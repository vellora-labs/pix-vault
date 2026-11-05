# Security policy

pix-vault is experimental. The contract has not been deployed to any network
and has not been audited. Do not use it with real funds.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub Security Advisories:
open the repository's **Security** tab and click **Report a vulnerability**.
Do not open a public issue or pull request for a security report.

If that button is not available, open an issue that only asks the maintainers
for a private contact, without any details of the problem.

A useful report names the affected file and function, describes the impact and,
if possible, includes a Foundry test that reproduces the issue.

## Scope

- `src/VelloraPixVault.sol`
- `script/DeployVelloraPixVault.s.sol`

The test helpers under `test/` and the vendored `lib/forge-std` are out of scope,
although reports about them are still welcome.
