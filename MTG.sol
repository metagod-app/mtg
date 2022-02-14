
// File: metagod-js/contracts/token/SafeMath.sol

pragma solidity ^0.6.12;

// ----------------------------------------------------------------------------
// Safe maths
// ----------------------------------------------------------------------------
library SafeMath {
    function add(uint a, uint b) internal pure returns (uint c) {
        c = a + b;
        require(c >= a, 'SafeMath:INVALID_ADD');
    }

    function sub(uint a, uint b) internal pure returns (uint c) {
        require(b <= a, 'SafeMath:OVERFLOW_SUB');
        c = a - b;
    }

    function mul(uint a, uint b, uint decimal) internal pure returns (uint) {
        uint dc = 10**decimal;
        uint c0 = a * b;
        require(a == 0 || c0 / a == b, "SafeMath: multiple overflow");
        uint c1 = c0 + (dc / 2);
        require(c1 >= c0, "SafeMath: multiple overflow");
        uint c2 = c1 / dc;
        return c2;
    }

    function div(uint256 a, uint256 b, uint decimal) internal pure returns (uint256) {
        require(b != 0, "SafeMath: division by zero");
        uint dc = 10**decimal;
        uint c0 = a * dc;
        require(a == 0 || c0 / a == dc, "SafeMath: division internal");
        uint c1 = c0 + (b / 2);
        require(c1 >= c0, "SafeMath: division internal");
        uint c2 = c1 / b;
        return c2;
    }
}

// File: metagod-js/contracts/token/Token.sol

pragma solidity ^0.6.12;


abstract contract ERC20Interface {
  function totalSupply() public virtual view returns (uint);
  function balanceOf(address tokenOwner) public virtual view returns (uint balance);
  function allowance(address tokenOwner, address spender) public virtual view returns (uint remaining);
  function transfer(address to, uint tokens) public virtual returns (bool success);
  function approve(address spender, uint tokens) public virtual returns (bool success);
  function transferFrom(address from, address to, uint tokens) public virtual returns (bool success);

  event Transfer(address indexed from, address indexed to, uint tokens);
  event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}

abstract contract ApproveAndCallFallBack {
  function receiveApproval(address from, uint256 tokens, address token, bytes memory data) public virtual;
}

contract Owned {
  address public owner;
  address public newOwner;

  event OwnershipTransferred(address indexed _from, address indexed _to);

  constructor() public {
    owner = msg.sender;
  }

  modifier onlyOwner {
    require(msg.sender == owner);
    _;
  }

  function transferOwnership(address _newOwner) public onlyOwner {
    newOwner = _newOwner;
  }
  
  function acceptOwnership() public {
    require(msg.sender == newOwner);
    emit OwnershipTransferred(owner, newOwner);
    owner = newOwner;
    newOwner = address(0);
  }
}

contract Pausable is Owned {
  event Pause();
  event Unpause();

  bool public paused = false;

  modifier whenNotPaused() {
    require(!paused);
    _;
  }

  modifier whenPaused() {
    require(paused);
    _;
  }

  function pause() onlyOwner whenNotPaused public {
    paused = true;
    emit Pause();
  }

  function unpause() onlyOwner whenPaused public {
    paused = false;
    emit Unpause();
  }
}

