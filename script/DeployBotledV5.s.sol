// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BotledConfig} from "../src/botled/BotledConfig.sol";
import {BotledRunnerPool} from "../src/botled/BotledRunnerPool.sol";
import {BotledFactoryV5} from "../src/botled/v5/BotledFactoryV5.sol";

/// @notice Botled v5 on Base: a new (unmodified) BotledRunnerPool anchored to a new BotledFactoryV5, which reuses the
///         deployed BotledConfig and BotledPanelOwner. Two CREATEs from one EOA, in this exact nonce order.
///   simulate: forge script script/DeployBotledV5.s.sol --rpc-url $BASE_RPC --sender <deployer>
///   deploy  : add --broadcast --account <keystore>   (NOT executed by the build; needs the owner's go)
/// Pre-req for deployCage: BotledConfig.proposeArbitration(standard) by the config owner + 1 day timelock.
contract DeployBotledV5 is Script {
    address constant CONFIG = 0x6A5785cc5e79Dc4c800367b54eA525c5e31040D7;
    address constant PANEL_OWNER = 0xF7E5A611154C8d30A03791409F2606C278597a04;
    address constant STANDARD = 0x1003592A2eeF71b15A21457910007b38B0e2027A;
    address constant AZL = 0x931517E9502F9d52CDF6F5AC7fca7925e2A1BBA3;
    address constant VRF_WRAPPER = 0xb0407dbe851f8318bd31404A49e658143C982F23;

    function run() external returns (address pool, address factory, address implementation) {
        uint256 vrfFund = vm.envOr("VRF_FUND_WEI", uint256(0));
        vm.startBroadcast();
        address deployer = msg.sender;
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        // same economics as the v4 pool: 100 AZL reserve per draw, 7 d exit cooldown, VRF gas 100k + 70k/juror, 3 conf
        pool = address(new BotledRunnerPool(predicted, AZL, VRF_WRAPPER, 100e18, 7 days, 100_000, 70_000, 3));
        BotledFactoryV5 f = new BotledFactoryV5(BotledConfig(CONFIG), pool, PANEL_OWNER, address(0), address(0));
        require(address(f) == predicted, "factory address != pool anchor");
        if (vrfFund > 0) {
            (bool ok,) = pool.call{value: vrfFund}("");
            require(ok, "vrf fund");
        }
        vm.stopBroadcast();
        factory = address(f);
        implementation = f.implementation();
        console2.log("BotledRunnerPool v5 :", pool);
        console2.log("BotledFactoryV5     :", factory);
        console2.log("BotledCageV5 impl   :", implementation);
        if (!BotledConfig(CONFIG).isSupportedArbitration(STANDARD)) {
            console2.log("NOTE: standard module not yet supported by BotledConfig -> deployCage reverts until");
            console2.log("      config.proposeArbitration(0x1003...027A) + 1 day (owner call).");
        }
    }
}
