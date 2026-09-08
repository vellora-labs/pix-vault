// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title VelloraPixVault
 * @notice Cofre por rede para a compra via PIX:
 *         segura a RESERVA (stable da rede: USDT, USDG…) e executa, por
 *         ordem, calldata de swap de um agregador/DEX allowlistado, entregando
 *         o token (ou o nativo) DIRETAMENTE ao usuário.
 *
 *         O que o contrato garante, independentemente de quem opera:
 *           - idempotência on-chain (`usedOrders`);
 *           - só operadores executam; só alvos allowlistados recebem calls;
 *           - a reserva só sai via approve exato para o `spender` da ordem, e
 *             o gasto medido nunca excede `amountIn`;
 *           - a entrega é medida no DESTINATÁRIO (delta de saldo) e tem de
 *             cobrir `minOut`;
 *           - tetos por ordem e por dia (janela UTC);
 *           - nenhuma call leva `value`, nenhuma call mira a própria reserva.
 *
 *         Não há registro de tokens/rotas por rede:
 *         a rota vem de fora (router/agregador) como calldata.
 *         Mesmo bytecode em todas as redes; a reserva é configurada pelo
 *         owner depois do deploy (permite CREATE2 com o mesmo endereço).
 */
contract VelloraPixVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Call {
        address target;
        bytes data;
    }

    IERC20 public reserve;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public isAllowedTarget;
    mapping(bytes32 => bool) public usedOrders;

    /// @notice Máximo de reserva por ordem (unidades mínimas). 0 = bloqueado (fail-closed).
    uint256 public maxAmountPerOrder;
    /// @notice Máximo de reserva por dia UTC (unidades mínimas). 0 = sem teto diário.
    uint256 public dailyCap;
    uint256 public spentToday;
    uint64 public dayStart;

    event ReserveSet(address indexed token);
    event OperatorSet(address indexed operator, bool allowed);
    event AllowedTargetSet(address indexed target, bool allowed);
    event LimitsSet(uint256 maxAmountPerOrder, uint256 dailyCap);
    event BuyExecuted(
        bytes32 indexed orderId,
        address indexed recipient,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 spent,
        uint256 delivered,
        address spender
    );
    event ReserveTransferred(bytes32 indexed orderId, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error NotOperator();
    error OrderAlreadyUsed(bytes32 orderId);
    error ReserveNotSet();
    error ReserveHasBalance();
    error InvalidRecipient();
    error InvalidTokenOut();
    error TargetNotAllowed(address target);
    error SpenderNotAllowed(address spender);
    error AmountZero();
    error AboveMaxPerOrder(uint256 amountIn, uint256 maxAmountPerOrder);
    error AboveDailyCap(uint256 wouldSpend, uint256 dailyCap);
    error CallFailed(uint256 index, bytes returnData);
    error Overspent(uint256 spent, uint256 amountIn);
    error NothingSpent();
    error InsufficientDelivery(uint256 delivered, uint256 minOut);
    error NativeTransferFailed();

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    receive() external payable {}

    // ----------------------------------------------------------------- admin

    /// @notice Define a reserva. Só pode trocar com saldo zero da reserva atual.
    function setReserve(address token) external onlyOwner {
        if (address(reserve) != address(0) && reserve.balanceOf(address(this)) != 0) revert ReserveHasBalance();
        reserve = IERC20(token);
        emit ReserveSet(token);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        isAllowedTarget[target] = allowed;
        emit AllowedTargetSet(target, allowed);
    }

    function setLimits(uint256 maxAmountPerOrder_, uint256 dailyCap_) external onlyOwner {
        maxAmountPerOrder = maxAmountPerOrder_;
        dailyCap = dailyCap_;
        emit LimitsSet(maxAmountPerOrder_, dailyCap_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Saque do owner (reserva, qualquer ERC-20 preso, ou nativo com token = 0).
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdrawn(token, to, amount);
    }

    // -------------------------------------------------------------- operação

    /**
     * @notice Executa uma compra: aprova `spender` por exatamente `amountIn`,
     *         roda as `calls` (todas em alvos allowlistados), zera o approve e
     *         mede gasto (≤ amountIn) e entrega ao `recipient` (≥ minOut).
     * @param tokenOut token entregue; address(0) = nativo (medido em `recipient.balance`).
     * @param spender  quem puxa a reserva (Augustus, Permit2, SmartRouter…).
     */
    function executeBuy(
        bytes32 orderId,
        address recipient,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address spender,
        Call[] calldata calls
    ) external onlyOperator whenNotPaused nonReentrant returns (uint256 delivered, uint256 spent) {
        _preflight(orderId, recipient, tokenOut, amountIn, spender);
        uint256 outBefore = _balanceOf(tokenOut, recipient);
        spent = _swap(spender, amountIn, calls);
        delivered = _balanceOf(tokenOut, recipient) - outBefore;
        if (delivered == 0 || delivered < minOut) revert InsufficientDelivery(delivered, minOut);
        emit BuyExecuted(orderId, recipient, tokenOut, amountIn, spent, delivered, spender);
    }

    function _preflight(bytes32 orderId, address recipient, address tokenOut, uint256 amountIn, address spender)
        internal
    {
        if (address(reserve) == address(0)) revert ReserveNotSet();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (tokenOut == address(reserve)) revert InvalidTokenOut();
        if (!isAllowedTarget[spender]) revert SpenderNotAllowed(spender);
        _consumeOrder(orderId);
        _checkLimits(amountIn);
    }

    /// Aprova `spender` por `amountIn`, roda as calls em alvos allowlistados, zera o approve e mede o gasto.
    function _swap(address spender, uint256 amountIn, Call[] calldata calls) internal returns (uint256 spent) {
        IERC20 reserve_ = reserve;
        uint256 reserveBefore = reserve_.balanceOf(address(this));
        reserve_.forceApprove(spender, amountIn);
        uint256 n = calls.length;
        for (uint256 i = 0; i < n; ++i) {
            address target = calls[i].target;
            if (!isAllowedTarget[target] || target == address(reserve_) || target == address(this)) {
                revert TargetNotAllowed(target);
            }
            (bool ok, bytes memory ret) = target.call(calls[i].data);
            if (!ok) revert CallFailed(i, ret);
        }
        reserve_.forceApprove(spender, 0);
        spent = reserveBefore - reserve_.balanceOf(address(this));
        if (spent == 0) revert NothingSpent();
        if (spent > amountIn) revert Overspent(spent, amountIn);
    }

    /// @notice Entrega a própria reserva (compra de USDT/USDG): sem swap.
    function transferReserve(bytes32 orderId, address recipient, uint256 amount)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        IERC20 reserve_ = reserve;
        if (address(reserve_) == address(0)) revert ReserveNotSet();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        _consumeOrder(orderId);
        _checkLimits(amount);
        reserve_.safeTransfer(recipient, amount);
        emit ReserveTransferred(orderId, recipient, amount);
    }

    // ------------------------------------------------------------- internos

    function _consumeOrder(bytes32 orderId) internal {
        if (usedOrders[orderId]) revert OrderAlreadyUsed(orderId);
        usedOrders[orderId] = true;
    }

    function _checkLimits(uint256 amount) internal {
        if (amount == 0) revert AmountZero();
        if (amount > maxAmountPerOrder) revert AboveMaxPerOrder(amount, maxAmountPerOrder);
        uint64 today = uint64((block.timestamp / 1 days) * 1 days);
        if (today != dayStart) {
            dayStart = today;
            spentToday = 0;
        }
        if (dailyCap != 0 && spentToday + amount > dailyCap) revert AboveDailyCap(spentToday + amount, dailyCap);
        spentToday += amount;
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }
}
