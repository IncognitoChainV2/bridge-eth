pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import "./IERC20.sol";
import "./pause.sol";

/**
 * Math operations with safety checks
 */
library SafeMath {
  function safeMul(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a * b;
    require(a == 0 || c / a == b);
    return c;
  }

  function safeDiv(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b > 0);
    uint256 c = a / b;
    require(a == b * c + a % b);
    return c;
  }

  function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b <= a);
    return a - b;
  }

  function safeAdd(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    require(c>=a && c>=b);
    return c;
  }
}


/**
 * @dev Interface of the contract capable of checking if an instruction is
 * confirmed over at Incognito Chain
 */
interface Incognito {
    function instructionApproved(
        bool,
        bytes32,
        uint,
        bytes32[] calldata,
        bool[] calldata,
        bytes32,
        bytes32,
        uint[] calldata,
        uint8[] calldata,
        bytes32[] calldata,
        bytes32[] calldata
    ) external view returns (bool);
}

/**
 * @dev Interface of the previous Vault contract to query burn proof status
 */
interface Withdrawable {
    function isWithdrawed(bytes32)  external view returns (bool);
    function isSigDataUsed(bytes32)  external view returns (bool);
    function getDepositedBalance(address, address)  external view returns (uint);
    function updateAssets(address[] calldata, uint[] calldata) external returns (bool); 
}

/**
 * @dev Responsible for holding the assets and issue minting instruction to
 * Incognito Chain. Also, when presented with a burn proof created over at
 * Incognito Chain, releases the tokens back to user
 */
