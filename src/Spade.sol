// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {IERC20} from "./interfaces/IERC20.sol";
import {IERC721TokenReceiver} from "./interfaces/IERC721TokenReceiver.sol";

import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";


/// ?????????????????????????????????????? . ######################################
/// ?????????????????????????????????????  %  #####################################
/// ????????????????????????????????????  %*:  ####################################
/// ???????????????????????????????????  %#*?:  ###################################
/// ?????????????????????????????????  ,%##*??:.  #################################
/// ???????????????????????????????  ,%##*?*#*??:.  ###############################
/// ?????????????????????????????  ,%###*??*##*???:.  #############################
/// ???????????????????????????  ,%####*???*###*????:.  ###########################
/// ?????????????????????????  ,%####**????*####**????:.  #########################
/// ???????????????????????  ,%#####**?????*#####**?????:.  #######################
/// ??????????????????????  %######**??????*######**??????:  ######################
/// ?????????????????????  %######**???????*#######**??????:  #####################
/// ????????????????????  %######***???????*#######***??????:  ####################
/// ????????????????????  %######***???????*#######***??????:  ####################
/// ????????????????????  %######***???????*#######***??????:  ####################
/// ?????????????????????  %######**??????***######**??????:  #####################
/// ??????????????????????  '%######****:^%*:^%****??????:'  ######################
/// ????????????????????????   '%####*:'  %*:  '%*????:'   ########################
/// ??????????????????????????           %#*?:           ##########################
/// ?????????????????????????????????  ,%##*??:.  #################################
/// ???????????????????????????????  .%###***???:.  ###############################
/// ??????????????????????????????                   ##############################
/// ???????????????????????????????????????*#######################################

