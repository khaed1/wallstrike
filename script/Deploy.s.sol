// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {ImdPriceRecorder} from "../src/ImdPriceRecorder.sol";
import {Wallstrike} from "../src/Wallstrike.sol";
import {ICappedBurnHook} from "../src/interfaces/ICappedBurnHook.sol";
import {IStakedIMD} from "../src/interfaces/IStakedIMD.sol";

/// @notice Deploys the recorder, a 48h TimelockController controlled by `ADMIN` (use a multisig), and
/// Wallstrike owned by that timelock. Fees go to `FEE_RECIPIENT`; `GUARDIAN` can pause at once.
///
///   ADMIN=0x... FEE_RECIPIENT=0x... GUARDIAN=0x... forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL \
///     --account deployer --broadcast --verify
contract Deploy is Script {
    IERC20 internal constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    IStakedIMD internal constant SIMD = IStakedIMD(0x9Efa934D9fAd4AE28c998a40195646b965a97247);
    ICappedBurnHook internal constant HOOK = ICappedBurnHook(0xc6C965Bd164c483e87d0B550671798e9A3602840);
    IPoolManager internal constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    PoolId internal constant MAIN_POOL = PoolId.wrap(0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3);
    uint256 internal constant TIMELOCK_DELAY = 48 hours;

    function run() external returns (ImdPriceRecorder recorder, TimelockController timelock, Wallstrike ws) {
        address admin = vm.envAddress("ADMIN");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address guardian = vm.envAddress("GUARDIAN");
        address[] memory admins = new address[](1);
        admins[0] = admin;

        vm.startBroadcast();
        recorder = new ImdPriceRecorder(HOOK, MANAGER, SIMD, MAIN_POOL);
        timelock = new TimelockController(TIMELOCK_DELAY, admins, admins, address(0));
        ws = new Wallstrike(IMD, SIMD, HOOK, recorder, address(timelock), feeRecipient, guardian);
        recorder.poke();
        vm.stopBroadcast();

        console2.log("ImdPriceRecorder", address(recorder));
        console2.log("TimelockController", address(timelock));
        console2.log("Wallstrike", address(ws));
    }
}
