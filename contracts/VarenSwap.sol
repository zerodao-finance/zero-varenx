// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-new/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts-new/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-new/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IGatewayRegistry.sol";
import "@openzeppelin/contracts-new/utils/Address.sol";
import { IUniswapV2Router02 } from "./interfaces/IUniswapV2Router02.sol";

contract VarenRouter is ReentrancyGuard {
  using SafeERC20 for IERC20;

  uint256 public FEE = 50;
  uint256 public constant PERCENTAGE_DIVIDER = 100_000;

  IGatewayRegistry public immutable registry;
  address public immutable router;
  address payable public immutable devWallet;
  uint256 public immutable blockTimeout;
  address public constant weth = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
  address public constant sushiRouter =
    0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
  // Events
  event Mint(address indexed sender, uint256 amount);
  event Burn(address indexed sender, uint256 amount);
  event Swap(
    address indexed sender,
    address indexed from,
    address indexed to,
    uint256 amount
  );
  address public immutable controller;

  constructor(
    address _controller,
    address _router,
    address _registry,
    address payable _devWallet,
    uint256 _blockTimeout
  ) {
    controller = _controller;
    router = _router;
    registry = IGatewayRegistry(_registry);
    devWallet = _devWallet;
    blockTimeout = _blockTimeout;
  }

  modifier onlyController() {
    require(msg.sender == controller, "!controller");
    _;
  }

  struct SwapRecord {
    address inToken;
    address outToken;
    address to;
    uint256 when;
    uint256 qty;
    bytes burnSendTo;
  }
  mapping(uint256 => SwapRecord) public records;

  function receiveLoan(
    address _to,
    address _inToken,
    uint256 _amount,
    uint256 _nonce,
    bytes memory _data
  ) public onlyController {
    SwapRecord memory swapRecord;
    swapRecord.when = block.number;
    swapRecord.to = _to;
    swapRecord.inToken = _inToken;
    bytes memory data;
    (swapRecord.outToken, swapRecord.burnSendTo, data) = abi.decode(
      _data,
      (address, bytes, bytes)
    );
    // else token is in the contract because of the minting process or the user sent ETH

    // Saving ref to current balance of destination token to know how much was swapped
    uint256 currentDestTokenBalance = currentBalance(swapRecord.outToken);

    // Executing the swap
    if (IERC20(swapRecord.inToken).allowance(address(this), router) < _amount) {
      IERC20(swapRecord.inToken).approve(router, type(uint256).max);
    }
    // Swapping
    Address.functionCall(router, data);

    // How much was swapped
    swapRecord.qty =
      currentBalance(swapRecord.outToken) -
      currentDestTokenBalance;
    records[_nonce] = swapRecord;
    emit Swap(
      swapRecord.to,
      swapRecord.inToken,
      swapRecord.outToken,
      swapRecord.qty
    );
  }

  function repayLoan(
    address, /* _to */
    address, /* _asset */
    uint256, /* _actualAmount */
    uint256 _nonce,
    bytes memory /* _data */
  ) public onlyController {
    SwapRecord storage record = records[_nonce];
    require(record.qty != 0, "!outstanding");
    if (record.burnSendTo.length != 0) {
      burnRenToken(record);
    } else {
      IERC20(record.outToken).safeTransfer(record.to, record.qty);
    }
  }

  function defaultLoan(uint256 _nonce) public {
    SwapRecord storage record = records[_nonce];
    require(block.number >= record.when + blockTimeout);
    require(record.qty != 0, "!outstanding");
    uint256 _amountSwappedBack = swapTokensBack(record);
    IERC20(record.outToken).safeTransfer(controller, _amountSwappedBack);
    delete records[_nonce];
  }

  function swapTokensBack(SwapRecord storage record)
    internal
    returns (uint256 amountSwappedBack)
  {
    address[] memory path = new address[](3);
    path[0] = record.outToken;
    path[1] = weth;
    path[2] = record.inToken;
    uint256[] memory amounts = IUniswapV2Router02(sushiRouter)
      .swapExactTokensForTokens(
        record.qty,
        1,
        path,
        address(this),
        block.timestamp + 1
      );
    amountSwappedBack = amounts[amounts.length - 1];
  }

  function burnRenToken(SwapRecord storage swapRecord) internal {
    registry.getGatewayByToken(swapRecord.outToken).burn(
      swapRecord.burnSendTo,
      swapRecord.qty
    );
    emit Burn(swapRecord.to, swapRecord.qty);
  }

  function currentBalance(address _token)
    public
    view
    returns (uint256 balance)
  {
    balance = IERC20(_token).balanceOf(address(this));
  }

  receive() external payable {}
}