contract StandardToken is ERC20Interface, Owned, Pausable {
  using SafeMath for uint;

  address public dev;
  string  public symbol;
  string  public name;
  uint8   public decimals;
  uint    public total_supply;
  uint    public rate_receiver;     // (!) input value precision follow "decimals"
  uint    public rate_max_transfer; // (!) input value precision follow "decimals"
  uint    public total_mint;
  bool    public is_mintable;

  mapping(address => uint) balances;
  mapping(address => mapping(address => uint)) allowed;
  mapping(address => bool) public tax_list;
  mapping(address => bool) public tax_whitelist;
  mapping(address => bool) public antiWhale_list;
  mapping(address => bool) public minter_list;

  event UpdateMintable(bool status);
  event UpdateDevAddress(address dev);
  event UpdateTaxAddress(address target_address, bool status);
  event UpdateTaxWhitelist(address target_address, bool status);
  event UpdateRateReceiver(uint rate);
  event UpdateRateMaxTransfer(uint rate);
  event UpdateAntiWhaleList(address account, bool status);
  event UpdateMinter(address minter, bool status);

  constructor(
      address _dev,
      uint    _rate_receiver,
      uint    _rate_max_transfer
  ) public {
    symbol            = "MTG";
    name              = "Metagod";
    decimals          = 18;
    total_supply      = 1000000000 * 10**uint(decimals);
    dev               = _dev;
    rate_receiver     = _rate_receiver;
    rate_max_transfer = _rate_max_transfer;
    is_mintable       = true;
    
    minter_list[msg.sender] = true;
  }

  modifier antiWhale(address from, address to, uint256 amount) {
    if (maxTransferAmount() > 0) {
      if (antiWhale_list[from] || antiWhale_list[to]) {
        require(amount <= maxTransferAmount(), "antiWhale: Transfer amount exceeds the maxTransferAmount");
      }
    }
    _;
  }
  
  modifier isMinter() {
      require(minter_list[msg.sender], "Not allowed to mint");
      _;
  }

  function totalSupply() public override view returns (uint) {
    return total_supply.sub(balances[address(0)]);
  }

  function circulateSupply() public view returns (uint) {
    return total_mint.sub(balances[address(0)]);
  }

  function balanceOf(address tokenOwner) public override view returns (uint balance) {
    return balances[tokenOwner];
  }

  function approve(address spender, uint tokens) public whenNotPaused override returns (bool success) {
    allowed[msg.sender][spender] = tokens;
    emit Approval(msg.sender, spender, tokens);
    return true;
  }

  function transfer(address to, uint tokens) public whenNotPaused antiWhale(msg.sender, to, tokens) override returns (bool success) {
    balances[msg.sender] = balances[msg.sender].sub(tokens);
    _transfer(msg.sender, to, tokens);
    return true;
  }

  function transferFrom(address from, address to, uint tokens) public whenNotPaused antiWhale(from, to, tokens) override returns (bool success) {
    balances[from] = balances[from].sub(tokens);
    allowed[from][msg.sender] = allowed[from][msg.sender].sub(tokens);
    _transfer(from, to, tokens);
    return true;
  }

  function _transfer(address from, address to, uint tokens) internal {
    /*
    * fullfill all requirment below to apply fee
    * 1. "from" or "to" address is in blacklist
    * 2. "from" or "to" address is not in whitelist
    */
    if ((tax_list[from] || tax_list[to]) && !(tax_whitelist[from] || tax_whitelist[to])) {
        // send token by calculate allocation to receiver
        uint amount = tokens.mul(rate_receiver, decimals);
        balances[to] = balances[to].add(amount);
        emit Transfer(from, to, amount);

        // send remaining token to dev
        uint amount_dev = tokens.sub(amount);
        if (amount_dev > 0) {
            balances[dev] = balances[dev].add(amount_dev);
            emit Transfer(from, dev, amount_dev);
        }
    } else {
        // send full amount to receiver
        balances[to] = balances[to].add(tokens);
        emit Transfer(from, to, tokens);
    }
  }

  function allowance(address tokenOwner, address spender) public view override returns (uint remaining) {
    return allowed[tokenOwner][spender];
  }

  function approveAndCall(address spender, uint tokens, bytes memory data) public whenNotPaused returns (bool success) {
    allowed[msg.sender][spender] = tokens;
    emit Approval(msg.sender, spender, tokens);
    ApproveAndCallFallBack(spender).receiveApproval(msg.sender, tokens, address(this), data);
    return true;
  }
  
  function updateMinter(address minter, bool status) external onlyOwner {
    minter_list[minter] = status;
    emit UpdateMinter(minter, status);
  }

  function mint(address _address, uint amount) external isMinter {
    _mint(_address, amount);
  }

  function _mint(address account, uint256 amount) internal {
    require(account != address(0), "mint to the zero address");
    require(is_mintable, "not mintable");
    uint tmp_total = total_mint.add(amount);
    require(tmp_total <= total_supply, "total supply exceed");

    balances[account] = balances[account].add(amount);
    total_mint = total_mint.add(amount);
    emit Transfer(address(0), account, amount);
  }

  function transferAnyERC20Token(address tokenAddress, uint tokens) external onlyOwner returns (bool success) {
    return ERC20Interface(tokenAddress).transfer(owner, tokens);
  }

  function maxTransferAmount() public view returns (uint) {
    return circulateSupply().mul(rate_max_transfer, decimals);
  }

  function updateRateMaxTransfer(uint rate) external onlyOwner returns (bool) {
    rate_max_transfer = rate;
    emit UpdateRateMaxTransfer(rate_max_transfer);
    return true;
  }
  
  function updateMintable(bool status) external onlyOwner returns (bool) {
    is_mintable = status;
    emit UpdateMintable(status);
    return true;
  }
  
  function updateDevAddress(address _dev) external onlyOwner returns (bool) {
    dev = _dev;
    emit UpdateDevAddress(_dev);
    return true;
  }
  
  function updateTaxAddress(address _address, bool status) public onlyOwner returns (bool) {
    tax_list[_address] = status;
    emit UpdateTaxAddress(_address, status);
    return true;
  }

  function updateTaxAddressBatch(address[] memory _address, bool[] memory status) external onlyOwner returns (bool) {
    require(_address.length == status.length, "invalid input size");

    for (uint i = 0; i < _address.length; i++) {
      updateTaxAddress(_address[i], status[i]);
    }
  }
  
  function updateTaxWhitelist(address _address, bool status) public onlyOwner returns (bool) {
    tax_whitelist[_address] = status;
    emit UpdateTaxWhitelist(_address, status);
    return true;
  }

  function updateTaxWhitelistBatch(address[] memory _address, bool[] memory status) external onlyOwner returns (bool) {
    require(_address.length == status.length, "invalid input size");

    for (uint i = 0; i < _address.length; i++) {
      updateTaxWhitelist(_address[i], status[i]);
    }
  }

  function updateAntiWhaleList(address _address, bool status) public onlyOwner returns (bool) {
    antiWhale_list[_address] = status;
    emit UpdateAntiWhaleList(_address, status);
    return true;
  }

  function updateAntiWhaleListBatch(address[] memory _address, bool[] memory status) external onlyOwner returns (bool) {
    require(_address.length == status.length, "invalid input size");

    for (uint i = 0; i < _address.length; i++) {
      updateAntiWhaleList(_address[i], status[i]);
    }
  }
  
  function updateRateReceiver(uint _rate_receiver) external onlyOwner returns (bool) {
    rate_receiver = _rate_receiver;
    emit UpdateRateReceiver(_rate_receiver);
    return true;
  }
  
  fallback() external payable {
    revert();
  }
}
