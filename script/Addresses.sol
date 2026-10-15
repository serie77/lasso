// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Robinhood Chain mainnet (chain id 4663) addresses, from app.hooke.fun/v1/protocol and chain inspection.
library Addresses {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // Global Dollar, 6 decimals
    address constant HXMAX = 0x71796aAD4CdFf942D3eE8Bb1227F779255f89DbC; // Hooke XMAX stock token, 18 decimals
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951; // Uniswap V4
    address constant HOOKE_ORACLE_REGISTRY = 0x33c5341DC45E389B2A993F4599649D121646240C;
    address constant HOOKE_FEE_HOOK = 0xb51d89BBc50B5AE469be8CFbF305CAb6ff3A50Cc; // hXMAX/USDG dynamic-tax hook
    bytes32 constant XMAX_FEED_ID = 0xd87eb24cefadd05cc0a3e9ae61754d652fc1444f24d4ccffca82357bec14943b;
    bytes32 constant ETH_USDG_POOL_ID = 0xfd2fff96a89622853d7322e6829c16182f1c1e6a73be8d3819dc4f5f54ba0d86; // ETH is currency0
    string constant PUBLIC_RPC = "https://rpc.mainnet.chain.robinhood.com";
}
