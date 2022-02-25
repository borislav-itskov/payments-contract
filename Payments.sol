// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract Payments is ReentrancyGuard {
    event TimelockedPaymentCreated(
        uint _paymentId,
        address _from,
        address _to,
        uint _value,
        uint64 time,
        bool _isToken
    );
    event TimeLockedWithdraw(uint _paymentId, address _to, uint _value, bool _isToken);

    event MultiSigPaymentCreated(
        uint _paymentId,
        address _from,
        address _to,
        uint _numApprovalsRequired,
        address[] approvers,
        uint _value,
        bool _isToken
    );
    event MultiSigApproved(uint _paymentId, address _approver);
    event MultiSigExecuted(uint _paymentId, address _to, uint _value);

    event StreamPaymentCreated(
        uint _paymentId,
        address _from,
        address _to,
        uint _value,
        uint64 start,
        uint64 duration,
        bool _isToken
    );
    event VestedWithdraw(uint _paymentId, address _to, uint _value, bool _isToken);

    IERC20 public _token;

    uint private _paymentId;
    uint private _multiSigPaymentId;
    uint private _streamPaymentId;

    struct TimeLockedPayment {
        uint amount;
        uint64 time;
        address beneficiary;
        bool paid;
        bool isToken;
    }

    struct MultiSigPayment {
        uint amount;
        uint numApprovalsRequired;
        uint numApprovals;
        address beneficiary;
        address[] approvers;
        bool executed;
        bool isToken;
    }

    struct StreamPayment {
        uint amount;
        uint released;
        uint64 start;
        uint64 duration;
        address beneficiary;
        bool isToken;
    }

    mapping(uint => TimeLockedPayment) private _timelockedPayments;

    mapping(uint => MultiSigPayment) private _multiSigPayments;
    mapping(uint => mapping(address => bool)) private _isApprover;
    mapping(uint => mapping(address => bool)) private _isApproved;

    mapping(uint => StreamPayment) private _streamPayments;

    modifier noZeroAddress(address add) {
        require(add != address(0), "Invalid address");
        _;
    }

    modifier paymentExists(uint id, uint maxProductId) {
        require(id < maxProductId, "Payment does not exist");
        _;
    }

    modifier approved(uint id) {
        require(
            _multiSigPayments[id].numApprovalsRequired <= _multiSigPayments[id].numApprovals,
            "Not enough confirmations"
        );
        _;
    }

    modifier canWithdrawTimelocked(uint id) {
        require(_timelockedPayments[id].paid == false, "Already withdrawn");
        require(_timelockedPayments[id].beneficiary == msg.sender, "Action not allowed");
        require(_timelockedPayments[id].time < block.timestamp, "Time has not passed");
        _;
    }

    modifier futureTime(uint time) {
        require(time > block.timestamp, "Time has already passed");
        _;
    }

    constructor(IERC20 token) {
        _token = token;
    }

    function createTimelockedPayment(address beneficiary, uint64 time) public payable {
        _createTimelockedPayment(beneficiary, time, msg.value, false);
    }

    function createTimelockedPaymentToken(address beneficiary, uint64 time, uint amount) public {
        _createTimelockedPayment(beneficiary, time, amount, true);
    }

    function withdrawTimePayment(uint id) external
        nonReentrant paymentExists(id, _paymentId) canWithdrawTimelocked(id) {
        _timelockedPayments[id].paid = true;

        if (_timelockedPayments[id].isToken) {
            _token.transfer(msg.sender, _timelockedPayments[id].amount);
        }
        else {
            Address.sendValue(payable(msg.sender), _timelockedPayments[id].amount);
        }

        emit TimeLockedWithdraw(id, msg.sender, _timelockedPayments[id].amount, _timelockedPayments[id].isToken);
    }

    function createMultiSigPayment(
        address beneficiary,
        uint numApprovalsRequired,
        address[] memory approvers
    ) public payable noZeroAddress(beneficiary) {
        _createMultiSigPayment(
            beneficiary,
            numApprovalsRequired,
            approvers,
            msg.value,
            false
        );
    }

    function createMultiSigPaymentToken(
        address beneficiary,
        uint numApprovalsRequired,
        address[] memory approvers,
        uint amount
    ) public noZeroAddress(beneficiary) {
        _createMultiSigPayment(
            beneficiary,
            numApprovalsRequired,
            approvers,
            amount,
            true
        );
    }

    function approve(uint id) public paymentExists(id, _multiSigPaymentId) {
        require(_isApprover[id][msg.sender], "Not an approver");
        require(!_isApproved[id][msg.sender], "Already approved");

        _multiSigPayments[id].numApprovals++;
        emit MultiSigApproved(id, msg.sender);
    }

    function executeMultiSigPayment(uint id) external
        paymentExists(id, _multiSigPaymentId)
        approved(id)
        nonReentrant {
        require(_multiSigPayments[id].beneficiary == msg.sender, "Action not allowed");
        require(_multiSigPayments[id].executed == false, "Already executed");

        _multiSigPayments[id].executed = true;

        if (_multiSigPayments[id].isToken) {
            _token.transfer(msg.sender, _multiSigPayments[id].amount);
        }
        else {
            Address.sendValue(payable(msg.sender), _multiSigPayments[id].amount);
        }

        emit MultiSigExecuted(id, msg.sender, _multiSigPayments[id].amount);
    }

    function createStreamPayment(address beneficiary, uint64 start, uint64 duration) public payable {
        _createStreamPayment(beneficiary, start, duration, msg.value, false);
    }

    function createStreamPaymentToken(address beneficiary, uint64 start, uint64 duration, uint amount) public {
        _createStreamPayment(beneficiary, start, duration, amount, true);
    }

    function withdrawVested(uint id) external nonReentrant paymentExists(id, _streamPaymentId) {
        require(_streamPayments[id].beneficiary == msg.sender, "Action not allowed");
        require(_streamPayments[id].start > block.timestamp, "Vesting has not started, yet");

        uint amountForPeriod = _vestingSchedule(uint64(block.timestamp), _streamPayments[id]);
        uint releasable = amountForPeriod - _streamPayments[id].released;
        _streamPayments[id].released += releasable;

        if (_streamPayments[id].isToken) {
            _token.transfer(msg.sender, releasable);
        }
        else {
            Address.sendValue(payable(msg.sender), releasable);
        }

        emit VestedWithdraw(id, msg.sender, releasable, _streamPayments[id].isToken);
    }

    function _vestingSchedule(
        uint64 timestamp,
        StreamPayment memory payment
    ) internal view virtual returns (uint) {
        if (timestamp < payment.start) {
            return 0;
        } else if (timestamp > payment.start + payment.duration) {
            return payment.amount;
        } else {
            return (payment.amount * (timestamp - payment.start)) / payment.duration;
        }
    }

    function _createTimelockedPayment(address beneficiary, uint64 time, uint amount, bool isToken)
        private noZeroAddress(beneficiary) futureTime(time) {
        _timelockedPayments[_paymentId] = TimeLockedPayment(amount, time, beneficiary, false, isToken);

        if (isToken) {
            _token.transferFrom(msg.sender, address(this), amount);
        }

        emit TimelockedPaymentCreated(_paymentId, msg.sender, beneficiary, amount, time, isToken);

        _paymentId++;
    }

    function _createMultiSigPayment(
        address beneficiary,
        uint numApprovalsRequired,
        address[] memory approvers,
        uint amount,
        bool isToken
    ) private {
        for (uint i = 0; i < approvers.length; i++) {
            address approver = approvers[i];

            require(approver != address(0), "invalid approver");
            require(!_isApprover[_multiSigPaymentId][approver], "approver not unique");

            _isApprover[_multiSigPaymentId][approver] = true;
        }

        _multiSigPayments[_multiSigPaymentId] = MultiSigPayment({
            amount: amount,
            numApprovalsRequired: numApprovalsRequired,
            numApprovals: 0,
            beneficiary: beneficiary,
            approvers: approvers,
            executed: false,
            isToken: isToken
        });

        if (isToken) {
            _token.transferFrom(msg.sender, address(this), amount);
        }

        emit MultiSigPaymentCreated(
            _multiSigPaymentId,
            msg.sender,
            beneficiary,
            numApprovalsRequired,
            approvers,
            amount,
            isToken
        );

        _multiSigPaymentId++;
    }

    function _createStreamPayment(address beneficiary, uint64 start, uint64 duration, uint amount, bool isToken)
        private noZeroAddress(beneficiary) futureTime(start) {
        _streamPayments[_streamPaymentId] = StreamPayment(amount, 0, start, duration, beneficiary, isToken);

        if (isToken) {
            _token.transferFrom(msg.sender, address(this), amount);
        }

        emit StreamPaymentCreated(
            _streamPaymentId,
            msg.sender,
            beneficiary,
            amount,
            start,
            duration,
            isToken
        );

        _streamPaymentId++;
    }
}