/// @title SPADE
/// @author andreas <andreas@nascent.xyz>
/// @dev Extensible ERC721 Implementation with a baked-in commitment scheme and lbp.
abstract contract Spade {
    ///////////////////////////////////////////////////////////////////////////////
    ///                               CUSTOM ERRORS                             ///
    ///////////////////////////////////////////////////////////////////////////////

    error NotAuthorized();

    error WrongFrom();

    error InvalidRecipient();

    error UnsafeRecipient();

    error AlreadyMinted();

    error NotMinted();

    error InsufficientDeposit();

    error WrongPhase();

    error InvalidHash();

    error InsufficientPrice();

    error InsufficientValue();

    error InvalidAction();

    error SoldOut();

    ///////////////////////////////////////////////////////////////////////////////
    ///                                   EVENTS                                ///
    ///////////////////////////////////////////////////////////////////////////////

    event Commit(address indexed from, bytes32 commitment);

    event Reveal(address indexed from, uint256 appraisal);

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId);

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    ///////////////////////////////////////////////////////////////////////////////
    ///                                  METADATA                               ///
    ///////////////////////////////////////////////////////////////////////////////

    string public name;

    string public symbol;

    function tokenURI(uint256 id) public view virtual returns (string memory);

    ///////////////////////////////////////////////////////////////////////////////
    ///                                  IMMUTABLES                             ///
    ///////////////////////////////////////////////////////////////////////////////

    /// @dev The deposit amount to place a commitment
    uint256 public immutable depositAmount;

    /// @dev The minimum mint price
    uint256 public immutable minPrice;

    /// @dev Commit Start Timestamp
    uint256 public immutable commitStart;

    /// @dev Reveal Start Timestamp
    uint256 public immutable revealStart;

    /// @dev Restricted Mint Start Timestamp
    uint256 public immutable restrictedMintStart;

    /// @dev Public Mint Start Timestamp
    uint256 public immutable publicMintStart;

    /// @dev Optional ERC20 Deposit Token
    address public immutable depositToken;

    /// @dev Flex is a scaling factor for standard deviation in price band calculation
    uint256 public constant FLEX = 1;

    /// @dev The maximum token supply
    uint256 public constant MAX_TOKEN_SUPPLY = 10_000;

    /// @dev LBP priceDecayPerBlock config
    uint256 public immutable priceDecayPerBlock;

    /// @dev LBP priceIncreasePerMint config
    uint256 public immutable priceIncreasePerMint;

    ///////////////////////////////////////////////////////////////////////////////
    ///                                CUSTOM STORAGE                           ///
    ///////////////////////////////////////////////////////////////////////////////

    /// @dev The outlier scale for loss penalty
    /// @dev Loss penalty is taken with OUTLIER_FLEX * error as a percent
    uint256 public constant OUTLIER_FLEX = 5;

    /// @dev The time stored for LBP implementation
    uint256 private mintTime;

    /// @notice A rolling variance calculation
    /// @dev Used for minting price bands
    uint256 public rollingVariance;

    /// @notice The number of commits calculated
    uint256 public count;

    /// @notice The result lbp start price
    uint256 public clearingPrice;

    /// @notice The total token supply
    uint256 public totalSupply;

    /// @notice User Commitments
    mapping(address => bytes32) public commits;

    /// @notice The resulting user appraisals
    mapping(address => uint256) public reveals;

    ///////////////////////////////////////////////////////////////////////////////
    ///                                ERC721 STORAGE                           ///
    ///////////////////////////////////////////////////////////////////////////////

    mapping(address => uint256) public balanceOf;

    mapping(uint256 => address) public ownerOf;

    mapping(uint256 => address) public getApproved;

    mapping(address => mapping(address => bool)) public isApprovedForAll;

    ///////////////////////////////////////////////////////////////////////////////
    ///                                 CONSTRUCTOR                             ///
    ///////////////////////////////////////////////////////////////////////////////

    constructor(
      string memory _name,
      string memory _symbol,
      uint256 _depositAmount,
      uint256 _minPrice,
      uint256 _commitStart,
      uint256 _revealStart,
      uint256 _restrictedMintStart,
      uint256 _publicMintStart,
      address _depositToken,
      uint256 _priceDecayPerBlock,
      uint256 _priceIncreasePerMint
    ) {
        name = _name;
        symbol = _symbol;

        // Store immutables
        depositAmount = _depositAmount;
        minPrice = _minPrice;
        commitStart = _commitStart;
        revealStart = _revealStart;
        restrictedMintStart = _restrictedMintStart;
        publicMintStart = _publicMintStart;
        depositToken = _depositToken;
        priceDecayPerBlock = _priceDecayPerBlock;
        priceIncreasePerMint = _priceIncreasePerMint;
    }

    ///////////////////////////////////////////////////////////////////////////////
    ///                              COMMITMENT LOGIC                           ///
    ///////////////////////////////////////////////////////////////////////////////

    /// @notice Commit is payable to require the deposit amount
    function commit(bytes32 commitment) external payable {
        // Make sure the user has placed the deposit amount
        if (depositToken == address(0) && msg.value < depositAmount) revert InsufficientDeposit();
        
        // Verify during commit phase
        if (block.timestamp < commitStart || block.timestamp >= revealStart) revert WrongPhase();
        
        // Transfer the deposit token into this contract
        if (depositToken != address(0)) {
          IERC20(depositToken).transferFrom(msg.sender, address(this), depositAmount);
        }

        // Store Commitment
        commits[msg.sender] = commitment;

        // Emit the commit event
        emit Commit(msg.sender, commitment);
    }

    /// @notice Revealing a commitment
    function reveal(uint256 appraisal, bytes32 blindingFactor) external {
        // Verify during reveal+mint phase
        if (block.timestamp < revealStart || block.timestamp >= restrictedMintStart) revert WrongPhase();

        bytes32 senderCommit = commits[msg.sender];

        bytes32 calculatedCommit = keccak256(abi.encodePacked(msg.sender, appraisal, blindingFactor));

        if (senderCommit != calculatedCommit) revert InvalidHash();

        // The user has revealed their correct value
        delete commits[msg.sender];
        reveals[msg.sender] = appraisal;

        // Add the appraisal to the result value and recalculate variance
        // Calculation adapted from https://math.stackexchange.com/questions/102978/incremental-computation-of-standard-deviation
        if (count == 0) {
          clearingPrice = appraisal;
        } else {
          // we have two or more values now so we calculate variance
          uint256 clearingPrice_ = clearingPrice;
          uint256 carryTerm = ((count - 1) * rollingVariance) / count;
          uint256 diff = appraisal < clearingPrice_ ? clearingPrice_ - appraisal : appraisal - clearingPrice_;
          uint256 updateTerm = (diff ** 2) / (count + 1);
          rollingVariance = carryTerm + updateTerm;
          // Update clearingPrice_ (new mean)
          clearingPrice_ = (count * clearingPrice_ + appraisal) / (count + 1);
        }
        unchecked {
          count += 1;
        }

        // Emit a Reveal Event
        emit Reveal(msg.sender, appraisal);
    }

    ///////////////////////////////////////////////////////////////////////////////
    ///                           RESTRICTED MINT LOGIC                         ///
    ///////////////////////////////////////////////////////////////////////////////

    /// @notice Enables Minting During the Restricted Minting Phase
    function restrictedMint() external payable {
        // Verify during mint phase
        if (block.timestamp < restrictedMintStart) revert WrongPhase();

        // Sload the user's appraisal value
        uint256 senderAppraisal = reveals[msg.sender];

        // Result value
        uint256 finalValue = clearingPrice;
        if (finalValue < minPrice) finalValue = minPrice;

        // Verify they sent at least enough to cover the mint cost
        if (depositToken == address(0) && msg.value < finalValue) revert InsufficientValue();
        if (depositToken != address(0)) IERC20(depositToken).transferFrom(msg.sender, address(this), finalValue);

        // Use Reveals as a mask
        if (reveals[msg.sender] == 0) revert InvalidAction(); 

        // Check that the appraisal is within the price band
        uint256 stdDev = FixedPointMathLib.sqrt(rollingVariance);
        uint256 clearingPrice_ = clearingPrice;
        if (senderAppraisal < (clearingPrice_ - FLEX * stdDev) || senderAppraisal > (clearingPrice_ + FLEX * stdDev)) {
          revert InsufficientPrice();
        }

        // Delete revealed value to prevent double spend
        delete reveals[msg.sender];

        // Send deposit back to the minter
        if(depositToken == address(0)) msg.sender.call{value: depositAmount}("");
        else IERC20(depositToken).transfer(msg.sender, depositAmount);

        // Otherwise, we can mint the token
        unchecked {
          _mint(msg.sender, totalSupply++);
        }
    }

    /// @notice Forgos a mint
    /// @notice A penalty is assumed if the user's sealed bid was within the minting threshold
    function forgo() external {
        // Verify during mint phase
        if (block.timestamp < restrictedMintStart) revert WrongPhase();

        // Use Reveals as a mask
        if (reveals[msg.sender] == 0) revert InvalidAction(); 

        // Sload the user's appraisal value
        uint256 senderAppraisal = reveals[msg.sender];

        // Calculate a Loss penalty
        uint256 clearingPrice_ = clearingPrice;
        uint256 lossPenalty = 0;
        uint256 stdDev = FixedPointMathLib.sqrt(rollingVariance);
        uint256 diff = senderAppraisal < clearingPrice_ ? clearingPrice_ - senderAppraisal : senderAppraisal - clearingPrice_;
        if (stdDev != 0 && senderAppraisal >= (clearingPrice_ - FLEX * stdDev) && senderAppraisal <= (clearingPrice_ + FLEX * stdDev)) {
          lossPenalty = ((diff / stdDev) * depositAmount) / 100;
        }

        // Increase loss penalty if it's an outlier using Z-scores
        if (stdDev != 0) {
          // Take a penalty of OUTLIER_FLEX * error as a percent
          lossPenalty += OUTLIER_FLEX * (diff / stdDev) * depositAmount / 100;
        }

        // Return the deposit less the loss penalty
        // NOTE: we can let this error on underflow since that means Cloak should keep the full deposit
        uint256 amountTransfer = depositAmount - lossPenalty;

        // Transfer eth or erc20 back to user
        delete reveals[msg.sender];
        if(depositToken == address(0)) msg.sender.call{value: amountTransfer}("");
        else IERC20(depositToken).transfer(msg.sender, amountTransfer);
    }

    /// @notice Allows a user to withdraw their deposit on reveal elusion
    function lostReveal() external {
        // Verify after the reveal phase
        if (block.timestamp < restrictedMintStart) revert WrongPhase();

        // Prevent withdrawals unless reveals is empty and commits isn't
        if (reveals[msg.sender] != 0 || commits[msg.sender] == 0) revert InvalidAction();
    
        // Then we can release deposit with a penalty
        // NOTE: Hardcoded loss penalty
        delete commits[msg.sender];
        uint256 lossyDeposit = depositAmount;
        lossyDeposit = lossyDeposit - ((lossyDeposit * 5_000) / 10_000);
        if(depositToken == address(0)) msg.sender.call{value: depositAmount}("");
        else IERC20(depositToken).transfer(msg.sender, depositAmount);
    }

    /// @notice Allows a user to view if they can mint
    function canRestrictedMint() external view returns (bool mintable) {
      // Sload the user's appraisal value
      uint256 senderAppraisal = reveals[msg.sender];
      uint256 stdDev = FixedPointMathLib.sqrt(rollingVariance);
      uint256 clearingPrice_ = clearingPrice;
      mintable = senderAppraisal >= (clearingPrice_ - FLEX * stdDev) && senderAppraisal <= (clearingPrice_ + FLEX * stdDev);
    }

    ///////////////////////////////////////////////////////////////////////////////
    ///                              PUBLIC LBP LOGIC                           ///
    ///////////////////////////////////////////////////////////////////////////////

    /// @notice Permissionless minting for non-commitment phase participants
    /// @param amount The number of ERC721 tokens to mint
    function mint(uint256 amount) external payable {
        if (block.timestamp < publicMintStart) revert WrongPhase();
        if (totalSupply >= MAX_TOKEN_SUPPLY) revert SoldOut();

        // Calculate the mint price
        uint256 memMintTime = mintTime;
        if (memMintTime == 0) memMintTime = block.timestamp;
        uint256 mintPrice = clearingPrice - ((block.timestamp - memMintTime) * priceDecayPerBlock);
        if (mintPrice < minPrice) mintPrice = minPrice;

        // Take Payment
        if (depositToken == address(0) && msg.value < (mintPrice * amount)) revert InsufficientValue();
        else IERC20(depositToken).transferFrom(msg.sender, address(this), mintPrice * amount);

        // Mint and Update
        for (uint256 i = 0; i < amount; i++) {
          unchecked {
            _safeMint(msg.sender, totalSupply++);
          }
        }
        clearingPrice = mintPrice + priceIncreasePerMint * amount;
        mintTime = block.timestamp;
    }

    /// @notice Allows a user to view if they can mint
    /// @param amount The amount of tokens to mint
    /// @return allowed If the sender is allowed to mint
    function canMint(uint256 amount) external view returns (bool allowed) {
      allowed = block.timestamp >= publicMintStart && (totalSupply + amount) < MAX_TOKEN_SUPPLY;
    }

    ///////////////////////////////////////////////////////////////////////////////
    ///                                ERC721 LOGIC                             ///
    ///////////////////////////////////////////////////////////////////////////////

    function approve(address spender, uint256 id) public virtual {
        address owner = ownerOf[id];

        if (msg.sender != owner || !isApprovedForAll[owner][msg.sender]) {
          revert NotAuthorized();
        }

        getApproved[id] = spender;

        emit Approval(owner, spender, id);
    }

    function setApprovalForAll(address operator, bool approved) public virtual {
        isApprovedForAll[msg.sender][operator] = approved;

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(
        address from,
        address to,
        uint256 id
    ) public virtual {
        if (from != ownerOf[id]) revert WrongFrom();

        if (to == address(0)) revert InvalidRecipient();

        if (msg.sender != from || msg.sender != getApproved[id] || !isApprovedForAll[from][msg.sender]) {
          revert NotAuthorized();
        }

        // Underflow impossible due to check for ownership
        unchecked {
            balanceOf[from]--;
            balanceOf[to]++;
        }

        ownerOf[id] = to;

        delete getApproved[id];

        emit Transfer(from, to, id);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id
    ) public virtual {
        transferFrom(from, to, id);

        if (
          to.code.length != 0 ||
          IERC721TokenReceiver(to).onERC721Received(msg.sender, from, id, "") !=
          IERC721TokenReceiver.onERC721Received.selector
        ) {
          revert UnsafeRecipient();
        }
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        bytes memory data
    ) public virtual {
        transferFrom(from, to, id);

        if (
          to.code.length != 0 ||
          IERC721TokenReceiver(to).onERC721Received(msg.sender, from, id, data) !=
          IERC721TokenReceiver.onERC721Received.selector
        ) {
          revert UnsafeRecipient();
        }
    }

    ///////////////////////////////////////////////////////////////////////////////
    ///                                ERC165 LOGIC                             ///
    ///////////////////////////////////////////////////////////////////////////////

    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 Interface ID for ERC165
            interfaceId == 0x80ac58cd || // ERC165 Interface ID for ERC721
            interfaceId == 0x5b5e139f;   // ERC165 Interface ID for ERC721Metadata
    }

    ///////////////////////////////////////////////////////////////////////////////
    ///                               INTERNAL LOGIC                            ///
    ///////////////////////////////////////////////////////////////////////////////

    function _mint(address to, uint256 id) internal virtual {
        if (to == address(0)) revert InvalidRecipient();

        if (ownerOf[id] != address(0)) revert AlreadyMinted();

        // Counter overflow is incredibly unrealistic.
        unchecked {
            balanceOf[to]++;
        }

        ownerOf[id] = to;

        emit Transfer(address(0), to, id);
    }

    function _burn(uint256 id) internal virtual {
        address owner = ownerOf[id];

        if (ownerOf[id] == address(0)) revert NotMinted();

        // Ownership check above ensures no underflow.
        unchecked {
            balanceOf[owner]--;
        }

        delete ownerOf[id];

        delete getApproved[id];

        emit Transfer(owner, address(0), id);
    }

    ///////////////////////////////////////////////////////////////////////////////
    ///                            INTERNAL SAFE LOGIC                          ///
    ///////////////////////////////////////////////////////////////////////////////

    function _safeMint(address to, uint256 id) internal virtual {
        _mint(to, id);

        if (
          to.code.length != 0 ||
          IERC721TokenReceiver(to).onERC721Received(msg.sender, address(0), id, "") !=
          IERC721TokenReceiver.onERC721Received.selector
        ) {
          revert UnsafeRecipient();
        }
    }

    function _safeMint(
        address to,
        uint256 id,
        bytes memory data
    ) internal virtual {
        _mint(to, id);

        if (
          to.code.length != 0 ||
          IERC721TokenReceiver(to).onERC721Received(msg.sender, address(0), id, data) !=
          IERC721TokenReceiver.onERC721Received.selector
        ) {
          revert UnsafeRecipient();
        }
    }
}