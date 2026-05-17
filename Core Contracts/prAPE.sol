// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IPrimalProtocol {
    function getCurrentIndex() external view returns (uint256);

    function handleTransfer(
        address from,
        address to,
        uint256 scaledAmount
    ) external;
}

contract PrimalApe is ERC20, Ownable {
    uint256 public constant PRECISION = 1e18;

    address public protocol;

    bool public paused;

    // =====================================================
    // SCALED ACCOUNTING
    // =====================================================

    mapping(address => uint256) internal _scaledBalances;
    uint256 internal _scaledTotalSupply;

    // =====================================================
    // EVENTS
    // =====================================================

    event ProtocolUpdated(address indexed protocol);
    event Paused(bool state);

    // =====================================================
    // MODIFIERS
    // =====================================================

    modifier onlyProtocol() {
        require(msg.sender == protocol, "ONLY_PROTOCOL");
        _;
    }

    modifier notPaused() {
        require(!paused, "PAUSED");
        _;
    }

    // =====================================================
    // CONSTRUCTOR
    // =====================================================

    constructor() ERC20("Primal Ape", "prAPE") Ownable(msg.sender) {}

    // =====================================================
    // CONFIG
    // =====================================================

    function setProtocol(address _protocol) external onlyOwner {
        require(protocol == address(0), "ALREADY_SET");
        require(_protocol != address(0), "INVALID");

        protocol = _protocol;

        emit ProtocolUpdated(_protocol);
    }

    function setPaused(bool state) external onlyOwner {
        paused = state;
        emit Paused(state);
    }

    // =====================================================
    // INDEX
    // =====================================================

    function getIndex() public view returns (uint256) {
        if (protocol == address(0)) return PRECISION;
        return IPrimalProtocol(protocol).getCurrentIndex();
    }

    // =====================================================
    // INTERNAL SCALE
    // =====================================================

    function _scale(uint256 amount) internal view returns (uint256) {
        uint256 index = getIndex();
        if (index == 0) return 0;
        return (amount * PRECISION) / index;
    }

    function _unscale(uint256 scaled) internal view returns (uint256) {
        return (scaled * getIndex()) / PRECISION;
    }

    // =====================================================
    // ERC20 OVERRIDES (VIEW LAYER)
    // =====================================================

    function totalSupply() public view override returns (uint256) {
        return _unscale(_scaledTotalSupply);
    }

    function balanceOf(address user) public view override returns (uint256) {
        return _unscale(_scaledBalances[user]);
    }

    function scaledBalanceOf(address user) external view returns (uint256) {
        return _scaledBalances[user];
    }

    function scaledTotalSupply() external view returns (uint256) {
        return _scaledTotalSupply;
    }

    // =====================================================
    // MINT / BURN (ONLY PROTOCOL)
    // =====================================================

    function mint(address to, uint256 amount) external onlyProtocol {
        require(to != address(0), "ZERO");
        require(amount > 0, "ZERO");

        uint256 scaled = _scale(amount);

        _scaledBalances[to] += scaled;
        _scaledTotalSupply += scaled;

        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyProtocol {
        require(from != address(0), "ZERO");
        require(amount > 0, "ZERO");

        uint256 scaled = _scale(amount);

        require(_scaledBalances[from] >= scaled, "INSUFFICIENT");

        _scaledBalances[from] -= scaled;
        _scaledTotalSupply -= scaled;

        emit Transfer(from, address(0), amount);
    }

    // =====================================================
    // TRANSFERS
    // =====================================================

    function transfer(
        address to,
        uint256 amount
    ) public override notPaused returns (bool) {
        _transferScaled(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override notPaused returns (bool) {
        uint256 allowed = allowance(from, msg.sender);
        require(allowed >= amount, "ALLOWANCE");

        _approve(from, msg.sender, allowed - amount);

        _transferScaled(from, to, amount);
        return true;
    }

    function _transferScaled(
        address from,
        address to,
        uint256 amount
    ) internal {
        require(from != address(0) && to != address(0), "ZERO");
        require(amount > 0, "ZERO");

        uint256 index = getIndex();

        uint256 scaledAmount = (amount * PRECISION) / index;

        require(_scaledBalances[from] >= scaledAmount, "BALANCE");

        _scaledBalances[from] -= scaledAmount;
        _scaledBalances[to] += scaledAmount;

        if (protocol != address(0)) {
            IPrimalProtocol(protocol).handleTransfer(from, to, scaledAmount);
        }

        emit Transfer(from, to, amount);
    }
}