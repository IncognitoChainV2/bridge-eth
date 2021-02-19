pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import "../proxy/pause.sol";

/**
 * @dev Stores beacon and bridge committee members of Incognito Chain. Other
 * contracts can query this contract to check if an instruction is confimed on
 * Incognito
 */
contract IncognitoProxy is AdminPausable {
    struct Committee {
        address[] pubkeys; // ETH address of all members
        uint startBlock; // The block that the committee starts to work on
    }

    Committee[] public beaconCommittees; // All beacon committees from genesis block
    Committee[] public bridgeCommittees; // All bridge committees from genesis block

    event BeaconCommitteeSwapped(uint id, uint startHeight);
    event BridgeCommitteeSwapped(uint id, uint startHeight);

    /**
     * @dev Sets the genesis committees and the address of admin
     * @notice Admin is the one responsible for the contract in case of emergency
     * Here, they are authorized to Pause the contract, stopping new committees
     * from being added to the contract
     * Admin is authorized to Pause the contract at anytime for 1 year starting
     * from the moment the contract is deployed
     * Admin is also authorized to increase the expiration time if they need more
     * time to implement a more decentralized failsafe mechanism
     * @notice Admin can also be a smart contract implementing a DAO and making decisions through a voting system
     * @param admin: ETH address
     * @param beaconCommittee: genesis committee members of beacon chain
     * @param bridgeCommittee: genesis committee members of bridge
     */
    constructor(
        address admin,
        address[] memory beaconCommittee,
        address[] memory bridgeCommittee
    ) public AdminPausable(admin) {
        beaconCommittees.push(Committee({
            pubkeys: beaconCommittee,
            startBlock: 0
        }));

        bridgeCommittees.push(Committee({
            pubkeys: bridgeCommittee,
            startBlock: 0
        }));
    }

    /**
     * @dev Gets a beacon committee in the past
     * @notice We need to implement this because the autogenerated getter returns only the startBlock
     * @param i index of the committee to get
     * @return the committee and their startBlock
     */
    function getBeaconCommittee(uint i) public view returns(Committee memory) {
        return beaconCommittees[i];
    }

    /**
     * @dev Gets a bridge committee in the past
     * @notice the same as getBeaconCommittee but for bridge
     */
    function getBridgeCommittee(uint i) public view returns(Committee memory) {
        return bridgeCommittees[i];
    }

    /**
     * @dev Updates the latest committee of the bridge
     * @notice This function takes a swap instruction on Incognito Chain, checks for its validity and stores the latest committee
     * @notice This only works when the contract is not Paused
     * @notice All params except inst are the list of 2 elements corresponding to the proof on beacon and bridge
     * @param inst: the decoded instruction as a list of bytes
     * @param instPaths: merkle path of the instruction
     * @param instPathIsLefts: whether each node on the path is the left or right child
     * @param instRoots: root of the merkle tree contains all instructions
     * @param blkData: merkle has of the block body
     * @param sigIdxs: indices of the validators who signed this block
     * @param sigVs: part of the signatures of the validators
     * @param sigRs: part of the signatures of the validators
     * @param sigSs: part of the signatures of the validators
     */
    function swapBridgeCommittee(
        bytes memory inst,
        bytes32[][2] memory instPaths,
        bool[][2] memory instPathIsLefts,
        bytes32[2] memory instRoots,
        bytes32[2] memory blkData,
        uint[][2] memory sigIdxs,
        uint8[][2] memory sigVs,
        bytes32[][2] memory sigRs,
        bytes32[][2] memory sigSs
    ) public isNotPaused {
        bytes32 instHash = keccak256(inst);

        // Verify instruction on beacon
        require(instructionApproved(
            true,
            instHash,
            beaconCommittees[beaconCommittees.length-1].startBlock,
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
        require(instructionApproved(
            false,
            instHash,
            bridgeCommittees[bridgeCommittees.length-1].startBlock,
            instPaths[1],
            instPathIsLefts[1],
            instRoots[1],
            blkData[1],
            sigIdxs[1],
            sigVs[1],
            sigRs[1],
            sigSs[1]
        ));

        // Parse instruction and check metadata
        (uint8 meta, uint8 shard, uint startHeight, uint numVals) = extractMetaFromInstruction(inst);
        require(meta == 71 && shard == 1);

        // Make sure 1 instruction can't be used twice (using startHeight)
        require(startHeight > bridgeCommittees[bridgeCommittees.length-1].startBlock, "cannot change old committee");

        // Swap committee
        address[] memory pubkeys = extractCommitteeFromInstruction(inst, numVals);
        bridgeCommittees.push(Committee({
            pubkeys: pubkeys,
            startBlock: startHeight
        }));

        emit BridgeCommitteeSwapped(bridgeCommittees.length, startHeight);
    }

    /**
     * @dev Updates the latest committee of the beacon chain
     * @notice This function takes a swap instruction on Incognito Chain, checks for its validity and stores the latest committee
     * @notice This only works when the contract is not Paused
     * @notice Swapping beacon committee doesn't require that the instruction is included in the bridge chain
     * @notice All params are the same as swapBridgeCommittee
     */
    function swapBeaconCommittee(
        bytes memory inst,
        bytes32[] memory instPath,
        bool[] memory instPathIsLeft,
        bytes32 instRoot,
        bytes32 blkData,
        uint[] memory sigIdx,
        uint8[] memory sigV,
        bytes32[] memory sigR,
        bytes32[] memory sigS
    ) public isNotPaused {
        bytes32 instHash = keccak256(inst);

        // Verify instruction on beacon
        require(instructionApproved(
            true,
            instHash,
            beaconCommittees[beaconCommittees.length-1].startBlock,
            instPath,
            instPathIsLeft,
            instRoot,
            blkData,
            sigIdx,
            sigV,
            sigR,
            sigS
        ));

        // Parse instruction and check metadata and shardID
        (uint8 meta, uint8 shard, uint startHeight, uint numVals) = extractMetaFromInstruction(inst);
        require(meta == 70 && shard == 1);

        // Make sure 1 instruction can't be used twice (using startHeight)
        require(startHeight > beaconCommittees[beaconCommittees.length-1].startBlock, "cannot change old committee");

        // Swap committee
        address[] memory pubkeys = extractCommitteeFromInstruction(inst, numVals);
        beaconCommittees.push(Committee({
            pubkeys: pubkeys,
            startBlock: startHeight
        }));

        emit BeaconCommitteeSwapped(beaconCommittees.length, startHeight);
    }

    /**
     * @dev Checks if an instruction is confirmed on chain (beacon or bridge)
     * @notice A confirmation means that the instruction is included in a block
     * that has enough validators' signatures
     * @param isBeacon: check on beacon or bridge
     * @param instHash: keccak256 hash of the instruction's content
     * @param blkHeight: height of the block containing the instruction
     * @param instPath: merkle path of the instruction
     * @param instPathIsLeft: whether each node on the path is the left or right child
     * @param instRoot: root of the merkle tree contains all instructions
     * @param blkData: merkle has of the block body
     * @param sigIdx: indices of the validators who signed this block
     * @param sigV: part of the signatures of the validators
     * @param sigR: part of the signatures of the validators
     * @param sigS: part of the signatures of the validators
     * @return bool: whether the instruction is valid and confirmed
     */
    function instructionApproved(
        bool isBeacon,
        bytes32 instHash,
        uint blkHeight,
        bytes32[] memory instPath,
        bool[] memory instPathIsLeft,
        bytes32 instRoot,
        bytes32 blkData,
        uint[] memory sigIdx,
        uint8[] memory sigV,
        bytes32[] memory sigR,
        bytes32[] memory sigS
    ) public view returns (bool) {
        // Find committee in charge of this block
        address[] memory signers;
        uint _;
        if (isBeacon) {
            (signers, _) = findBeaconCommitteeFromHeight(blkHeight);
        } else {
            (signers, _) = findBridgeCommitteeFromHeight(blkHeight);
        }

        // Extract signers that signed this block (require sigIdx to be strictly increasing)
        require(sigV.length == sigIdx.length);
        require(sigV.length == sigR.length);
        require(sigV.length == sigS.length);
        for (uint i = 0; i < sigIdx.length; i++) {
            if ((i > 0 && sigIdx[i] <= sigIdx[i-1]) || sigIdx[i] >= signers.length) {
                return false;
            }
            signers[i] = signers[sigIdx[i]];
        }

        // Get double block hash from instRoot and other data
        bytes32 blk = keccak256(abi.encodePacked(keccak256(abi.encodePacked(blkData, instRoot))));

        // Check if enough validators signed this block
        if (sigIdx.length <= signers.length * 2 / 3) {
            return false;
        }

        // Check that signature is correct
        require(verifySig(signers, blk, sigV, sigR, sigS));

        // Check that inst is in block
        require(instructionInMerkleTree(
            instHash,
            instRoot,
            instPath,
            instPathIsLeft
        ));

        return true;
    }

    /**
     * @dev Finds the beacon committee in charge of signing a block height
     * @notice This functions does a binary search of all committees (since genesis block)
     * @param blkHeight: to search for
     * @return committee: address of the committee members
     * @return id: index of the committee
     */
    function findBeaconCommitteeFromHeight(uint blkHeight) public view returns (address[] memory, uint) {
        uint l = 0;
        uint r = beaconCommittees.length;
        require(r > 0);
        r = r - 1;
        while (l != r) {
            uint m = (l + r + 1) / 2;
            if (beaconCommittees[m].startBlock <= blkHeight) {
                l = m;
            } else {
                r = m - 1;
            }
        }
        return (beaconCommittees[l].pubkeys, l);
    }

    /**
     * @dev Finds the bridge committee in charge of signing a block height
     * @notice The same as findBeaconCommitteeFromHeight but for bridge chain
     */
    function findBridgeCommitteeFromHeight(uint blkHeight) public view returns (address[] memory, uint) {
        uint l = 0;
        uint r = bridgeCommittees.length;
        require(r > 0);
        r = r - 1;
        while (l != r) {
            uint m = (l + r + 1) / 2;
            if (bridgeCommittees[m].startBlock <= blkHeight) {
                l = m;
            } else {
                r = m - 1;
            }
        }
        return (bridgeCommittees[l].pubkeys, l);
    }

    /**
     * @dev Checks if a value is in a merkle tree
     * @param leaf: the value to check
     * @param root: of the merkle tree
     * @param path: merkle path of the value to check
     * @param left: whether each node on the path is the left or right child
     * @return bool: whether the value is in the merkle tree
     */
    function instructionInMerkleTree(
        bytes32 leaf,
        bytes32 root,
        bytes32[] memory path,
        bool[] memory left
    ) public pure returns (bool) {
        require(left.length == path.length);
        bytes32 hash = leaf;
        for (uint i = 0; i < path.length; i++) {
            if (left[i]) {
                hash = keccak256(abi.encodePacked(path[i], hash));
            } else if (path[i] == 0x0) {
                hash = keccak256(abi.encodePacked(hash, hash));
            } else {
                hash = keccak256(abi.encodePacked(hash, path[i]));
            }
        }
        return hash == root;
    }

    /**
     * @dev Extracts the metadata of a swap instruction
     * @param inst: the full instruction, containing both metadata and body
     * @return meta: type of the instruction, 70 for swapping beacon and 71 for bridge
     * @return shard: ID of the Incognito shard containing the instruction, must be 1
     * @return height: the starting block that the committee is responsible for
     * @return numVals: number of validators in the new committee
     */
    function extractMetaFromInstruction(bytes memory inst) public pure returns(uint8, uint8, uint, uint) {
        require(inst.length >= 0x42); // 0x02 bytes for meta and shard, 0x20 each for height and numVals
        uint8 meta = uint8(inst[0]);
        uint8 shard = uint8(inst[1]);
        uint height;
        uint numVals;
        assembly {
            // skip first 0x20 bytes (stored length of inst)
            height := mload(add(inst, 0x22)) // [2:34]
            numVals := mload(add(inst, 0x42)) // [34:66]
        }
        return (meta, shard, height, numVals);
    }

    /**
     * @dev Extracts the committee (body) from a swap instruction
     * @param inst: the full instruction, containing both metadata and body
     * @param numVals: number of validators in the new committee
     * @return committee: address of the committee members
     */
    function extractCommitteeFromInstruction(bytes memory inst, uint numVals) public pure returns (address[] memory) {
        require(inst.length == 0x42 + numVals * 0x20);
        address[] memory addr = new address[](numVals);
        address tmp;
        for (uint i = 0; i < numVals; i++) {
            assembly {
                // skip first 0x20 bytes (stored length of inst)
                // also, skip the next 0x42 bytes (stored metadata)
                tmp := mload(add(add(inst, 0x62), mul(i, 0x20))) // 67+i*32
            }
            addr[i] = tmp;
        }
        return addr;
    }

    /**
     * @dev Verifies that the signatures for a message are correct
     * @param msgHash: the message to be verify
     * @param v: part of the signatures
     * @param r: part of the signatures
     * @param s: part of the signatures
     * @return bool: whether all signatures are correct
     */
    function verifySig(
        address[] memory committee,
        bytes32 msgHash,
        uint8[] memory v,
        bytes32[] memory r,
        bytes32[] memory s
    ) public pure returns (bool) {
        require(v.length == r.length);
        require(v.length == s.length);
        for (uint i = 0; i < v.length; i++){
            if (ecrecover(msgHash, v[i], r[i], s[i]) != committee[i]) {
                return false;
            }
        }
        return true;
    }
}