// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title OUSD Token Contract
 * @dev ERC20 compatible contract for OUSD
 * @dev Implements an elastic supply
 * @author Origin Protocol Inc
 */
import { Governable } from "../governance/Governable.sol";
import {console} from "forge-std/Test.sol";

/**
 * NOTE that this is an ERC20 token but the invariant that the sum of
 * balanceOf(x) for all x is not >= totalSupply(). This is a consequence of the
 * rebasing design. Any integrations with OUSD should be aware.
 */

contract OUSD is Governable {

    event TotalSupplyUpdatedHighres(
        uint256 totalSupply,
        uint256 rebasingCredits,
        uint256 rebasingCreditsPerToken
    );
    event AccountRebasingEnabled(address account);
    event AccountRebasingDisabled(address account);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    enum RebaseOptions {
        NotSet,
        OptOut,
        OptIn,
        YieldDelegationSource,
        YieldDelegationTarget
    }

    uint256 private constant MAX_SUPPLY = ~uint128(0); // (2^128) - 1
    uint256 public _totalSupply;
    mapping(address => mapping(address => uint256)) private _allowances;
    address public vaultAddress = address(0);
    mapping(address => uint256) private _creditBalances;
    uint256 private _rebasingCredits;
    uint256 private _rebasingCreditsPerToken;
    // Frozen address/credits are non rebasing (value is held in contracts which
    // do not receive yield unless they explicitly opt in)
    uint256 public nonRebasingSupply;
    mapping(address => uint256) public nonRebasingCreditsPerToken;
    mapping(address => RebaseOptions) public rebaseState;
    mapping(address => uint256) public isUpgraded;
    mapping(address => address) public yieldTo;
    mapping(address => address) public yieldFrom;
    mapping(address => uint256) public aintMoney;

    uint256 private constant RESOLUTION_INCREASE = 1e9;

    function initialize(
        string calldata,
        string calldata,
        address _vaultAddress,
        uint256 _initialCreditsPerToken
    ) external onlyGovernor {
        require(vaultAddress == address(0), "Already initialized");
        require(_rebasingCreditsPerToken == 0, "Already initialized");
        _rebasingCreditsPerToken = _initialCreditsPerToken;
        vaultAddress = _vaultAddress;
    }

    function name() external pure returns (string memory) {
        return "Origin Dollar";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function symbol() external pure returns (string memory) {
        return "OUSD";
    }

    /**
     * @dev Verifies that the caller is the Vault contract
     */
    modifier onlyVault() {
        require(vaultAddress == msg.sender, "Caller is not the Vault");
        _;
    }

    /**
     * @return The total supply of OUSD.
     */
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @return Low resolution rebasingCreditsPerToken
     */
    function rebasingCreditsPerToken() public view returns (uint256) {
        return _rebasingCreditsPerToken / RESOLUTION_INCREASE;
    }

    /**
     * @return Low resolution total number of rebasing credits
     */
    function rebasingCredits() public view returns (uint256) {
        return _rebasingCredits / RESOLUTION_INCREASE;
    }

    /**
     * @return High resolution rebasingCreditsPerToken
     */
    function rebasingCreditsPerTokenHighres() public view returns (uint256) {
        return _rebasingCreditsPerToken;
    }

    /**
     * @return High resolution total number of rebasing credits
     */
    function rebasingCreditsHighres() public view returns (uint256) {
        return _rebasingCredits;
    }

    /**
     * @dev Gets the balance of the specified address.
     * @param _account Address to query the balance of.
     * @return A uint256 representing the amount of base units owned by the
     *         specified address.
     */
    function balanceOf(address _account)
        public
        view
        returns (uint256)
    {
        return
            _creditBalances[_account] * 1e18 / _creditsPerToken(_account) 
            - aintMoney[_account];
    }

    /**
     * @dev Gets the credits balance of the specified address.
     * @dev Backwards compatible with old low res credits per token.
     * @param _account The address to query the balance of.
     * @return (uint256, uint256) Credit balance and credits per token of the
     *         address
     */
    function creditsBalanceOf(address _account)
        public
        view
        returns (uint256, uint256)
    {
        uint256 cpt = _creditsPerToken(_account);
        if (cpt == 1e27) {
            // For a period before the resolution upgrade, we created all new
            // contract accounts at high resolution. Since they are not changing
            // as a result of this upgrade, we will return their true values
            return (_creditBalances[_account], cpt);
        } else {
            return (
                _creditBalances[_account] / RESOLUTION_INCREASE,
                cpt / RESOLUTION_INCREASE
            );
        }
    }

    /**
     * @dev Gets the credits balance of the specified address.
     * @param _account The address to query the balance of.
     * @return (uint256, uint256, bool) Credit balance, credits per token of the
     *         address, and isUpgraded
     */
    function creditsBalanceOfHighres(address _account)
        public
        view
        returns (
            uint256,
            uint256,
            bool
        )
    {
        return (
            _creditBalances[_account],
            _creditsPerToken(_account),
            isUpgraded[_account] == 1
        );
    }

    /**
     * @dev Transfer tokens to a specified address.
     * @param _to the address to transfer to.
     * @param _value the amount to be transferred.
     * @return true on success.
     */
    function transfer(address _to, uint256 _value)
        public
        returns (bool)
    {
        require(_to != address(0), "Transfer to zero address");
        require(
            _value <= balanceOf(msg.sender),
            "Transfer greater than balance"
        );

        _executeTransfer(msg.sender, _to, _value);

        emit Transfer(msg.sender, _to, _value);

        return true;
    }

    /**
     * @dev Transfer tokens from one address to another.
     * @param _from The address you want to send tokens from.
     * @param _to The address you want to transfer to.
     * @param _value The amount of tokens to be transferred.
     */
    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) public returns (bool) {
        require(_to != address(0), "Transfer to zero address");
        require(_value <= balanceOf(_from), "Transfer greater than balance");

        _allowances[_from][msg.sender] = _allowances[_from][msg.sender] - _value;

        _executeTransfer(_from, _to, _value);

        emit Transfer(_from, _to, _value);

        return true;
    }

    /**
     * @dev Update the count of non rebasing credits in response to a transfer
     * @param _from The address you want to send tokens from.
     * @param _to The address you want to transfer to.
     * @param _value Amount of OUSD to transfer
     */
    function _executeTransfer(
        address _from,
        address _to,
        uint256 _value
    ) internal {
        if(_from == _to){
            return;
        }

        (int256 fromRebasingCreditsDiff, int256 fromNonRebasingSupplyDiff) 
            = _adjustAccount(_from, -int256(_value));
        (int256 toRebasingCreditsDiff, int256 toNonRebasingSupplyDiff) 
            = _adjustAccount(_to, int256(_value));

        _adjustGlobals(
            fromRebasingCreditsDiff + toRebasingCreditsDiff,
            fromNonRebasingSupplyDiff + toNonRebasingSupplyDiff
        );
    }

    function _adjustAccount(address account, int256 balanceChange) internal returns (int256 rebasingCreditsDiff, int256 nonRebasingSupplyDiff) {
        int256 currentBalance = int256(balanceOf(account));
        int256 newBalance = currentBalance + balanceChange;
        if(newBalance < 0){
            revert("Transfer amount exceeds balance"); // Should never trigger
        }
        if(_isNonRebasingAccount(account)){
            nonRebasingSupplyDiff = balanceChange;
            if(nonRebasingCreditsPerToken[account]!=1e27){
                nonRebasingCreditsPerToken[account] = 1e27;
            }
            _creditBalances[account] = uint256(newBalance) * 1e9;
        } else {
            int256 newCredits = ((newBalance) * int256(_rebasingCreditsPerToken) + 1e18 - 1) / 1e18;
            rebasingCreditsDiff = newCredits - int256(_creditBalances[account]);
            _creditBalances[account] = uint256(newCredits);
        }
    }

    function _adjustGlobals(int256 rebasingCreditsDiff, int256 nonRebasingSupplyDiff) internal {
        if(rebasingCreditsDiff !=0){
            if (uint256(int256(_rebasingCredits) + rebasingCreditsDiff) < 0){
                revert("underflow");
            }
            _rebasingCredits = uint256(int256(_rebasingCredits) + rebasingCreditsDiff);
        }
        if(nonRebasingSupplyDiff !=0){
            if (int256(nonRebasingSupply) + nonRebasingSupplyDiff < 0){
                revert("underflow");
            }
            nonRebasingSupply = uint256(int256(nonRebasingSupply) + nonRebasingSupplyDiff);
        }
    }

    /**
     * @dev Function to check the amount of tokens that _owner has allowed to
     *      `_spender`.
     * @param _owner The address which owns the funds.
     * @param _spender The address which will spend the funds.
     * @return The number of tokens still available for the _spender.
     */
    function allowance(address _owner, address _spender)
        public
        view
        returns (uint256)
    {
        return _allowances[_owner][_spender];
    }

    /**
     * @dev Approve the passed address to spend the specified amount of tokens
     *      on behalf of msg.sender. This method is included for ERC20
     *      compatibility. `increaseAllowance` and `decreaseAllowance` should be
     *      used instead.
     *
     *      Changing an allowance with this method brings the risk that someone
     *      may transfer both the old and the new allowance - if they are both
     *      greater than zero - if a transfer transaction is mined before the
     *      later approve() call is mined.
     * @param _spender The address which will spend the funds.
     * @param _value The amount of tokens to be spent.
     */
    function approve(address _spender, uint256 _value)
        public
        returns (bool)
    {
        _allowances[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
        return true;
    }

    /**
     * @dev Increase the amount of tokens that an owner has allowed to
     *      `_spender`.
     *      This method should be used instead of approve() to avoid the double
     *      approval vulnerability described above.
     * @param _spender The address which will spend the funds.
     * @param _addedValue The amount of tokens to increase the allowance by.
     */
    function increaseAllowance(address _spender, uint256 _addedValue)
        public
        returns (bool)
    {
        _allowances[msg.sender][_spender] = _allowances[msg.sender][_spender]
            + _addedValue;
        emit Approval(msg.sender, _spender, _allowances[msg.sender][_spender]);
        return true;
    }

    /**
     * @dev Decrease the amount of tokens that an owner has allowed to
            `_spender`.
     * @param _spender The address which will spend the funds.
     * @param _subtractedValue The amount of tokens to decrease the allowance
     *        by.
     */
    function decreaseAllowance(address _spender, uint256 _subtractedValue)
        public
        returns (bool)
    {
        uint256 oldValue = _allowances[msg.sender][_spender];
        if (_subtractedValue >= oldValue) {
            _allowances[msg.sender][_spender] = 0;
        } else {
            _allowances[msg.sender][_spender] = oldValue - _subtractedValue;
        }
        emit Approval(msg.sender, _spender, _allowances[msg.sender][_spender]);
        return true;
    }

    /**
     * @dev Mints new tokens, increasing totalSupply.
     */
    function mint(address _account, uint256 _amount) external onlyVault {
        _mint(_account, _amount);
    }

    /**
     * @dev Creates `_amount` tokens and assigns them to `_account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements
     *
     * - `to` cannot be the zero address.
     */
    function _mint(address _account, uint256 _amount) internal nonReentrant {
        require(_account != address(0), "Mint to the zero address");

        (int256 toRebasingCreditsDiff, int256 toNonRebasingSupplyDiff) 
            = _adjustAccount(_account, int256(_amount));
        _adjustGlobals(toRebasingCreditsDiff, toNonRebasingSupplyDiff);
        _totalSupply = _totalSupply + _amount;

        require(_totalSupply < MAX_SUPPLY, "Max supply");
        emit Transfer(address(0), _account, _amount);
    }

    /**
     * @dev Burns tokens, decreasing totalSupply.
     */
    function burn(address account, uint256 amount) external onlyVault {
        _burn(account, amount);
    }

    /**
     * @dev Destroys `_amount` tokens from `_account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements
     *
     * - `_account` cannot be the zero address.
     * - `_account` must have at least `_amount` tokens.
     */
    function _burn(address _account, uint256 _amount) internal nonReentrant {
        require(_account != address(0), "Burn from the zero address");
        if (_amount == 0) {
            return;
        }

        (int256 toRebasingCreditsDiff, int256 toNonRebasingSupplyDiff) 
            = _adjustAccount(_account, -int256(_amount));
        _adjustGlobals(toRebasingCreditsDiff, toNonRebasingSupplyDiff);
        _totalSupply = _totalSupply - _amount;

        emit Transfer(_account, address(0), _amount);
    }

    /**
     * @dev Get the credits per token for an account. Returns a fixed amount
     *      if the account is non-rebasing.
     * @param _account Address of the account.
     */
    function _creditsPerToken(address _account)
        internal
        view
        returns (uint256)
    {
        if (nonRebasingCreditsPerToken[_account] != 0) {
            return nonRebasingCreditsPerToken[_account];
        } else {
            return _rebasingCreditsPerToken;
        }
    }

    /**
     * @dev Is an account using rebasing accounting or non-rebasing accounting?
     *      Also, ensure contracts are non-rebasing if they have not opted in.
     * @param _account Address of the account.
     */
    function _isNonRebasingAccount(address _account) internal returns (bool) {
        bool isContract = _account.code.length > 0;
        if (isContract && rebaseState[_account] == RebaseOptions.NotSet) {
            _ensureRebasingMigration(_account);
        }
        return nonRebasingCreditsPerToken[_account] > 0;
    }

    /**
     * @dev Ensures internal account for rebasing and non-rebasing credits and
     *      supply is updated following deployment of frozen yield change.
     */
    function _ensureRebasingMigration(address _account) internal {
        // Todo: integrate, deduplicate
        if (nonRebasingCreditsPerToken[_account] == 0) {
            emit AccountRebasingDisabled(_account);
            if (_creditBalances[_account] == 0) {
                // Since there is no existing balance, we can directly set to
                // high resolution, and do not have to do any other bookkeeping
                nonRebasingCreditsPerToken[_account] = 1e27;
            } else {
                // Migrate an existing account:

                // Set fixed credits per token for this account
                nonRebasingCreditsPerToken[_account] = _rebasingCreditsPerToken;
                // Update non rebasing supply
                nonRebasingSupply = nonRebasingSupply + balanceOf(_account);
                // Update credit tallies
                _rebasingCredits = _rebasingCredits - _creditBalances[_account];
            }
        }
    }

    /**
     * @notice Enable rebasing for an account.
     * @dev Add a contract address to the non-rebasing exception list. The
     * address's balance will be part of rebases and the account will be exposed
     * to upside and downside.
     * @param _account Address of the account.
     */
    function governanceRebaseOptIn(address _account)
        public
        nonReentrant
        onlyGovernor
    {
        _rebaseOptIn(_account);
    }

    /**
     * @dev Add a contract address to the non-rebasing exception list. The
     * address's balance will be part of rebases and the account will be exposed
     * to upside and downside.
     */
    function rebaseOptIn() public nonReentrant {
        _rebaseOptIn(msg.sender);
    }

    function _rebaseOptIn(address _account) internal {
        require(_isNonRebasingAccount(_account), "Account has not opted out");
        uint256 balance = balanceOf(msg.sender);
        (int256 beforeRebasingCreditsDiff, int256 beforeNonRebasingSupplyDiff) 
            = _adjustAccount(msg.sender, -int256(balance));

        nonRebasingCreditsPerToken[msg.sender] = 0;
        rebaseState[msg.sender] = RebaseOptions.OptIn;

        (int256 afterRebasingCreditsDiff, int256 afterNonRebasingSupplyDiff) 
            = _adjustAccount(msg.sender, int256(balance));
        _adjustGlobals(
            beforeRebasingCreditsDiff - afterRebasingCreditsDiff,
            beforeNonRebasingSupplyDiff - afterNonRebasingSupplyDiff 
        );
        emit AccountRebasingEnabled(_account);
    }

    function rebaseOptOut() public nonReentrant {
        require(!_isNonRebasingAccount(msg.sender), "Account has not opted in");
        uint256 balance = balanceOf(msg.sender);
        (int256 beforeRebasingCreditsDiff, int256 beforeNonRebasingSupplyDiff) 
            = _adjustAccount(msg.sender, -int256(balance));

        nonRebasingCreditsPerToken[msg.sender] = 1e27;
        rebaseState[msg.sender] = RebaseOptions.OptOut;

        (int256 afterRebasingCreditsDiff, int256 afterNonRebasingSupplyDiff) 
            = _adjustAccount(msg.sender, int256(balance));
        _adjustGlobals(
            afterRebasingCreditsDiff - beforeRebasingCreditsDiff,
            afterNonRebasingSupplyDiff - beforeNonRebasingSupplyDiff
        );
        emit AccountRebasingDisabled(msg.sender);
    }

    /**
     * @dev Modify the supply without minting new tokens. This uses a change in
     *      the exchange rate between "credits" and OUSD tokens to change balances.
     * @param _newTotalSupply New total supply of OUSD.
     */
    function changeSupply(uint256 _newTotalSupply)
        external
        onlyVault
        nonReentrant
    {
        require(_totalSupply > 0, "Cannot increase 0 supply");

        if (_totalSupply == _newTotalSupply) {
            emit TotalSupplyUpdatedHighres(
                _totalSupply,
                _rebasingCredits,
                _rebasingCreditsPerToken
            );
            return;
        }

        _totalSupply = _newTotalSupply > MAX_SUPPLY
            ? MAX_SUPPLY
            : _newTotalSupply;

        _rebasingCreditsPerToken = _rebasingCredits 
            * 1e18 / (_totalSupply - nonRebasingSupply);

        require(_rebasingCreditsPerToken > 0, "Invalid change in supply");

        _totalSupply = (_rebasingCredits * 1e18 / _rebasingCreditsPerToken)
            + nonRebasingSupply;

        emit TotalSupplyUpdatedHighres(
            _totalSupply,
            _rebasingCredits,
            _rebasingCreditsPerToken
        );
    }

    function delegateYield(address from, address to) external onlyGovernor() {
        require(from != to, "Cannot delegate to self");
        require(
            yieldFrom[to] == address(0) 
            && yieldTo[to] == address(0)
            && yieldFrom[from] == address(0)
            && yieldTo[from] == address(0)
            , "Blocked by existing yield delegation");
        require(!_isNonRebasingAccount(to), "Must delegate to a rebasing account");
        require(_isNonRebasingAccount(from), "Must delegate from a non-rebasing account");
        
        yieldTo[from] = to;
        yieldFrom[to] = from;
        rebaseState[from] = RebaseOptions.YieldDelegationSource;
        rebaseState[to] = RebaseOptions.YieldDelegationTarget;
        // Todo: accounting changes
    }

    function undelegateYield(address from) external onlyGovernor() {
        require(yieldTo[from] != address(0), "");
        yieldFrom[yieldTo[from]] = address(0);
        yieldTo[from] = address(0);
        // Todo: change rebase state
    }
}