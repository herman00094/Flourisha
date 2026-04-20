// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    Flourisha is a brand-grade onchain companion for health + style:
    - "looks" are minted as onchain SVGs with floral motifs derived from a seed
    - a curator can publish seasonal palettes and prompt frames
    - users can redeem signed recommendations without exposing private profiles onchain

    This file contains the main contract plus a tiny launchpad that deploys it with
    pre-populated, per-contract unique addresses.
*/

/// @dev Minimal ERC165.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @dev Minimal ERC721 receiver.
interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @dev Minimal ERC721 interface, intentionally narrow.
interface IERC721 is IERC165 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

/// @dev Minimal ERC2981 interface.
interface IERC2981 is IERC165 {
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount);
}

library FlorStrings {
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            unchecked {
                digits++;
                temp /= 10;
            }
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            unchecked {
                digits -= 1;
                buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
                value /= 10;
            }
        }
        return string(buffer);
    }

    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes16 symbols = "0123456789abcdef";
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; ) {
            unchecked {
                buffer[i] = symbols[value & 0xf];
                value >>= 4;
                i--;
            }
        }
        return string(buffer);
    }
}

library FlorBase64 {
    bytes internal constant TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";

        bytes memory table = TABLE;
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen + 32);

        assembly {
            let tablePtr := add(table, 1)
            let resultPtr := add(result, 32)
            for { let i := 0 } lt(i, mload(data)) { } {
                i := add(i, 3)
                let input := and(mload(add(data, i)), 0xffffff)
                let out := mload(add(tablePtr, and(shr(18, input), 0x3F)))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(shr(12, input), 0x3F))), 0xFF))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(shr(6, input), 0x3F))), 0xFF))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(input, 0x3F))), 0xFF))
                out := shl(224, out)
                mstore(resultPtr, out)
                resultPtr := add(resultPtr, 4)
            }

            switch mod(mload(data), 3)
            case 1 { mstore(sub(resultPtr, 2), shl(240, 0x3d3d)) }
            case 2 { mstore(sub(resultPtr, 1), shl(248, 0x3d)) }

            mstore(result, encodedLen)
        }

        return string(result);
    }
}

library FlorECDSA {
    error FlorECDSA_BadSig();
    error FlorECDSA_BadS();
    error FlorECDSA_BadV();

    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) revert FlorECDSA_BadSig();
        bytes32 r;
        bytes32 s;
        uint8 v;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        // malleability check
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert FlorECDSA_BadS();
        }
        if (v != 27 && v != 28) revert FlorECDSA_BadV();
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) revert FlorECDSA_BadSig();
        return signer;
    }

    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}

abstract contract FlorReentrancy {
    uint256 private _status;
    error FlorGuard_Reentered();
    constructor() {
        _status = 1;
    }
    modifier nonReentrant() {
        if (_status != 1) revert FlorGuard_Reentered();
        _status = 2;
        _;
        _status = 1;
    }
}

abstract contract FlorPausable {
    event FlourishaPause(address indexed actor, uint256 indexed at);
    event FlourishaUnpause(address indexed actor, uint256 indexed at);
    error Flourisha_Paused();
    error Flourisha_NotPaused();
    bool private _paused;
    function paused() public view returns (bool) { return _paused; }
    modifier whenNotPaused() { if (_paused) revert Flourisha_Paused(); _; }
    modifier whenPaused() { if (!_paused) revert Flourisha_NotPaused(); _; }
    function _pause() internal whenNotPaused { _paused = true; emit FlourishaPause(msg.sender, block.number); }
    function _unpause() internal whenPaused { _paused = false; emit FlourishaUnpause(msg.sender, block.number); }
}

contract Flourisha is IERC721, IERC2981, FlorReentrancy, FlorPausable {
    using FlorStrings for uint256;

    // -------------------------
    // Uniqueness anchors
    // -------------------------
    bytes32 public constant FLOURISHA_DOMAIN = keccak256("Flourisha.floral-health-style.v1");
    bytes32 public constant NOTEBOOK_TAG = keccak256("Flourisha.notebook.tagline.rose-neroli");
    bytes32 public constant GENESIS_DUST = bytes32(uint256(0x0f50f7a7f9fb4c055b0d878b5326fab79a3073f38c5aa61c6f81be97e9f7a1f2e));
    bytes32 public constant STARLING_SEED = bytes32(uint256(0x09a6c006b8b1a1dfda3398112fbd4eff3b9c6dade9239c668b08d1a9091d735e6));
    bytes32 public constant PETAL_CHIME = bytes32(uint256(0x087fd7817fb4193bb4802f7645e0d64298d9090c9d60fbbc14f5e8d7705b6047c));

    // -------------------------
    // Core metadata
    // -------------------------
    string public name;
    string public symbol;

    // -------------------------
    // Authority (constructor-injected)
    // -------------------------
    address public immutable admin;
    address public immutable treasury;
    address public immutable curator;
    address public immutable emergencyGuardian;
    address public immutable recommendationSigner;

    // -------------------------
    // Mint/payment config
    // -------------------------
    uint256 public immutable mintPriceWei;
    uint256 public immutable maxSupply;
    uint96 public immutable royaltyBps; // 1% = 100
    address public immutable royaltyReceiver;
