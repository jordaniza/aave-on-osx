pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {PermissionLib} from "@aragon/osx/core/permission/PermissionLib.sol";
import {ERC1967Proxy} from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title TestNoFork
 * @notice deploy the entire aragon stack locally without needing a forked environment.
 * BLAZINGLY FAST TESTING IS NOW UNLOCKED
 */
contract TestNoFork is Test {
    address deployer = address(420);
    DAO managementDAO;

    function testSetup() public {
        vm.startPrank(deployer);

        // deploy management DAO
        {
            DAO impl = new DAO();
            bytes memory initData = abi.encodeCall(
                DAO.initialize,
                (bytes(""), deployer, address(0), "0x")
            );

            // deploy management DAO proxy
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            // wrap the DAO
            managementDAO = DAO(payable(address(proxy)));
        }

        // set the permissions
        {
            PermissionLib.MultiTargetPermission[]
                memory permissions = new PermissionLib.MultiTargetPermission[](1);

            permissions[0] = PermissionLib.MultiTargetPermission({
                where: address(managementDAO),
                who: deployer,
                operation: PermissionLib.Operation.Grant,
                condition: address(0),
                permissionId: keccak256("EXECUTE_PERMISSION")
            });
            managementDAO.applyMultiTargetPermissions(permissions);
        }
        {
            // set DAO factory permissions equivalents
            PermissionLib.MultiTargetPermission[]
                memory permissions = new PermissionLib.MultiTargetPermission[](6);
            bytes32[] memory DAO_PERMISSIONS = new bytes32[](6);
            DAO_PERMISSIONS[0] = keccak256("ROOT_PERMISSION");
            DAO_PERMISSIONS[1] = keccak256("UPGRADE_DAO_PERMISSION");
            DAO_PERMISSIONS[2] = keccak256("SET_SIGNATURE_VALIDATOR_PERMISSION");
            DAO_PERMISSIONS[3] = keccak256("SET_TRUSTED_FORWARDER_PERMISSION");
            DAO_PERMISSIONS[4] = keccak256("SET_METADATA_PERMISSION");
            DAO_PERMISSIONS[5] = keccak256("REGISTER_STANDARD_CALLBACK_PERMISSION");

            for (uint256 i = 0; i < DAO_PERMISSIONS.length; i++) {
                permissions[i] = PermissionLib.MultiTargetPermission({
                    where: address(managementDAO),
                    who: address(managementDAO),
                    operation: PermissionLib.Operation.Grant,
                    condition: address(0),
                    permissionId: DAO_PERMISSIONS[i]
                });
            }
            managementDAO.applyMultiTargetPermissions(permissions);
        }

        // validate - simple for now
        {
            require(
                managementDAO.isGranted({
                    _where: address(managementDAO),
                    _who: deployer,
                    _permissionId: keccak256("EXECUTE_PERMISSION"),
                    _data: bytes("")
                }),
                "TestNoFork: permission not set"
            );
        }

        // deploy the mock ENS and connect it, skip the actual setup we don't care for unit tests
        {

        }

        vm.stopPrank();
    }
}
