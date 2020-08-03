pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import "./pause.sol";

interface ValidatorStorage {
    function loadCandidates(bool isBeacon, uint swapID) external view returns(address[] memory);
    function storeCandidates(bool isBeacon, uint swapID, uint oldGID, uint newGID, address[] calldata newAddrs) external;
    function loadCommittee(bool isBeacon) external view returns(address[] memory);
    function storeCommittee(bool isBeacon, uint gID1, uint gID2) external;
}

/**
 * @dev Stores beacon and bridge committee members of Incognito Chain. Other
 * contracts can query this contract to check if an instruction is confimed on
 * Incognito
 */
contract IncognitoProxy is AdminPausable {
    struct MerkleProof {
        uint id;
        bytes32[] path;
    }

    struct InstructionProof {
        uint8[] sigV;
        uint id;
        bytes32[] path;
        bytes32 blkData;
        uint[] sigIdx;
        bytes32[] sigR;
        bytes32[] sigS;
    }

    struct CommitteeMeta {
        uint8 meta;
        uint8 shard;
        uint startHeight;
        uint numVals;
        uint id;
    }

    struct Committee {
        address[] pubkeys; // ETH address of all members
        uint startBlock; // The block that the committee starts to work on
        uint swapID;
    }

    struct Candidate {
        address[] pubkeys;
        uint startBlock;
        bytes32 beaconBlockHash;
    }

    struct Finality {
        uint blockHeight; // TODO: remove if unnecessary
        bytes32 rootHash;
    }

    // Finality info for beacon and bridge
    Finality public beaconFinality;
    Finality public bridgeFinality;

    // Actual storage of the validators' pubkeys
    ValidatorStorage public validatorStorage;

    // The latest swapID for beacon/shard
    // isBeacon => swapID
    mapping(bool => uint) public committeeSwapID;

    // Hash of the beacon block needed to prove that a swap is finalized
    // isBeacon => swapID => hash
    mapping(bool => mapping(uint => bytes32)) public swapBeaconHash;

    event SubmittedBeaconCandidate(uint startHeight);
    event SubmittedBridgeCandidate(uint startHeight);
    event ChainFinalized(bool isBeacon);
    event CandidatePromoted(uint swapID, bool isBeacon);

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
        bytes32 blk;
        // beaconCommittees.push(Committee({
        //     pubkeys: beaconCommittee,
        //     startBlock: 0,
        //     swapID: 0
        // }));
        // beaconCandidates[0] = Candidate({
        //     pubkeys: beaconCommittee,
        //     startBlock: 0,
        //     beaconBlockHash: blk
        // });

        // bridgeCommittees.push(Committee({
        //     pubkeys: bridgeCommittee,
        //     startBlock: 0,
        //     swapID: 0
        // }));
        // bridgeCandidates[0] = Candidate({
        //     pubkeys: bridgeCommittee,
        //     startBlock: 0,
        //     beaconBlockHash: blk
        // });
    }

    /**
     * @dev Validates and stores a new group of bridge candidates
     * The candidates will become a committee when a finality proof is provided
     * @notice This function takes a swap instruction on Incognito Chain, checks for its validity and stores the candidates
     * @notice This only works when the contract is not Paused
     * @notice All params except inst are the list of 2 elements corresponding to the proof on beacon and bridge
     */
    function submitBridgeCandidate( // 1.07M
        bytes memory inst,
        InstructionProof[2] memory instProofs
    ) public isNotPaused {
        // DATA: 110k
        // Parse instruction and check metadata
        CommitteeMeta memory cm; // Temp var to by pass max local var in a function
        (cm.meta, cm.shard, cm.startHeight, cm.numVals, cm.id) = extractMetaFromInstruction(inst);
        require(cm.meta == 71 && cm.shard == 1);

        // Verify instruction on beacon
        // NOTE: assuming no swap candidate for beacon
        // TODO: find correct committee to swap instead of just getting the last one
        bytes32 instHash = keccak256(inst);
        address[] memory signers = filterSigners(instProofs[0].sigIdx, validatorStorage.loadCommittee(true)); // 9k
        bytes32 root = calcMerkleRoot(instHash, instProofs[0].id, instProofs[0].path);
        require(instructionApprovedBySigners(
            instHash,
            signers,
            instProofs[0]
        ), "invalid beacon instruction"); // 26k

        // Verify instruction on bridge
        uint latestSwapID = committeeSwapID[false];
        require(cm.id > latestSwapID, "cannot submit candidate for old swaps");
        if (cm.id == latestSwapID + 1) {
            signers = filterSigners(instProofs[1].sigIdx, validatorStorage.loadCommittee(false)); // 47k
        } else {
            signers = filterSigners(instProofs[1].sigIdx, validatorStorage.loadCandidates(false, cm.id - 1));
        }
        require(instructionApprovedBySigners(
            instHash,
            signers,
            instProofs[1]
        ), "invalid bridge instruction"); // 140k

        // Store candidates
        // blockHash is from beacon block, we need to prove that block is final
        // before promoting this candidates to committee
        // TODO: do not submit old addrs, extract from storage
        signers = extractCommitteeFromInstruction(inst, cm.numVals);
        bytes32 blk = keccak256(abi.encodePacked(keccak256(abi.encodePacked(instProofs[0].blkData, root))));
        validatorStorage.storeCandidates(false, cm.id, oldGID, newGID, newAddrs); // 730k
        swapBeaconHash[false][cm.id] = blk;

        emit SubmittedBridgeCandidate(cm.startHeight);
    }

    /**
     * @dev Updates the latest committee of the beacon chain
     * @notice This function takes a swap instruction on Incognito Chain, checks for its validity and stores the latest committee
     * @notice This only works when the contract is not Paused
     * @notice Swapping beacon committee doesn't require that the instruction is included in the bridge chain
     * @notice All params are the same as swapBridgeCommittee
     */
    function submitBeaconCandidate(
        bytes memory inst,
        InstructionProof memory instProof
    ) public isNotPaused {
        // Parse instruction and check metadata
        CommitteeMeta memory cm;
        (cm.meta, cm.shard, cm.startHeight, cm.numVals, cm.id) = extractMetaFromInstruction(inst);
        require(cm.meta == 70 && cm.shard == 1);

        // Verify instruction on beacon
        bytes32 instHash = keccak256(inst);
        address[] memory signers;
        uint latestSwapID = committeeSwapID[true];
        require(cm.id > latestSwapID, "cannot submit candidate for old swaps");
        if (cm.id == latestSwapID + 1) {
            signers = filterSigners(instProof.sigIdx, validatorStorage.loadCommittee(true));
        } else {
            signers = filterSigners(instProof.sigIdx, validatorStorage.loadCandidates(true, cm.id - 1));
        }
        require(instructionApprovedBySigners(
            instHash,
            signers,
            instProof
        ));

        // Store candidates
        address[] memory pubkeys = extractCommitteeFromInstruction(inst, cm.numVals);
        bytes32 root = calcMerkleRoot(instHash, instProof.id, instProof.path);
        bytes32 blk = keccak256(abi.encodePacked(keccak256(abi.encodePacked(instProof.blkData, root))));
        validatorStorage.storeCandidates(true, cm.id, oldGID, newGID, newAddrs);
        swapBeaconHash[true][cm.id] = blk;

        emit SubmittedBeaconCandidate(cm.startHeight);
    }

    // // TODO: doc
    // function loadCandidates(uint swapID, bool isBeacon) public returns (address[] memory) {
    //     if (isBeacon) {
    //         require(beaconCandidates[swapID].pubkeys.length > 0, "invalid beacon swapID");
    //         return beaconCandidates[swapID].pubkeys;
    //     }
    //     require(bridgeCandidates[swapID].pubkeys.length > 0, "invalid bridge swapID");
    //     return bridgeCandidates[swapID].pubkeys;
    // }

    // TODO: doc
    function submitFinalityProof( // 500k bridge, 150k beacon
        bytes[2] memory insts,
        InstructionProof[2] memory instProofs,
        uint swapID,
        bool isBeacon
    ) public isNotPaused {
        // DATA: 140k
        // TODO: optimize: first block check merkle proof instead of sigs
        // Extract the committee signed the instructions
        // Using the same committee for both blocks: we do not support two
        // adjacent blocks with increasing timeslots but signed by 2 different committees
        require(swapID >= committeeSwapID[isBeacon], "proof must be signed by new committee/candidate");
        address[] memory signers = validatorStorage.loadCandidates(isBeacon, swapID); // 30k

        // Check if both BlockMerkleRoot instructions are valid
        for (uint i = 0; i < 2; i++) {
            // Extract signers that signed this block (require sigIdx to be strictly increasing)
            address[] memory signersTmp = filterSigners(instProofs[i].sigIdx, signers);

            require(instructionApprovedBySigners(
                keccak256(insts[i]),
                signersTmp,
                instProofs[i]
            ), "invalid signatures");
        } // 300k

        // Validate instruction's data
        (uint8 meta0, bytes32 rootHash, uint proposeTime0) = extractDataFromBlockMerkleInstruction(insts[0]);
        (uint8 meta1, bytes32 _, uint proposeTime1) = extractDataFromBlockMerkleInstruction(insts[1]);
        require(proposeTime0 / 10 + 1 == proposeTime1 / 10, "proposeTime invalid");
        require(meta0 == 73 && meta1 == 73, "invalid meta");

        // Save the block merkle root
        if (isBeacon) {
            beaconFinality = Finality({
                blockHeight: 0, // TODO: save height if needed
                rootHash: rootHash
            });
        } else {
            bridgeFinality = Finality({
                blockHeight: 0,
                rootHash: rootHash
            });
        }
        emit ChainFinalized(isBeacon);
    }

    // TODO: doc
    function promoteCandidate( // 800k bridge
        uint swapID,
        bool isBeacon,
        MerkleProof memory proof
    ) public isNotPaused {
        // DATA: 7k
        // Extract block data
        bytes32 blockHash = swapBeaconHash[isBeacon][swapID];

        // Check that block is in merkle tree
        require(blockIsFinal(
            true,
            blockHash,
            proof.id,
            proof.path
        ));

        // This must be the next swapID
        require(committeeSwapID[isBeacon] + 1 == swapID, "must promote candidate sequentially");

        // Move candidate to committee
        validatorStorage.storeCommittee(isBeacon, gID1, gID2); // 770k

        emit CandidatePromoted(swapID, isBeacon);
    }

    // TODO: doc
    function blockIsFinal(
        bool isBeacon,
        bytes32 blockHash,
        uint blockID,
        bytes32[] memory path
    ) public view returns (bool) {
        bytes32 blockRoot;
        if (isBeacon) {
            blockRoot = beaconFinality.rootHash;
        } else {
            blockRoot = bridgeFinality.rootHash;
        }
        return calcMerkleRoot(blockHash, blockID, path) == blockRoot;
    }

    function instructionApprovedBySigners(
        bytes32 instHash,
        address[] memory signers,
        InstructionProof memory instProof
    ) public view returns (bool) {
        // Get root of instruction merkle trr
        bytes32 root = calcMerkleRoot(instHash, instProof.id, instProof.path);

        // Get double block hash from instRoot and other data
        bytes32 blk = keccak256(abi.encodePacked(keccak256(abi.encodePacked(instProof.blkData, root))));

        // Check if enough validators signed this block
        if (instProof.sigV.length <= signers.length * 2 / 3) {
            return false;
        }

        // Check that signature is correct
        return verifySig(signers, blk, instProof.sigV, instProof.sigR, instProof.sigS);
    }

    // TODO: doc
    /**
     * @dev Checks if a value is in a merkle tree
     */
    function calcMerkleRoot(
        bytes32 leaf,
        uint id,
        bytes32[] memory path
    ) public pure returns (bytes32) {
        for (uint i = 0; i < path.length; i++) {
            if (id & 1 > 0) {
                leaf = keccak256(abi.encodePacked(path[i], leaf));
            } else if (path[i] == 0x0) {
                leaf = keccak256(abi.encodePacked(leaf, leaf));
            } else {
                leaf = keccak256(abi.encodePacked(leaf, path[i]));
            }
            id = id >> 1;
        }
        return leaf;
    }

    /**
     * @dev Extracts the metadata of a swap instruction
     * @param inst: the full instruction, containing both metadata and body
     * @return meta: type of the instruction, 70 for swapping beacon and 71 for bridge
     * @return shard: ID of the Incognito shard containing the instruction, must be 1
     * @return height: the starting block that the committee is responsible for
     * @return numVals: number of validators in the new committee
     * @return id: id of the swap
     */
    function extractMetaFromInstruction(bytes memory inst) public pure returns(uint8, uint8, uint, uint, uint) {
        require(inst.length >= 0x62); // 0x02 bytes for meta and shard, 0x20 each for height, numVals and swapID
        uint8 meta = uint8(inst[0]);
        uint8 shard = uint8(inst[1]);
        uint height;
        uint numVals;
        uint id;
        assembly {
            // skip first 0x20 bytes (stored length of inst)
            height := mload(add(inst, 0x22)) // [2:34]
            numVals := mload(add(inst, 0x42)) // [34:66]
            id := mload(add(inst, 0x62)) // [66:98]
        }
        return (meta, shard, height, numVals, id);
    }

    /**
     * @dev Extracts the committee (body) from a swap instruction
     * @param inst: the full instruction, containing both metadata and body
     * @param numVals: number of validators in the new committee
     * @return committee: address of the committee members
     */
    function extractCommitteeFromInstruction(bytes memory inst, uint numVals) public pure returns (address[] memory) {
        require(inst.length == 0x62 + numVals * 0x20);
        address[] memory addr = new address[](numVals);
        address tmp;
        for (uint i = 0; i < numVals; i++) {
            assembly {
                // skip first 0x20 bytes (stored length of inst)
                // also, skip the next 0x62 bytes (stored metadata)
                tmp := mload(add(add(inst, 0x82), mul(i, 0x20))) // 98+i*32
            }
            addr[i] = tmp;
        }
        return addr;
    }

    function extractDataFromBlockMerkleInstruction(bytes memory inst) public pure returns (uint8, bytes32, uint) {
        require(inst.length >= 0x41); // 0x01 bytes for meta and shard, 0x20 each for rootHash and proposeTime
        uint8 meta = uint8(inst[0]);
        bytes32 rootHash;
        uint proposeTime;
        assembly {
            // skip first 0x20 bytes (stored length of inst)
            rootHash := mload(add(inst, 0x21)) // [1:33]
            proposeTime := mload(add(inst, 0x41)) // [33:65]
        }
        return (meta, rootHash, proposeTime);
    }

    // TODO: doc
    function filterSigners(uint[] memory sigIdx, address[] memory signers) public pure returns (address[] memory) {
        address[] memory signersTmp = new address[](signers.length);
        for (uint i = 0; i < sigIdx.length; i++) {
            if ((i > 0 && sigIdx[i] <= sigIdx[i-1]) || sigIdx[i] >= signers.length) {
                revert("sigIdx invalid");
            }
            signersTmp[i] = signers[sigIdx[i]];
        }
        return signersTmp;
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