contract Vault is AdminPausable {
    using SafeMath for uint;
    address constant public ETH_TOKEN = 0x0000000000000000000000000000000000000000;
    mapping(bytes32 => bool) public withdrawed;
    mapping(bytes32 => bool) public sigDataUsed;
    // address => token => amount
    mapping(address => mapping(address => uint)) public withdrawRequests;
    mapping(address => uint) public totalDepositedToSCAmount;
    Incognito public incognito;
    Withdrawable public prevVault;
    address payable public newVault;
    bool public notEntered = true;

    event Deposit(address token, string incognitoAddress, uint amount);
    event Withdraw(address token, address to, uint amount);
    event Migrate(address newVault);
    event MoveAssets(address[] assets);
    event UpdateTokenTotal(address[] assets, uint[] amounts);
    event UpdateIncognitoProxy(address newIncognitoProxy);

    /**
     * modifier for contract version 
     */
     modifier onlyPreVault(){
        require(address(prevVault) != address(0x0) && msg.sender == address(prevVault), "Only preVault authored to call!");
        _;
     }
     
    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, notEntered will be true
        require(notEntered, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        notEntered = false;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        notEntered = true;
    } 

    /**
     * @dev Creates new Vault to hold assets for Incognito Chain
     * @param admin: authorized address to Pause and migrate contract
     * @param incognitoProxyAddress: contract containing Incognito's committees
     * @param _prevVault: previous version of the Vault to refer back if necessary
     * After migrating all assets to a new Vault, we still need to refer
     * back to previous Vault to make sure old withdrawals aren't being reused
     */
    constructor(address admin, address incognitoProxyAddress, address _prevVault) public AdminPausable(admin) {
        incognito = Incognito(incognitoProxyAddress);
        prevVault = Withdrawable(_prevVault);
        newVault = address(0);
    }

    /**
     * @dev Makes a ETH deposit to the vault to mint pETH over at Incognito Chain
     * @notice This only works when the contract is not Paused
     * @notice The maximum amount to deposit is capped since Incognito balance is stored as uint64
     * @param incognitoAddress: Incognito Address to receive pETH
     */
    function deposit(string memory incognitoAddress) public payable isNotPaused {
        require(address(this).balance <= 10 ** 27, "Balance of this contract has been reaching to its uint's maximum!");
        emit Deposit(ETH_TOKEN, incognitoAddress, msg.value);
    }

    /**
     * @dev Makes a ERC20 deposit to the vault to mint pERC20 over at Incognito Chain
     * @notice This only works when the contract is not Paused
     * @notice The maximum amount to deposit is capped since Incognito balance is stored as uint64
     * @notice Before calling this function, enough ERC20 must be allowed to
     * tranfer from msg.sender to this contract
     * @param token: address of the ERC20 token
     * @param amount: to deposit to the vault and mint on Incognito Chain
     * @param incognitoAddress: Incognito Address to receive pERC20
     */
    function depositERC20(address token, uint amount, string memory incognitoAddress) public payable isNotPaused {
        IERC20 erc20Interface = IERC20(token);
        uint8 decimals = getDecimals(address(token));
        uint tokenBalance = erc20Interface.balanceOf(address(this));
        uint emitAmount = amount;
        if (decimals > 9) {
            emitAmount = emitAmount / (10 ** (uint(decimals) - 9));
            tokenBalance = tokenBalance / (10 ** (uint(decimals) - 9));
        }
        require(emitAmount <= 10 ** 18 && tokenBalance <= 10 ** 18 && emitAmount.safeAdd(tokenBalance) <= 10 ** 18);

        erc20Interface.transferFrom(msg.sender, address(this), amount);
        require(checkSuccess());
        emit Deposit(token, incognitoAddress, emitAmount);
    }

    /**
     * @dev Checks if a burn proof has been used before
     * @notice First, we check inside the storage of this contract itself. If the
     * hash has been used before, we return the result. Otherwise, we query
     * previous vault recursively until the first Vault (prevVault address is 0x0)
     * @param hash: of the burn proof
     * @return bool: whether the proof has been used or not
     */
    function isWithdrawed(bytes32 hash) public view returns(bool) {
        if (withdrawed[hash]) {
            return true;
        } else if (address(prevVault) == address(0)) {
            return false;
        }
        return prevVault.isWithdrawed(hash);
    }

    /**
     * @dev Parses a burn instruction and returns individual components
     * @param inst: the full instruction, containing both metadata and body
     * @return flag:
     * @return meta: type of the instruction, 72 for burning instruction
     * @return shard: ID of the Incognito shard containing the instruction, must be 1
     * @return token: ETH address of the token contract (0x0 for ETH)
     * @return to: ETH address of the receiver of the token
     */
    function parseBurnInst(bytes memory inst) public pure returns (uint8, uint8, address, address payable, uint) {
        uint8 meta = uint8(inst[0]);
        uint8 shard = uint8(inst[1]);
        address token;
        address payable to;
        uint amount;
        assembly {
            // skip first 0x20 bytes (stored length of inst)
            token := mload(add(inst, 0x22)) // [3:34]
            to := mload(add(inst, 0x42)) // [34:66]
            amount := mload(add(inst, 0x62)) // [66:98]
        }
        return (meta, shard, token, to, amount);
    }

    /**
     * @dev Verifies that a burn instruction is valid
     * @notice All params except inst are the list of 2 elements corresponding to
     * the proof on beacon and bridge
     * @notice All params are the same as in `withdraw`
     */
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
        require(!isWithdrawed(instHash), "The instHash already used!");

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

    /**
     * @dev Withdraws pETH/pIERC20 by providing a burn proof over at Incognito Chain
     * @notice This function takes a burn instruction on Incognito Chain, checks
     * for its validity and returns the token back to ETH chain
     * @notice This only works when the contract is not Paused
     * @notice All params except inst are the list of 2 elements corresponding to
     * the proof on beacon and bridge
     * @param inst: the decoded instruction as a list of bytes
     * @param heights: the blocks containing the instruction
     * @param instPaths: merkle path of the instruction
     * @param instPathIsLefts: whether each node on the path is the left or right child
     * @param instRoots: root of the merkle tree contains all instructions
     * @param blkData: merkle has of the block body
     * @param sigIdxs: indices of the validators who signed this block
     * @param sigVs: part of the signatures of the validators
     * @param sigRs: part of the signatures of the validators
     * @param sigSs: part of the signatures of the validators
     */
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
    ) public isNotPaused nonReentrant {
        (uint8 meta, uint8 shard, address token, address payable to, uint burned) = parseBurnInst(inst);
        require(meta == 72 && shard == 1); // Check instruction type

        // Check if balance is enough
        if (token == ETH_TOKEN) {
            require(address(this).balance >= burned.safeAdd(totalDepositedToSCAmount[token]));
        } else {
            uint8 decimals = getDecimals(token);
            if (decimals > 9) {
                burned = burned * (10 ** (uint(decimals) - 9));
            }
            require(IERC20(token).balanceOf(address(this)) >= burned.safeAdd(totalDepositedToSCAmount[token]));
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
          (bool success, ) =  to.call{value: burned}("");
          require(success);
        } else {
            IERC20(token).transfer(to, burned);
            require(checkSuccess());
        }
        emit Withdraw(token, to, burned);
    }

    /**
     * @dev Burnt Proof is submited to store burnt amount of p-token/p-ETH and receiver's address
     * Receiver then can call withdrawRequest to withdraw these token to he/she incognito address.
     * @notice This function takes a burn instruction on Incognito Chain, checks
     * for its validity and returns the token back to ETH chain
     * @notice This only works when the contract is not Paused
     * @notice All params except inst are the list of 2 elements corresponding to
     * the proof on beacon and bridge
     * @param inst: the decoded instruction as a list of bytes
     * @param heights: the blocks containing the instruction
     * @param instPaths: merkle path of the instruction
     * @param instPathIsLefts: whether each node on the path is the left or right child
     * @param instRoots: root of the merkle tree contains all instructions
     * @param blkData: merkle has of the block body
     * @param sigIdxs: indices of the validators who signed this block
     * @param sigVs: part of the signatures of the validators
     * @param sigRs: part of the signatures of the validators
     * @param sigSs: part of the signatures of the validators
     */
    function submitBurnProof(
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
    ) public isNotPaused nonReentrant {
        (uint8 meta, uint8 shard, address token, address payable to, uint burned) = parseBurnInst(inst);
        require(meta == 97 && shard == 1); // Check instruction type
        // Check if balance is enough
        if (token == ETH_TOKEN) {
            require(address(this).balance >= burned.safeAdd(totalDepositedToSCAmount[token]));
        } else {
            uint8 decimals = getDecimals(token);
            if (decimals > 9) {
                burned = burned * (10 ** (uint(decimals) - 9));
            }
            require(IERC20(token).balanceOf(address(this)) >= burned.safeAdd(totalDepositedToSCAmount[token]));
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

        withdrawRequests[to][token] = withdrawRequests[to][token].safeAdd(burned);
        totalDepositedToSCAmount[token] = totalDepositedToSCAmount[token].safeAdd(burned);
    }

    /**
     * @dev generate address from signature data and hash.
     */
    function sigToAddress(bytes memory signData, bytes32 hash) public pure returns (address) {
        bytes32 s;
        bytes32 r;
        uint8 v;
        assembly {
            r := mload(add(signData, 0x20))
            s := mload(add(signData, 0x40))
        }
        v = uint8(signData[64]) + 27;
        return ecrecover(hash, v, r, s);
    }

    /**
     * @dev Checks if a sig data has been used before
     * @notice First, we check inside the storage of this contract itself. If the
     * hash has been used before, we return the result. Otherwise, we query
     * previous vault recursively until the first Vault (prevVault address is 0x0)
     * @param hash: of the sig data
     * @return bool: whether the sig data has been used or not
     */
    function isSigDataUsed(bytes32 hash) public view returns(bool) {
        if (sigDataUsed[hash]) {
            return true;
        }
        return false;
    }

    /**
     * @dev User requests withdraw token contains in withdrawRequests.
     * Deposit event will be emitted to let incognito recognize and mint new p-tokens for the user.
     * @param incognitoAddress: incognito's address that will receive minted p-tokens.
     * @param token: ethereum's token address (eg., ETH, DAI, ...)
     * @param amount: amount of the token in ethereum's denomination
     * @param signData: signature of an unique data that is signed by an account which is generated from user's incognito privkey
     * @param timestamp: unique data generated from client (timestamp for example)
     */
    function requestWithdraw(
        string memory incognitoAddress,
        address token,
        uint amount,
        bytes memory signData,
        bytes memory timestamp
    ) public isNotPaused nonReentrant {
        // verify owner signs data
        address verifier = verifySignData(abi.encodePacked(incognitoAddress, token, timestamp, amount), signData);
        
        require(withdrawRequests[verifier][token] >= amount);
        withdrawRequests[verifier][token] = withdrawRequests[verifier][token].safeSub(amount);
        totalDepositedToSCAmount[token] = totalDepositedToSCAmount[token].safeSub(amount);
        
        // convert denomination from ethereum's to incognito's (pcoin)
        uint emitAmount = amount;
        if (token != ETH_TOKEN) {
            uint8 decimals = getDecimals(token);
            if (decimals > 9) {
                emitAmount = amount / (10 ** (uint(decimals) - 9));
            }
        }

        emit Deposit(token, incognitoAddress, emitAmount);
    }

    /**
     * @dev execute is a general function that plays a role as proxy to interact to other smart contracts.
     * @param token: ethereum's token address (eg., ETH, DAI, ...)
     * @param amount: amount of the token in ethereum's denomination
     * @param recipientToken: received token address.
     * @param exchangeAddress: address of targeting smart contract that actually executes the desired logics like trade, invest, borrow and so on.
     * @param callData: encoded with signature and params of function from targeting smart contract.
     * @param timestamp: unique data generated from client (timestamp for example)
     * @param signData: signature of an unique data that is signed by an account which is generated from user's incognito privkey
     */
    function execute(
        address token,
        uint amount,
        address recipientToken,
        address exchangeAddress,
        bytes memory callData,
        bytes memory timestamp,
        bytes memory signData
    ) public payable isNotPaused nonReentrant {
        //verify ower signs data from input
        address verifier = verifySignData(abi.encodePacked(exchangeAddress, callData, timestamp, amount), signData);
        
        require(withdrawRequests[verifier][token] >= amount);
        require(token != recipientToken);

        // update balance of verifier
        totalDepositedToSCAmount[token] = totalDepositedToSCAmount[token].safeSub(amount);
        withdrawRequests[verifier][token] = withdrawRequests[verifier][token].safeSub(amount);

        // define number of eth spent for forwarder.
        uint ethAmount = msg.value;
        if (token == ETH_TOKEN) {
            ethAmount = ethAmount.safeAdd(amount);
        } else {
            // transfer token to exchangeAddress.
            require(IERC20(token).balanceOf(address(this)) >= amount, "The balance of vault contract is insufficient");
            IERC20(token).transfer(exchangeAddress, amount);
            require(checkSuccess(), "Transfering to exchange contract address is failed");
        }
        uint returnedAmount = callExtFunc(recipientToken, ethAmount, callData, exchangeAddress);

        // update withdrawRequests
        withdrawRequests[verifier][recipientToken] = withdrawRequests[verifier][recipientToken].safeAdd(returnedAmount);
        totalDepositedToSCAmount[recipientToken] = totalDepositedToSCAmount[recipientToken].safeAdd(returnedAmount);
    }

    /**
     * @dev execute multi trade.
     * The tokens array must contain unique token address for trading
     */
    function executeMulti(
        address[] memory tokens,
        uint[] memory amounts,
        address[] memory recipientTokens,
        address exchangeAddress,
        bytes memory callData,
        bytes memory timestamp,
        bytes memory signData
    ) public payable isNotPaused nonReentrant {
        require(tokens.length == amounts.length && recipientTokens.length > 0);
        //verify ower signs data from input
        address verifier = verifySignData(abi.encodePacked(exchangeAddress, callData, timestamp, amounts), signData);
        // define number of eth spent for forwarder.
        uint ethAmount = msg.value;
        for(uint i = 0; i < tokens.length; i++){
            // check balance is enough or not
            require(withdrawRequests[verifier][tokens[i]] >= amounts[i]);
    
            // update balances of verifier
            totalDepositedToSCAmount[tokens[i]] = totalDepositedToSCAmount[tokens[i]].safeSub(amounts[i]);
            withdrawRequests[verifier][tokens[i]] = withdrawRequests[verifier][tokens[i]].safeSub(amounts[i]);
            
            if (tokens[i] == ETH_TOKEN) {
                ethAmount = ethAmount.safeAdd(amounts[i]);
            } else {
            // transfer token to exchangeAddress.
                require(IERC20(tokens[i]).balanceOf(address(this)) >= amounts[i], "The balance of vault contract is insufficient");
                IERC20(tokens[i]).transfer(exchangeAddress, amounts[i]);
                require(checkSuccess(), "Transfering to exchange contract address is failed");
            }
        }
        
        // get balance of recipient token before trade to compare after trade.
        uint[] memory balancesBeforeTrade = new uint[](recipientTokens.length);
        for(uint i = 0; i < recipientTokens.length; i++) {
            balancesBeforeTrade[i] = balanceOf(recipientTokens[i]);
            if (recipientTokens[i] == ETH_TOKEN) {
                balancesBeforeTrade[i] = balancesBeforeTrade[i].safeSub(msg.value);
            }
        }
        
        //return array Addresses and Amounts
        (address[] memory returnedTokenAddresses,uint[] memory returnedAmounts) = callExtFuncMulti(ethAmount, callData, exchangeAddress);
        
        require(returnedTokenAddresses.length == recipientTokens.length && returnedAmounts.length == returnedTokenAddresses.length);
        
        //update withdrawRequests
        for(uint i = 0; i < returnedAmounts.length; i++) {
            require(returnedTokenAddresses[i] == recipientTokens[i] 
                    && balanceOf(recipientTokens[i]).safeSub(balancesBeforeTrade[i]) == returnedAmounts[i]);
            withdrawRequests[verifier][recipientTokens[i]] = withdrawRequests[verifier][recipientTokens[i]].safeAdd(returnedAmounts[i]);
            totalDepositedToSCAmount[recipientTokens[i]] = totalDepositedToSCAmount[recipientTokens[i]].safeAdd(returnedAmounts[i]);
        }
    }

    /**
     * @dev single trade
     */
    function callExtFunc(address recipientToken, uint ethAmount, bytes memory callData, address exchangeAddress) internal returns (uint) {
         // get balance of recipient token before trade to compare after trade.
        uint balanceBeforeTrade = balanceOf(recipientToken);
        if (recipientToken == ETH_TOKEN) {
            balanceBeforeTrade = balanceBeforeTrade.safeSub(msg.value);
        }
        require(address(this).balance >= ethAmount);
        (bool success, bytes memory result) = exchangeAddress.call{value: ethAmount}(callData);
        require(success);

        (address returnedTokenAddress, uint returnedAmount) = abi.decode(result, (address, uint));
        require(returnedTokenAddress == recipientToken && balanceOf(recipientToken).safeSub(balanceBeforeTrade) == returnedAmount);

        return returnedAmount;
    }
    
    /**
     * @dev multi trade
     */
    function callExtFuncMulti(uint ethAmount, bytes memory callData, address exchangeAddress) internal returns (address[] memory, uint[] memory) {
        require(address(this).balance >= ethAmount);
        (bool success, bytes memory result) = exchangeAddress.call{value: ethAmount}(callData);
        require(success);

        return abi.decode(result, (address[], uint[]));
    }
    
    /**
     * @dev verify sign data
     */
     function verifySignData(bytes memory data, bytes memory signData) internal returns(address){
        bytes32 hash = keccak256(data);
        require(!isSigDataUsed(hash));
        address verifier = sigToAddress(signData, hash);
       // mark data hash of sig as used
        sigDataUsed[hash] = true;
        
        return verifier;
     }
    
    /**
     * @dev Get the amount of specific coin for specific wallet
     */
    function getDepositedBalance(
        address token,
        address owner
    ) public view returns (uint) {
        return withdrawRequests[owner][token];
    }

    /**
     * @dev Saves the address of the new Vault to migrate assets to
     * @notice In case of emergency, Admin will Pause the contract, shutting down
     * all incoming transactions. After a new contract with the fix is deployed,
     * they will migrate assets to it and allow normal operations to resume
     * @notice This only works when the contract is Paused
     * @notice This can only be called by Admin
     * @param _newVault: address to save
     */
    function migrate(address payable _newVault) public onlyAdmin isPaused {
        require(_newVault != address(0));
        newVault = _newVault;
        emit Migrate(_newVault);
    }

    /**
     * @dev Move some assets to newVault
     * @notice This only works when the contract is Paused
     * @notice This can only be called by Admin
     * @param assets: address of the ERC20 tokens to move, 0x0 for ETH
     */
    function moveAssets(address[] memory assets) public onlyAdmin isPaused {
        require(newVault != address(0));
        uint[] memory amounts = new uint[](assets.length);
        for (uint i = 0; i < assets.length; i++) {
            if (assets[i] == ETH_TOKEN) {
                amounts[i] = totalDepositedToSCAmount[ETH_TOKEN];
                newVault.transfer(address(this).balance);
            } else {
                uint bal = IERC20(assets[i]).balanceOf(address(this));
                if (bal > 0) {
                    IERC20(assets[i]).transfer(newVault, bal);
                    require(checkSuccess());
                }
                amounts[i] = totalDepositedToSCAmount[assets[i]];
            }
            totalDepositedToSCAmount[assets[i]] = 0;
        }
        require(Withdrawable(newVault).updateAssets(assets, amounts));
        
        emit MoveAssets(assets);
    }

    /**
     * @dev Move total number of assets to newVault
     * @notice This only works when the preVault is Paused
     * @notice This can only be called by preVault
     * @param assets: address of the ERC20 tokens to move, 0x0 for ETH
     * @param amounts: total number of the ERC20 tokens to move, 0x0 for ETH
     */
    function updateAssets(address[] calldata assets, uint[] calldata amounts) external onlyPreVault returns(bool) {
        require(assets.length == amounts.length, "The amounts and assets length must be equal!");
        for (uint i = 0; i < assets.length; i++) {
            totalDepositedToSCAmount[assets[i]] = totalDepositedToSCAmount[assets[i]].safeAdd(amounts[i]);
        }
        emit UpdateTokenTotal(assets, amounts);
        
        return true;
    }

    /**
     * @dev Changes the IncognitoProxy to use
     * @notice If the IncognitoProxy contract malfunctioned, Admin could config
     * the Vault to use a new fixed IncognitoProxy contract
     * @notice This only works when the contract is Paused
     * @notice This can only be called by Admin
     * @param newIncognitoProxy: address of the new contract
     */
    function updateIncognitoProxy(address newIncognitoProxy) public onlyAdmin isPaused {
        require(newIncognitoProxy != address(0));
        incognito = Incognito(newIncognitoProxy);
        emit UpdateIncognitoProxy(newIncognitoProxy);
    }

    /**
     * @dev Payable receive function to receive Ether from oldVault when migrating
     */
    receive() external payable {}

    /**
     * @dev Check if transfer() and transferFrom() of ERC20 succeeded or not
     * This check is needed to fix https://github.com/ethereum/solidity/issues/4116
     * This function is copied from https://github.com/AdExNetwork/adex-protocol-eth/blob/master/contracts/libs/SafeERC20.sol
     */
    function checkSuccess() private pure returns (bool) {
		uint256 returnValue = 0;
		assembly {
			// check number of bytes returned from last function call
			switch returndatasize()

			// no bytes returned: assume success
			case 0x0 {
				returnValue := 1
			}

			// 32 bytes returned: check if non-zero
			case 0x20 {
				// copy 32 bytes into scratch space
				returndatacopy(0x0, 0x0, 0x20)

				// load those bytes into returnValue
				returnValue := mload(0x0)
			}

			// not sure what was returned: don't mark as success
			default { }
		}
		return returnValue != 0;
	}

    /**
     * @dev Get the decimals of an ERC20 token, return 0 if it isn't defined
     * We check the returndatasize to covert both cases that the token has
     * and doesn't have the function decimals()
     */
    function getDecimals(address token) public view returns (uint8) {
        IERC20 erc20 = IERC20(token);
        return uint8(erc20.decimals());
    }

    /**
     * @dev Get the amount of coin deposited to this smartcontract
     */
    function balanceOf(address token) public view returns (uint) {
        if (token == ETH_TOKEN) {
            return address(this).balance;
        }
        return IERC20(token).balanceOf(address(this));
    }
}
