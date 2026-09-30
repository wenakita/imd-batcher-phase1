// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title OFTBootstrapRegistry
 * @author 0xakita.eth
 * @notice Minimal registry for CreatorShareOFT construction.
 * @dev Used only during OFT deployment to resolve the LayerZero endpoint.
 *      Known chains return an explicit endpoint. Unknown chains revert.
 *      Base, Ethereum, Arbitrum, BSC, and Avalanche use the canonical EndpointV2.
 *      Unichain and Robinhood use the alternate endpoint family.
 *      EIDs stay Base and Robinhood only; other chains use Registry4626.
 *      No mutable state is permitted — write-free to eliminate endpoint poisoning.
 *
 * @dev Bootstrap is deployed at salt `keccak256("4626:OFTBootstrapRegistry:v1")` via
 *      `UniversalCreate2DeployerFromStore` on every chain. Same bytecode + salt + deployer
 *      ⇒ same bootstrap address cross-chain (required for ShareOFT CREATE2 parity).
 */
contract OFTBootstrapRegistry {
    /// @dev LayerZero v2 EndpointV2 — common address on most EVM chains.
    address public constant LZ_COMMON_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    /// @dev Alternate EndpointV2 family (Robinhood Chain).
    address public constant LZ_ALT_ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    /// @dev Base mainnet chain id.
    uint256 public constant BASE_CHAIN_ID = 8453;
    /// @dev Ethereum mainnet chain id.
    uint256 public constant ETH_CHAIN_ID = 1;
    /// @dev Arbitrum One chain id.
    uint256 public constant ARB_CHAIN_ID = 42_161;
    /// @dev BNB Smart Chain chain id.
    uint256 public constant BSC_CHAIN_ID = 56;
    /// @dev Avalanche C-Chain chain id.
    uint256 public constant AVAX_CHAIN_ID = 43_114;
    /// @dev Unichain mainnet chain id.
    uint256 public constant UNICHAIN_CHAIN_ID = 130;
    /// @dev Robinhood Chain mainnet chain id.
    uint256 public constant ROBINHOOD_CHAIN_ID = 4663;

    error UnknownBootstrapChain(uint256 chainId);
    /// @dev LayerZero EID for Base mainnet.
    uint32 public constant BASE_EID = 30184;
    /// @dev LayerZero EID for Robinhood Chain mainnet.
    uint32 public constant ROBINHOOD_EID = 30416;

    /// @notice Return the LayerZero endpoint for a known chain.
    /// @dev Reverts for any chain that is not listed. There is no canonical-endpoint fallback.
    function getLayerZeroEndpoint(uint256 chainId) external pure returns (address) {
        if (chainId == ROBINHOOD_CHAIN_ID || chainId == UNICHAIN_CHAIN_ID) return LZ_ALT_ENDPOINT;
        if (
            chainId == BASE_CHAIN_ID || chainId == ETH_CHAIN_ID || chainId == ARB_CHAIN_ID || chainId == BSC_CHAIN_ID
                || chainId == AVAX_CHAIN_ID
        ) {
            return LZ_COMMON_ENDPOINT;
        }
        revert UnknownBootstrapChain(chainId);
    }

    /// @notice Return the LayerZero EID for the provided chain id.
    /// @dev B-11: bootstrap is CREATE2-pinned two-chain-only (Base + Robinhood).
    ///      Other chains must use mutable `Registry4626` EID mappings — do not add
    ///      EIDs here (bytecode change would break ShareOFT CREATE2 parity).
    function getEidForChainId(uint256 chainId) external pure returns (uint32) {
        if (chainId == BASE_CHAIN_ID) return BASE_EID;
        if (chainId == ROBINHOOD_CHAIN_ID) return ROBINHOOD_EID;
        return 0;
    }
}
