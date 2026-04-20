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

    // -------------------------
    // Storage: ERC721-lite
    // -------------------------
    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // -------------------------
    // Storage: Flourisha content
    // -------------------------
    struct LookSeed {
        uint64 paletteId;
        uint64 bloomId;
        uint128 seed;
    }

    struct Palette {
        string name;
        string[] hexes; // e.g. ["#0b1320", "#e2c39a"]
        uint64 createdAt;
        uint8 mood; // 0..255, used for UI hints
        bool active;
    }

    struct PromptFrame {
        string title;
        string[] lines;
        uint64 createdAt;
        bool active;
    }

    uint256 public totalSupply;
    mapping(uint256 => LookSeed) public lookOf;
    mapping(uint64 => Palette) private _palettes;
    mapping(uint64 => PromptFrame) private _frames;
    uint64 public paletteCount;
    uint64 public frameCount;

    // -------------------------
    // Anti-replay + redeem permits
    // -------------------------
    mapping(bytes32 => bool) public usedPermit;
    mapping(address => uint64) public userNonce;

    // -------------------------
    // Events / errors (distinct naming)
    // -------------------------
    event FlourishaLookMinted(
        address indexed user,
        uint256 indexed tokenId,
        uint64 indexed paletteId,
        uint64 bloomId,
        uint128 seed,
        uint256 paidWei
    );
    event FlourishaPalettePublished(uint64 indexed paletteId, string name, uint8 mood, bool active);
    event FlourishaFramePublished(uint64 indexed frameId, string title, bool active);
    event FlourishaFrameLine(uint64 indexed frameId, uint256 indexed lineIndex, string text);
    event FlourishaPaletteColor(uint64 indexed paletteId, uint256 indexed index, string hexColor);
    event FlourishaPermitRedeemed(address indexed user, bytes32 indexed permitHash, uint64 indexed usedNonce, uint256 atBlock);
    event FlourishaEmergencySweep(address indexed to, uint256 amountWei, uint256 atBlock);

    error Flourisha_OnlyAdmin();
    error Flourisha_OnlyCurator();
    error Flourisha_OnlyGuardian();
    error Flourisha_BadAddress();
    error Flourisha_SupplyExhausted();
    error Flourisha_WrongValue();
    error Flourisha_NotOwnerNorApproved();
    error Flourisha_BadRecipient();
    error Flourisha_TokenMissing();
    error Flourisha_UnsafeRecipient();
    error Flourisha_PermitUsed();
    error Flourisha_SignatureMismatch();
    error Flourisha_FrameMissing();
    error Flourisha_PaletteMissing();
    error Flourisha_NotActive();

    // -------------------------
    // Constructor
    // -------------------------
    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        address treasury_,
        address curator_,
        address emergencyGuardian_,
        address recommendationSigner_,
        uint256 mintPriceWei_,
        uint256 maxSupply_,
        address royaltyReceiver_,
        uint96 royaltyBps_
    ) {
        if (
            admin_ == address(0) || treasury_ == address(0) || curator_ == address(0) || emergencyGuardian_ == address(0)
                || recommendationSigner_ == address(0) || royaltyReceiver_ == address(0)
        ) revert Flourisha_BadAddress();
        if (royaltyBps_ > 2500) revert Flourisha_WrongValue(); // hard cap at 25% (mainnet sanity)
        if (maxSupply_ == 0) revert Flourisha_WrongValue();

        name = name_;
        symbol = symbol_;

        admin = admin_;
        treasury = treasury_;
        curator = curator_;
        emergencyGuardian = emergencyGuardian_;
        recommendationSigner = recommendationSigner_;

        mintPriceWei = mintPriceWei_;
        maxSupply = maxSupply_;
        royaltyReceiver = royaltyReceiver_;
        royaltyBps = royaltyBps_;

        _seedInitialCatalog();
    }

    // -------------------------
    // Modifiers
    // -------------------------
    modifier onlyAdmin() {
        if (msg.sender != admin) revert Flourisha_OnlyAdmin();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert Flourisha_OnlyCurator();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != emergencyGuardian) revert Flourisha_OnlyGuardian();
        _;
    }

    // -------------------------
    // ERC165
    // -------------------------
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC2981).interfaceId;
    }

    // -------------------------
    // ERC721-lite view
    // -------------------------
    function balanceOf(address owner) external view override returns (uint256) {
        if (owner == address(0)) revert Flourisha_BadAddress();
        return _balanceOf[owner];
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        address owner = _ownerOf[tokenId];
        if (owner == address(0)) revert Flourisha_TokenMissing();
        return owner;
    }

    function getApproved(uint256 tokenId) external view override returns (address) {
        if (_ownerOf[tokenId] == address(0)) revert Flourisha_TokenMissing();
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    // -------------------------
    // ERC721-lite approvals
    // -------------------------
    function approve(address to, uint256 tokenId) external override whenNotPaused {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) revert Flourisha_NotOwnerNorApproved();
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external override whenNotPaused {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    // -------------------------
    // Transfers
    // -------------------------
    function transferFrom(address from, address to, uint256 tokenId) public override whenNotPaused {
        if (to == address(0)) revert Flourisha_BadRecipient();
        address owner = ownerOf(tokenId);
        if (owner != from) revert Flourisha_NotOwnerNorApproved();
        if (!_isApprovedOrOwner(msg.sender, tokenId, owner)) revert Flourisha_NotOwnerNorApproved();

        delete _tokenApprovals[tokenId];
        unchecked {
            _balanceOf[from] -= 1;
            _balanceOf[to] += 1;
        }
        _ownerOf[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external override {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public override whenNotPaused {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 ret) {
                if (ret != IERC721Receiver.onERC721Received.selector) revert Flourisha_UnsafeRecipient();
            } catch {
                revert Flourisha_UnsafeRecipient();
            }
        }
    }
