pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

/**
 * EPNS Core is the main protocol that deals with the imperative
 * features and functionalities like Channel Creation, admin etc.
 *
 * This protocol will be specifically deployed on Ethereum Blockchain while the Communicator
 * protocols can be deployed on Multiple Chains.
 * The EPNS Core is more inclined towards the storing and handling the Channel related
 * Functionalties.
 **/

// Essential Imports

import "./interfaces/ILendingPool.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IEPNSCommunicator.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "hardhat/console.sol";

contract EPNSCore is Initializable, ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ***************
     * DEFINE ENUMS AND CONSTANTS
     *************** */
    // For Message Type
    enum ChannelType {
        ProtocolNonInterest,
        ProtocolPromotion,
        InterestBearingOpen,
        InterestBearingMutual
    }
    enum ChannelAction {
        ChannelRemoved,
        ChannelAdded,
        ChannelUpdated
    }
    enum SubscriberAction {
        SubscriberRemoved,
        SubscriberAdded,
        SubscriberUpdated
    }

    /**
     * @notice Channel Struct that involves imperative details about
     * a specific Channel.
     **/
    struct Channel {
        // Channel Type
        ChannelType channelType;
        uint8 channelState; // Channel State Details: 0 -> INACTIVE, 1 -> ACTIVATED, 2 -> DeActivated By Channel Owner, 3 -> BLOCKED by ADMIN/Governance
        // Channel Pool Contribution
        uint256 poolContribution;
        uint256 memberCount;
        uint256 channelHistoricalZ;
        uint256 channelFairShareCount;
        uint256 channelLastUpdate; // The last update block number, used to calculate fair share
        // To calculate fair share of profit from the pool of channels generating interest
        uint256 channelStartBlock; // Helps in defining when channel started for pool and profit calculation
        uint256 channelUpdateBlock; // Helps in outlining when channel was updated
        uint256 channelWeight; // The individual weight to be applied as per pool contribution
        // TBD -> THE FOLLOWING STRUCT ELEMENTS' SIGNIFICANCE NEEDS TO BE DISCUSSED.
        // These were either used to keep track of Subscribers or used in the subscribe/unsubscribe functions to calculate the FS Ratio

        //mapping(address => bool) memberExists;  // To keep track of subscribers info
        // For iterable mapping

        mapping(address => uint256) members;
        mapping(uint256 => address) mapAddressMember; // This maps to the user
        // To calculate fair share of profit for a subscriber
        // The historical constant that is applied with (wnx0 + wnx1 + .... + wnxZ)
        // Read more in the repo: https://github.com/ethereum-push-notification-system
        mapping(address => uint256) memberLastUpdate;
    }

    /** MAPPINGS **/
    mapping(address => Channel) public channels;
    mapping(uint256 => address) public mapAddressChannels;
    mapping(address => string) public channelNotifSettings;
    mapping(address => uint256) public usersInterestClaimed;
    mapping(address => uint256) public usersInterestInWallet;

    /** STATE VARIABLES **/
    string public constant name = "EPNS CORE V4";

    uint256 ADJUST_FOR_FLOAT;

    address public epnsCommunicator;
    address public lendingPoolProviderAddress;
    address public daiAddress;
    address public aDaiAddress;
    address public admin;

    uint256 public channelsCount; // Record of total Channels in the protocol
    //  Helper Variables for FSRatio Calculation | GROUPS = CHANNELS
    uint256 public groupNormalizedWeight;
    uint256 public groupHistoricalZ;
    uint256 public groupLastUpdate;
    uint256 public groupFairShareCount;

    address private UNISWAP_V2_ROUTER;
    address private PUSH_TOKEN_ADDRESS;

    // Necessary variables for Defi
    uint256 public poolFunds;
    uint256 public REFERRAL_CODE;
    uint256 DELEGATED_CONTRACT_FEES;
    uint256 ADD_CHANNEL_MIN_POOL_CONTRIBUTION;
    uint256 ADD_CHANNEL_MAX_POOL_CONTRIBUTION;

    /** EVENTS **/
    event DeactivateChannel(address indexed channel);
    event ReactivateChannel(address indexed channel);
    event UpdateChannel(address indexed channel, bytes identity);
    event Withdrawal(address indexed to, address token, uint256 amount);
    event InterestClaimed(address indexed user, uint256 indexed amount);
    event AddChannel(
        address indexed channel,
        ChannelType indexed channelType,
        bytes identity
    );
    event ChannelNotifcationSettingsAdded(
        address _channel,
        uint256 totalNotifOptions,
        string _notifSettings,
        string _notifDescription
    );

    /* ************** 
    
    => MODIFIERS <=

    ***************/
    modifier onlyGov() {
        require(msg.sender == admin, "EPNSCore::onlyGov, user is not admin");
        _;
    }
    // TBD - Information -> onlyActivatedChannels redesigned
    modifier onlyActivatedChannels(address _channel) {
        require(
            channels[_channel].channelState == 1,
            "Channel Deactivated, Blocked or Doesn't Exist"
        );
        _;
    }
    // TBD - Information -> onlyUserWithNoChannel became onlyInactiveChannels
    modifier onlyInactiveChannels(address _channel) {
        require(
            channels[_channel].channelState == 0,
            "Channel is already activated "
        );
        _;
    }

    modifier onlyDeactivatedChannels(address _channel) {
        require(
            channels[_channel].channelState == 2,
            "Channel is already activated "
        );
        _;
    }

    modifier onlyUnblockedChannels(address _channel) {
        require(
            channels[_channel].channelState != 3,
            "Channel is Completely BLOCKED"
        );
        _;
    }

    // TBD - Information -> onlyChannelOwner redesigned
    modifier onlyChannelOwner(address _channel) {
        require(
            ((channels[_channel].channelState == 1 && msg.sender == _channel) ||
                (msg.sender == admin &&
                    _channel == 0x0000000000000000000000000000000000000000)),
            "Channel doesn't Exists or Invalid Channel Owner"
        );
        _;
    }

    modifier onlyUserAllowedChannelType(ChannelType _channelType) {
        require(
            (_channelType == ChannelType.InterestBearingOpen ||
                _channelType == ChannelType.InterestBearingMutual),
            "Channel Type Invalid"
        );

        _;
    }

    // THESE 3 USE USER struct, WILL HAVE TO REDEISGN THEM

    // modifier onlySubscribed(address _channel, address _subscriber) {
    //     require(channels[_channel].memberExists[_subscriber], "Subscriber doesn't Exists");
    //     _;
    // }

    /* ***************
        INITIALIZER

    *************** */

    function initialize(
        address _admin,
        address _lendingPoolProviderAddress,
        address _daiAddress,
        address _aDaiAddress,
        uint256 _referralCode
    ) public initializer returns (bool success) {
        // setup addresses
        admin = _admin; // multisig/timelock, also controls the proxy
        lendingPoolProviderAddress = _lendingPoolProviderAddress;
        daiAddress = _daiAddress;
        aDaiAddress = _aDaiAddress;
        REFERRAL_CODE = _referralCode;
        UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
        PUSH_TOKEN_ADDRESS = 0xf418588522d5dd018b425E472991E52EBBeEEEEE;

        DELEGATED_CONTRACT_FEES = 1 * 10**17; // 0.1 DAI to perform any delegate call

        ADD_CHANNEL_MIN_POOL_CONTRIBUTION = 50 ether; // 50 DAI or above to create the channel
        ADD_CHANNEL_MAX_POOL_CONTRIBUTION = 250000 * 50 * 10**18; // 250k DAI or below, we don't want channel to make a costly mistake as well

        groupLastUpdate = block.number;
        groupNormalizedWeight = ADJUST_FOR_FLOAT; // Always Starts with 1 * ADJUST FOR FLOAT

        ADJUST_FOR_FLOAT = 10**7;

        // Add EPNS Channels
        // First is for all users
        // Second is all channel alerter, amount deposited for both is 0
        // to save gas, emit both the events out
        // identity = payloadtype + payloadhash

        // EPNS ALL USERS
        emit AddChannel(
            admin,
            ChannelType.ProtocolNonInterest,
            "1+QmSbRT16JVF922yAB26YxWFD6DmGsnSHm8VBrGUQnXTS74"
        );
        _createChannel(admin, ChannelType.ProtocolNonInterest, 0); // should the owner of the contract be the channel? should it be admin in this case?

        // EPNS ALERTER CHANNEL
        emit AddChannel(
            0x0000000000000000000000000000000000000000,
            ChannelType.ProtocolNonInterest,
            "1+QmTCKYL2HRbwD6nGNvFLe4wPvDNuaYGr6RiVeCvWjVpn5s"
        );
        _createChannel(
            0x0000000000000000000000000000000000000000,
            ChannelType.ProtocolNonInterest,
            0
        );

        // Create Channel
        success = true;
    }

    //TBD - Use of onlyOwner and Setter function for communicator?
    function setEpnsCommunicatorAddress(address _commAddress)
        external
        onlyOwner
    {
        epnsCommunicator = _commAddress;
    }

    /* ***********************************
        Channel HELPER Functions

    **************************************/
    function getChannelState(address _channel) public returns (uint256 state) {
        state = channels[_channel].channelState;
    }

    /* ***********************************
        CHANNEL RELATED FUNCTIONALTIES

    **************************************/

    // TBD - IS THIS FUNCTION REQUIRED? It uses broadcastPublicKey function from EPNS Communicator
    //    /// @dev Create channel with fees and public key
    // function createChannelWithFeesAndPublicKey(ChannelType _channelType, bytes calldata _identity, bytes calldata _publickey,uint256 _amount)
    //     external onlyUserWithNoChannel onlyUserAllowedChannelType(_channelType) {
    //     // Save gas, Emit the event out
    //     emit AddChannel(msg.sender, _channelType, _identity);

    //     // Broadcast public key
    //     // @TODO Find a way to save cost

    //     // Will save gas
    //     if (!users[msg.sender].publicKeyRegistered) {
    //         _broadcastPublicKey(msg.sender, _publickey);
    //     }

    //     // Bubble down to create channel
    //     _createChannelWithFees(msg.sender, _channelType,_amount);
    // }

    /// @dev To update channel, only possible if 1 subscriber is present or this is governance
    function updateChannelMeta(address _channel, bytes calldata _identity)
        external
    {
        emit UpdateChannel(_channel, _identity);

        _updateChannelMeta(_channel);
    }

    // TBD - Getting subscribercount is difficult from Multi CHain-> Should we include PUSH Nodes for that purpose?
    /// @dev private function to update channel meta
    function _updateChannelMeta(address _channel)
        internal
        onlyChannelOwner(_channel)
    {
        // // check if special channel
        // if (msg.sender == governance && (_channel == governance || _channel == 0x0000000000000000000000000000000000000000 || _channel == address(this))) {
        //   // don't do check for 1 as these are special channels

        // }
        // else {
        //   // do check for 1
        //   require (channels[_channel].memberCount == 1, "Channel has external subscribers");
        // }

        channels[msg.sender].channelUpdateBlock = block.number;
    }

    /// @dev One time, Create Promoter Channel
    function createPromoterChannel()
        external
        onlyInactiveChannels(address(this))
    {
        // EPNS PROMOTER CHANNEL
        // Check the allowance and transfer funds
        IERC20(daiAddress).transferFrom(
            msg.sender,
            address(this),
            ADD_CHANNEL_MIN_POOL_CONTRIBUTION
        );

        // Then Add Promoter Channel
        emit AddChannel(
            address(this),
            ChannelType.ProtocolPromotion,
            "1+QmRcewnNpdt2DWYuud3LxHTwox2RqQ8uyZWDJ6eY6iHkfn"
        );

        // Call create channel after fees transfer
        _createChannelAfterTransferOfFees(
            address(this),
            ChannelType.ProtocolPromotion,
            ADD_CHANNEL_MIN_POOL_CONTRIBUTION
        );
    }

    /**
     * @notice An external function that allows users to Create their Own Channels by depositing a valid amount of DAI.
     * @dev    Only allows users to Create One Channel for a specific address.
     *         Only allows a Valid Channel Type to be assigned for the Channel Being created.
     *         Validates and Transfers the amount of DAI from the Channel Creator to this Contract Address
     *         Deposits the Funds the Lending Pool and creates the Channel for the msg.sender.
     * @param  _channelType the type of the Channel Being created
     * @param  _identity the bytes value of the identity of the Channel
     * @param  _amount Amount of DAI to be deposited before Creating the Channel
     **/
    function createChannelWithFees(
        ChannelType _channelType,
        bytes calldata _identity,
        uint256 _amount
    )
        external
        onlyInactiveChannels(msg.sender)
        onlyUserAllowedChannelType(_channelType)
    {
        // Save gas, Emit the event out
        emit AddChannel(msg.sender, _channelType, _identity);

        // Bubble down to create channel
        _createChannelWithFees(msg.sender, _channelType, _amount);
    }

    /// @dev add channel with fees
    function _createChannelWithFees(
        address _channel,
        ChannelType _channelType,
        uint256 _amount
    ) private {
        // Check if it's equal or above Channel Pool Contribution
        // removed allowance -
        require(
            _amount >= ADD_CHANNEL_MIN_POOL_CONTRIBUTION,
            "Insufficient Funds or max ceiling reached"
        );
        IERC20(daiAddress).safeTransferFrom(_channel, address(this), _amount);
        _createChannelAfterTransferOfFees(_channel, _channelType, _amount);
    }

    function _createChannelAfterTransferOfFees(
        address _channel,
        ChannelType _channelType,
        uint256 _amount
    ) private {
        // Deposit funds to pool
        _depositFundsToPool(_amount);

        // Call Create Channel
        _createChannel(_channel, _channelType, _amount);
    }

    /**
     * @notice Base Channel Creation Function that allows users to Create Their own Channels and Stores crucial details about the Channel being created
     * @dev    -Initializes the Channel Struct
     *         -Subscribes the Channel's Owner to Imperative EPNS Channels as well as their Own Channels
     *         -Increases Channel Counts and Readjusts the FS of Channels
     * @param _channel         address of the channel being Created
     * @param _channelType     The type of the Channel
     * @param _amountDeposited The total amount being deposited while Channel Creation
     **/
    function _createChannel(
        address _channel,
        ChannelType _channelType,
        uint256 _amountDeposited
    ) private {
        // Calculate channel weight
        uint256 _channelWeight = _amountDeposited.mul(ADJUST_FOR_FLOAT).div(
            ADD_CHANNEL_MIN_POOL_CONTRIBUTION
        );

        // Next create the channel and mark user as channellized
        channels[_channel].channelState = 1;

        channels[_channel].poolContribution = _amountDeposited;
        channels[_channel].channelType = _channelType;
        channels[_channel].channelStartBlock = block.number;
        channels[_channel].channelUpdateBlock = block.number;
        channels[_channel].channelWeight = _channelWeight;

        // Add to map of addresses and increment channel count
        mapAddressChannels[channelsCount] = _channel;
        channelsCount = channelsCount.add(1);

        // Readjust fair share if interest bearing
        if (
            _channelType == ChannelType.ProtocolPromotion ||
            _channelType == ChannelType.InterestBearingOpen ||
            _channelType == ChannelType.InterestBearingMutual
        ) {
            (
                groupFairShareCount,
                groupNormalizedWeight,
                groupHistoricalZ,
                groupLastUpdate
            ) = _readjustFairShareOfChannels(
                ChannelAction.ChannelAdded,
                _channelWeight,
                groupFairShareCount,
                groupNormalizedWeight,
                groupHistoricalZ,
                groupLastUpdate
            );
        }

        // Subscribe them to their own channel as well
        if (_channel != admin) {
            IEPNSCommunicator(epnsCommunicator).subscribeViaCore(
                _channel,
                _channel
            );
        }

        // All Channels are subscribed to EPNS Alerter as well, unless it's the EPNS Alerter channel iteself
        if (_channel != 0x0000000000000000000000000000000000000000) {
            IEPNSCommunicator(epnsCommunicator).subscribeViaCore(
                0x0000000000000000000000000000000000000000,
                _channel
            );
            IEPNSCommunicator(epnsCommunicator).subscribeViaCore(
                admin,
                _channel
            );
        }
    }

    // @notice - Deliminated Notification Settings string contains -> Total Notif Options + Notification Settings
    // For instance: 5+1-0+2-50-20-100+1-1+2-78-10-150
    // 5 -> Total Notification Options provided by a Channel owner

    // For Boolean Type Notif Options
    // 1-0 -> 1 stands for BOOLEAN type - 0 stands for Default Boolean Type for that Notifcation(set by Channel Owner), In this case FALSE.
    // 1-1 stands for BOOLEAN type - 1 stands for Default Boolean Type for that Notifcation(set by Channel Owner), In this case TRUE.

    // For SLIDER TYPE Notif Options
    // 2-50-20-100 -> 2 stands for SLIDER TYPE - 50 stands for Default Value for that Option - 20 is the Start Range of that SLIDER - 100 is the END Range of that SLIDER Option
    // 2-78-10-150 -> 2 stands for SLIDER TYPE - 78 stands for Default Value for that Option - 10 is the Start Range of that SLIDER - 150 is the END Range of that SLIDER Option

    // @param _notifOptions - Total Notification options provided by the Channel Owner
    // @param _notifSettings- Deliminated String of Notification Settings
    // @param _notifDescription - Description of each Notification that depicts the Purpose of that Notification

    function createChannelNotificationSettings(
        uint256 _notifOptions,
        string calldata _notifSettings,
        string calldata _notifDescription
    ) external onlyActivatedChannels(msg.sender) {
        string memory notifSetting = string(
            abi.encodePacked(
                Strings.toString(_notifOptions),
                "+",
                _notifSettings
            )
        );
        channelNotifSettings[msg.sender] = notifSetting;
        emit ChannelNotifcationSettingsAdded(
            msg.sender,
            _notifOptions,
            notifSetting,
            _notifDescription
        );
    }

    /**
     * @notice Allows Channel Owner to Deactivate his/her Channel for any period of Time. Channels Deactivated can be Activated again.
     * @dev    -Updates the State of the Channel(channelState) in the Channel's Struct.
     *         -Function can only be Called by Already Activated Channels
     *
     **/
    function deactivateChannel() external onlyActivatedChannels(msg.sender) {
        channels[msg.sender].channelState = 2;
        emit DeactivateChannel(msg.sender);
    }

    /**
     * @notice Allows Channel Owner to Reactivate his/her Channel again.
     * @dev    -Updates the State of the Channel(channelState) in the Channel's Struct.
     *         -Function can only be called by previously Deactivated Channels
     *
     **/
    function reActivateChannel() external onlyDeactivatedChannels(msg.sender) {
        channels[msg.sender].channelState = 1;
        emit ReactivateChannel(msg.sender);
    }

    /* ************** 
    
    => DEPOSIT & WITHDRAWAL of FUNDS<=

    *************** */

    function updateUniswapV2Address(address _newAddress) external onlyGov {
        UNISWAP_V2_ROUTER = _newAddress;
    }

    /// @dev deposit funds to pool
    function _depositFundsToPool(uint256 amount) private {
        // Got the funds, add it to the channels dai pool
        poolFunds = poolFunds.add(amount);

        // Next swap it via AAVE for aDAI
        // mainnet address, for other addresses: https://docs.aave.com/developers/developing-on-aave/deployed-contract-instances
        ILendingPoolAddressesProvider provider = ILendingPoolAddressesProvider(
            lendingPoolProviderAddress
        );
        ILendingPool lendingPool = ILendingPool(provider.getLendingPool());
        IERC20(daiAddress).approve(provider.getLendingPoolCore(), amount);

        // Deposit to AAVE
        lendingPool.deposit(daiAddress, amount, uint16(REFERRAL_CODE)); // set to 0 in constructor presently
    }

    /// @dev withdraw funds from pool
    function _withdrawFundsFromPool(uint256 ratio) private nonReentrant {
        uint256 totalBalanceWithProfit = IERC20(aDaiAddress).balanceOf(
            address(this)
        );

        uint256 totalProfit = totalBalanceWithProfit.sub(poolFunds);
        uint256 userAmount = totalProfit.mul(ratio);

        // adjust poolFunds first
        uint256 userAmountAdjusted = userAmount.div(ADJUST_FOR_FLOAT);
        poolFunds = poolFunds.sub(userAmountAdjusted);

        // Add to interest claimed
        usersInterestClaimed[msg.sender] = usersInterestClaimed[msg.sender].add(
            userAmountAdjusted
        );

        // Finally SWAP aDAI to PUSH, and TRANSFER TO USER
        swapAndTransferaDaiToPUSH(msg.sender, userAmountAdjusted);
        // Emit Event
        emit InterestClaimed(msg.sender, userAmountAdjusted);
    }

    /// @dev to withraw funds coming from donate
    function withdrawEthFunds() external onlyGov {
        uint256 bal = address(this).balance;

        payable(admin).transfer(bal);

        // Emit Event
        emit Withdrawal(msg.sender, daiAddress, bal);
    }

    /*
     * @dev Swaps aDai to PUSH Tokens and Transfers to the USER Address
     * @param _user address of the user that will recieve the PUSH Tokens
     * @param __userAmount the amount of aDai to be swapped and transferred
     */
    function swapAndTransferaDaiToPUSH(address _user, uint256 _userAmount)
        internal
        returns (bool)
    {
        IERC20(aDaiAddress).approve(UNISWAP_V2_ROUTER, _userAmount);

        address[] memory path;
        path[0] = aDaiAddress;
        path[1] = PUSH_TOKEN_ADDRESS;

        IUniswapV2Router(UNISWAP_V2_ROUTER).swapExactTokensForTokens(
            _userAmount,
            1,
            path,
            _user,
            block.timestamp
        );
        return true;
    }

    /* ************** 
    
    => FAIR SHARE RATIO CALCULATIONS <=

    *************** */
    /// @dev readjust fair share runs on channel addition, removal or update of channel
    function _readjustFairShareOfChannels(
        ChannelAction _action,
        uint256 _channelWeight,
        uint256 _groupFairShareCount,
        uint256 _groupNormalizedWeight,
        uint256 _groupHistoricalZ,
        uint256 _groupLastUpdate
    )
        private
        view
        returns (
            uint256 groupNewCount,
            uint256 groupNewNormalizedWeight,
            uint256 groupNewHistoricalZ,
            uint256 groupNewLastUpdate
        )
    {
        // readjusts the group count and do deconstruction of weight
        uint256 groupModCount = _groupFairShareCount;
        uint256 prevGroupCount = groupModCount;

        uint256 totalWeight;
        uint256 adjustedNormalizedWeight = _groupNormalizedWeight; //_groupNormalizedWeight;

        // Increment or decrement count based on flag
        if (_action == ChannelAction.ChannelAdded) {
            groupModCount = groupModCount.add(1);

            totalWeight = adjustedNormalizedWeight.mul(prevGroupCount);
            totalWeight = totalWeight.add(_channelWeight);
        } else if (_action == ChannelAction.ChannelRemoved) {
            groupModCount = groupModCount.sub(1);

            totalWeight = adjustedNormalizedWeight.mul(prevGroupCount);
            totalWeight = totalWeight.sub(_channelWeight);
        } else if (_action == ChannelAction.ChannelUpdated) {
            totalWeight = adjustedNormalizedWeight.mul(prevGroupCount.sub(1));
            totalWeight = totalWeight.add(_channelWeight);
        } else {
            revert("Invalid Channel Action");
        }

        // now calculate the historical constant
        // z = z + nxw
        // z is the historical constant
        // n is the previous count of group fair share
        // x is the differential between the latest block and the last update block of the group
        // w is the normalized average of the group (ie, groupA weight is 1 and groupB is 2 then w is (1+2)/2 = 1.5)
        uint256 n = groupModCount;
        uint256 x = block.number.sub(_groupLastUpdate);
        uint256 w = totalWeight.div(groupModCount);
        uint256 z = _groupHistoricalZ;

        uint256 nx = n.mul(x);
        uint256 nxw = nx.mul(w);

        // Save Historical Constant and Update Last Change Block
        z = z.add(nxw);

        if (n == 1) {
            // z should start from here as this is first channel
            z = 0;
        }

        // Update return variables
        groupNewCount = groupModCount;
        groupNewNormalizedWeight = w;
        groupNewHistoricalZ = z;
        groupNewLastUpdate = block.number;
    }

    function getChainId() internal pure returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }
}
