# Building from this repo

- Registry wasm (NEAR): `near/build-wasm.sh` (rust 1.99.1, cargo-near 0.23.0, `--locked`) must reproduce the sha256 in
  `near/wasm.sha256`, which equals the code hash of the mainnet registry (see `deploy/mainnet-near-v5.json`).
  Docker path: `cd near/botled-registry && cargo near build reproducible-wasm`.
- Solidity (Base): Foundry, solc 0.8.24. Two local dependencies are not vendored here:
  - `lib-forge-std` -> a forge-std checkout (`git clone https://github.com/foundry-rs/forge-std lib-forge-std`)
  - `azzle-v2/` remapping -> the Azzle v2 contracts (`github.com/azzle-lab/azzle`, `contracts/src/v2`); used only by tests
    and `script/DeployLocalNear.s.sol`. Adjust the path in `foundry.toml`.
  - `npm install` for `@openzeppelin/contracts`.
- runner-near: `cd runner-near && npm install && npm run selftest && npm run e2e` (local anvil only).
