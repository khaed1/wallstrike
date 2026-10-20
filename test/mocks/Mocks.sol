// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20 as OZERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract MockIMD is OZERC20 {
    constructor() OZERC20("IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Same rules as mainnet StakedIMD: 6-decimal offset and the one-block hold, where any mint stamps
/// the receiver, a transfer passes the sender's stamp on, and a stamped owner cannot withdraw or redeem in
/// that block. Transfers are never blocked.
contract MockStakedIMD is ERC4626 {
    address internal immutable _asset;
    mapping(address => uint256) public lastDepositBlock;

    error SameBlockRedeem();

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() public view override returns (address) {
        return _asset;
    }

    function name() public pure override returns (string memory) {
        return "Staked IMD";
    }

    function symbol() public pure override returns (string memory) {
        return "sIMD";
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _withdraw(address by, address to, address owner, uint256 assets, uint256 shares) internal override {
        if (block.number == lastDepositBlock[owner]) revert SameBlockRedeem();
        super._withdraw(by, to, owner, assets, shares);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (amount == 0 || to == address(0)) return;
        if (from == address(0)) {
            lastDepositBlock[to] = block.number;
        } else if (lastDepositBlock[from] > lastDepositBlock[to]) {
            lastDepositBlock[to] = lastDepositBlock[from];
        }
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (block.number == lastDepositBlock[owner]) return 0;
        return super.maxRedeem(owner);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (block.number == lastDepositBlock[owner]) return 0;
        return super.maxWithdraw(owner);
    }
}

contract MockCappedBurnHook {
    PoolId public poolId;
    bool public marketOpen = true;
    uint128 public positionLiquidity = 1e20;
    bool public rebalanceEnabled = true;
    int24 public refTick;
    int24 public maxRefStep = 200;
    int24 internal _wallLower;
    int24 internal _wallUpper = 887220;
    uint128 internal _wallLiquidity = 1e20;

    function backstop() external view returns (int24, int24, uint128) {
        return (_wallLower, _wallUpper, _wallLiquidity);
    }

    function setRefTick(int24 tick) external {
        refTick = tick;
    }

    function setWall(int24 lower, uint128 liquidity) external {
        _wallLower = lower;
        _wallLiquidity = liquidity;
    }

    function setMarketOpen(bool open) external {
        marketOpen = open;
    }

    function setPositionLiquidity(uint128 liquidity) external {
        positionLiquidity = liquidity;
    }

    function setRebalanceEnabled(bool enabled) external {
        rebalanceEnabled = enabled;
    }

    function setMaxRefStep(int24 step) external {
        maxRefStep = step;
    }
}

/// @notice Serves Uniswap v4 pool state through `extsload` in PoolManager's storage layout.
contract MockPoolManager {
    mapping(bytes32 => bytes32) internal _slots;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    function setPool(PoolId id, uint160 sqrtPriceX96, int24 tick, uint128 liquidity) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), StateLibrary.POOLS_SLOT));
        _slots[stateSlot] =
            bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(10_000) << 208));
        _slots[bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET)] = bytes32(uint256(liquidity));
    }
}
