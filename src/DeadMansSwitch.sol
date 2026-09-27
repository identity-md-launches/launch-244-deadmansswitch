// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A Sepolia test-ETH toy. Not a custody or inheritance product.
/// @dev No administrative role, token integration, or initialization step.
contract DeadMansSwitch {
    uint256 public constant MIN_PERIOD = 1 days;
    uint256 public constant MAX_PERIOD = 365 days;
    uint256 public constant RECOVERY_DELAY = 365 days;

    struct Switch {
        address depositor;
        address beneficiary;
        uint256 balance;
        uint256 period;
        uint256 lastPing;
        bool closed;
    }

    mapping(uint256 => Switch) private _switches;
    uint256 public switchCount;
    uint256 private _guard = 1;

    error UnknownSwitch(uint256 id);
    error ClosedSwitch(uint256 id);
    error UnauthorizedDepositor();
    error UnauthorizedBeneficiary();
    error AlreadyLapsed();
    error NotLapsed();
    error RecoveryNotAvailable();
    error InvalidBeneficiary();
    error InvalidPeriod();
    error InvalidAmount();
    error InvalidRecipient();
    error EtherTransferFailed();
    error ReentrantCall();

    event Created(
        uint256 indexed id,
        address indexed depositor,
        address indexed beneficiary,
        uint256 balance,
        uint256 period,
        uint256 lastPing
    );
    event Pinged(uint256 indexed id, address indexed depositor, uint256 lastPing);
    event Deposited(uint256 indexed id, address indexed depositor, uint256 amount, uint256 lastPing);
    event Withdrawn(uint256 indexed id, address indexed depositor, uint256 amount, uint256 lastPing);
    event BeneficiaryChanged(uint256 indexed id, address indexed depositor, address indexed newBeneficiary);
    event PeriodChanged(uint256 indexed id, address indexed depositor, uint256 period, uint256 lastPing);
    event Claimed(uint256 indexed id, address indexed beneficiary, address to, uint256 amount);
    event Reclaimed(uint256 indexed id, address indexed depositor, address to, uint256 amount);

    constructor() {}

    /// @dev Shared across all mutations: an ETH receiver cannot mutate any switch in a callback.
    modifier nonReentrant() {
        if (_guard != 1) revert ReentrantCall();
        _guard = 2;
        _;
        _guard = 1;
    }

    /// @notice Creates an active switch, optionally with test ETH, and returns its id (starting at 1).
    function create(address beneficiary, uint256 period) external payable nonReentrant returns (uint256 id) {
        _checkBeneficiary(beneficiary, msg.sender);
        _checkPeriod(period);
        id = ++switchCount;
        _switches[id] = Switch(msg.sender, beneficiary, msg.value, period, block.timestamp, false);
        emit Created(id, msg.sender, beneficiary, msg.value, period, block.timestamp);
    }

    function ping(uint256 id) external nonReentrant {
        Switch storage info = _activeDepositorSwitch(id);
        info.lastPing = block.timestamp;
        emit Pinged(id, msg.sender, block.timestamp);
    }

    function deposit(uint256 id) external payable nonReentrant {
        Switch storage info = _activeDepositorSwitch(id);
        if (msg.value == 0) revert InvalidAmount();
        info.balance += msg.value;
        info.lastPing = block.timestamp;
        emit Deposited(id, msg.sender, msg.value, block.timestamp);
    }

    /// @notice Withdraws to the depositor. A full withdrawal leaves the switch open.
    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        Switch storage info = _activeDepositorSwitch(id);
        if (amount == 0 || amount > info.balance) revert InvalidAmount();
        info.balance -= amount;
        info.lastPing = block.timestamp;
        emit Withdrawn(id, msg.sender, amount, block.timestamp);
        _send(msg.sender, amount);
    }

    function setBeneficiary(uint256 id, address newBeneficiary) external nonReentrant {
        Switch storage info = _activeDepositorSwitch(id);
        _checkBeneficiary(newBeneficiary, info.depositor);
        info.beneficiary = newBeneficiary;
        info.lastPing = block.timestamp;
        emit BeneficiaryChanged(id, msg.sender, newBeneficiary);
    }

    function setPeriod(uint256 id, uint256 period) external nonReentrant {
        Switch storage info = _activeDepositorSwitch(id);
        _checkPeriod(period);
        info.period = period;
        info.lastPing = block.timestamp;
        emit PeriodChanged(id, msg.sender, period, block.timestamp);
    }

    /// @notice Beneficiary may close and collect from the exact lapse timestamp onward.
    function claim(uint256 id, address to) external nonReentrant {
        Switch storage info = _openSwitch(id);
        if (msg.sender != info.beneficiary) revert UnauthorizedBeneficiary();
        if (block.timestamp < info.lastPing + info.period) revert NotLapsed();
        if (to == address(0)) revert InvalidRecipient();
        uint256 amount = _close(info);
        emit Claimed(id, msg.sender, to, amount);
        _send(to, amount);
    }

    /// @notice Depositor may recover after one further year. Beneficiary can still win this race.
    function reclaim(uint256 id, address to) external nonReentrant {
        Switch storage info = _openSwitch(id);
        if (msg.sender != info.depositor) revert UnauthorizedDepositor();
        if (block.timestamp < info.lastPing + info.period + RECOVERY_DELAY) revert RecoveryNotAvailable();
        if (to == address(0)) revert InvalidRecipient();
        uint256 amount = _close(info);
        emit Reclaimed(id, msg.sender, to, amount);
        _send(to, amount);
    }

    /// @notice Closed switches remain readable for history; nonexistent ids revert.
    function switchInfo(uint256 id)
        external
        view
        returns (address depositor, address beneficiary, uint256 balance, uint256 period, uint256 lastPing, bool closed)
    {
        Switch storage info = _existingSwitch(id);
        return (info.depositor, info.beneficiary, info.balance, info.period, info.lastPing, info.closed);
    }

    function timeLeft(uint256 id) external view returns (uint256) {
        Switch storage info = _existingSwitch(id);
        uint256 deadline = info.lastPing + info.period;
        return block.timestamp >= deadline ? 0 : deadline - block.timestamp;
    }

    function _existingSwitch(uint256 id) private view returns (Switch storage info) {
        info = _switches[id];
        if (info.depositor == address(0)) revert UnknownSwitch(id);
    }

    function _openSwitch(uint256 id) private view returns (Switch storage info) {
        info = _existingSwitch(id);
        if (info.closed) revert ClosedSwitch(id);
    }

    function _activeDepositorSwitch(uint256 id) private view returns (Switch storage info) {
        info = _openSwitch(id);
        if (msg.sender != info.depositor) revert UnauthorizedDepositor();
        if (block.timestamp >= info.lastPing + info.period) revert AlreadyLapsed();
    }

    function _checkBeneficiary(address beneficiary, address depositor) private pure {
        if (beneficiary == address(0) || beneficiary == depositor) revert InvalidBeneficiary();
    }

    function _checkPeriod(uint256 period) private pure {
        if (period < MIN_PERIOD || period > MAX_PERIOD) revert InvalidPeriod();
    }

    function _close(Switch storage info) private returns (uint256 amount) {
        amount = info.balance;
        info.balance = 0;
        info.closed = true;
    }

    function _send(address to, uint256 amount) private {
        (bool sent,) = to.call{value: amount}("");
        if (!sent) revert EtherTransferFailed();
    }
}
