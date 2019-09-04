pragma solidity >=0.5.0 <0.6.0;
pragma experimental ABIEncoderV2;

import "./IERC20.sol";

contract Incognito {
  function instructionApproved(
    bool,
    bytes32,
    uint,
    bytes32[] memory,
    bool[] memory,
    bytes32,
    bytes32,
    uint[] memory,
    uint8[] memory,
    bytes32[] memory,
    bytes32[] memory
  ) public view returns (bool);
}

contract Vault {
  address constant ETH_TOKEN = 0x0000000000000000000000000000000000000000;
  address public owner;
  mapping(bytes32 => bool) public withdrawed;
  Incognito public incognito;

  event Deposit(address token, string incognitoAddress, uint amount);
  event Withdraw(address token, address to, uint amount);

  constructor(address incognitoProxyAddress) public payable {
    /* Set the owner to the creator of this contract */
    owner = msg.sender;
    incognito = Incognito(incognitoProxyAddress);
  }

  function deposit(string memory incognitoAddress) public payable {
    // require((msg.value + address(this).balance) <= 10 ** 27, "Balance of this contract has been reaching to its uint's maximum.");
    require(msg.value + address(this).balance <= 10 ** 27);
    emit Deposit(ETH_TOKEN, incognitoAddress, msg.value);
  }

  function depositERC20(address token, uint amount, string memory incognitoAddress) public payable {
    IERC20 erc20Interface = IERC20(token);
    uint tokenBalance = erc20Interface.balanceOf(address(this));
    require(amount + tokenBalance <= 10 ** 18);
    require(erc20Interface.transferFrom(msg.sender, address(this), amount));
    emit Deposit(token, incognitoAddress, amount);
  }

  function parseBurnInst(bytes memory inst) public pure returns (uint8, uint8, address, address payable, uint) {
    uint8 meta = uint8(inst[0]);
    uint8 shard = uint8(inst[1]);
    address token;
    address payable to;
    uint amount;
    assembly {
      // skip first 0x20 bytes (stored length of inst)
      token := mload(add(inst, 0x22)) // [2:34]
      to := mload(add(inst, 0x42)) // [34:66]
      amount := mload(add(inst, 0x62)) // [66:98]
    }
    return (meta, shard, token, to, amount);
  }

  function verifyInst(
    bytes memory inst,
    uint[2] memory heights,
    bytes32[][2] memory instPaths,
    bool[][2] memory instPathIsLefts,
    bytes32[2] memory instRoots,
    bytes32[2] memory blkData,
    uint[][2] memory sigIdxs,
    uint8[][2] memory sigVs,
    bytes32[][2] memory sigRs,
    bytes32[][2] memory sigSs
  ) internal {
    // Each instruction can only by redeemed once
    bytes32 instHash = keccak256(inst);
    bytes32 beaconInstHash = keccak256(abi.encodePacked(inst, heights[0]));
    bytes32 bridgeInstHash = keccak256(abi.encodePacked(inst, heights[1]));
    require(withdrawed[instHash] == false);

    // Verify instruction on beacon
    require(incognito.instructionApproved(
      true,
      beaconInstHash,
      heights[0],
      instPaths[0],
      instPathIsLefts[0],
      instRoots[0],
      blkData[0],
      sigIdxs[0],
      sigVs[0],
      sigRs[0],
      sigSs[0]
    ));

    // Verify instruction on bridge
    require(incognito.instructionApproved(
      false,
      bridgeInstHash,
      heights[1],
      instPaths[1],
      instPathIsLefts[1],
      instRoots[1],
      blkData[1],
      sigIdxs[1],
      sigVs[1],
      sigRs[1],
      sigSs[1]
    ));
    withdrawed[instHash] = true;
  }

  function withdraw(
    bytes memory inst,
    uint[2] memory heights,
    bytes32[][2] memory instPaths,
    bool[][2] memory instPathIsLefts,
    bytes32[2] memory instRoots,
    bytes32[2] memory blkData,
    uint[][2] memory sigIdxs,
    uint8[][2] memory sigVs,
    bytes32[][2] memory sigRs,
    bytes32[][2] memory sigSs
  ) public payable {
    (uint8 meta, uint8 shard, address token, address payable to, uint burned) = parseBurnInst(inst);
    require(meta == 72 && shard == 1); // Check instruction type

    // Check if balance is enough
    if (token == ETH_TOKEN) {
      require(address(this).balance >= burned);
    } else {
      require(IERC20(token).balanceOf(address(this)) >= burned);
    }

    verifyInst(
      inst,
      heights,
      instPaths,
      instPathIsLefts,
      instRoots,
      blkData,
      sigIdxs,
      sigVs,
      sigRs,
      sigSs
    );

    // Send and notify
    if (token == ETH_TOKEN) {
      to.transfer(burned);
    } else {
      require(IERC20(token).transfer(to, burned));
    }
    emit Withdraw(token, to, burned);
  }
}