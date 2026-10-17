// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

/**
 * @title IGPv2Settlement
 * @notice Minimal interface for CoW Protocol's settlement contract, exposing only the surface the CowSwap
 *         helper uses: the pre-signature entrypoint and two immutables - `domainSeparator`, used to
 *         reconstruct an order's UID on-chain, and `vaultRelayer`, the settlement spender the helper approves
 *         to pull sell tokens.
 * @dev `setPreSignature` requires `owner == msg.sender`, where `owner` is the account embedded in
 *      `orderUid`. That single constraint is what forces the caller of `setPreSignature` to be the same
 *      account whose sell-token balance and approval the relayer draws from at settlement.
 */
interface IGPv2Settlement {

    /**
     * @notice Sets or clears the on-chain pre-signature authorizing `orderUid` for settlement.
     * @dev Reverts unless the `owner` packed into `orderUid` equals `msg.sender`.
     * @param orderUid 56-byte packed UID: orderDigest(32) ‖ owner(20) ‖ validTo(4).
     * @param signed True to authorize the order, false to revoke (cancel) it.
     */
    function setPreSignature(bytes calldata orderUid, bool signed) external;

    /**
     * @notice The EIP-712 domain separator this settlement contract signs orders under.
     */
    function domainSeparator() external view returns (bytes32);

    /**
     * @notice The relayer that actually pulls sell tokens from order owners; the address that must be
     *         granted the sell-token approval.
     */
    function vaultRelayer() external view returns (address);

}
