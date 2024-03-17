pragma solidity 0.8.24;

// external libs
import {ERC1967Proxy} from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import {ENS} from "@ensdomains/ens-contracts/contracts/registry/ENS.sol";

// aragon core
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {PermissionLib} from "@aragon/osx/core/permission/PermissionLib.sol";

// aragon framework
import {ENSSubdomainRegistrar} from "@aragon/osx/framework/utils/ens/ENSSubdomainRegistrar.sol";
import {DAORegistry} from "@aragon/osx/framework/dao/DAORegistry.sol";
import {PluginRepoFactory} from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";
import {PluginRepoRegistry} from "@aragon/osx/framework/plugin/repo/PluginRepoRegistry.sol";
import {PluginSetupProcessor} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {DAOFactory} from "@aragon/osx/framework/dao/DAOFactory.sol";

// forge
import {Test} from "forge-std/Test.sol";

// local
import {MockENS} from "./mocks/MockENS.sol";

// constants
bytes32 constant PLUGIN_ETH = keccak256("plugin.dao.eth");
bytes32 constant DAO_ETH = keccak256("dao.eth");

function bytes32ToAddress(bytes32 _bytes32) pure returns (address) {
    return address(uint160(uint256(_bytes32)));
}

/**
 * @title TestNoFork
 * @notice deploy the entire aragon stack locally without needing a forked environment.
 * BLAZINGLY FAST TESTING IS NOW UNLOCKED
 */
contract TestNoFork is Test {
    address deployer = address(420);
    DAO managementDAO;
    MockENS ens;
    ENSSubdomainRegistrar daoSDR;
    ENSSubdomainRegistrar pluginSDR;
    DAOFactory daoFactory;
    DAORegistry daoRegistry;
    PluginRepoFactory pluginRepoFactory;
    PluginRepoRegistry pluginRepoRegistry;
    PluginSetupProcessor pluginSetupProcessor;

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
            ens = new MockENS();
            {
                ens.setResolver(DAO_ETH, bytes32ToAddress(DAO_ETH));
                ens.setResolver(PLUGIN_ETH, bytes32ToAddress(PLUGIN_ETH));
            }
            {
                ENSSubdomainRegistrar impl = new ENSSubdomainRegistrar();

                ERC1967Proxy daoSDRProxy = new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        ENSSubdomainRegistrar.initialize,
                        (managementDAO, ENS(address(ens)), DAO_ETH)
                    )
                );

                ERC1967Proxy pluginSDRPtoxy = new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        ENSSubdomainRegistrar.initialize,
                        (managementDAO, ENS(address(ens)), PLUGIN_ETH)
                    )
                );

                daoSDR = ENSSubdomainRegistrar(payable(address(daoSDRProxy)));
                pluginSDR = ENSSubdomainRegistrar(payable(address(pluginSDRPtoxy)));
            }
        }

        // deploy the DAO registry
        {
            DAORegistry impl = new DAORegistry();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(DAORegistry.initialize, (managementDAO, daoSDR))
            );
            daoRegistry = DAORegistry(payable(address(proxy)));
        }

        // deploy plugin repo registry
        {
            PluginRepoRegistry impl = new PluginRepoRegistry();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(PluginRepoRegistry.initialize, (managementDAO, pluginSDR))
            );
            pluginRepoRegistry = PluginRepoRegistry(payable(address(proxy)));
        }

        // deploy the non-upgradeable plugin repo factory
        {
            pluginRepoFactory = new PluginRepoFactory(pluginRepoRegistry);
        }

        // deploy the non-upgradeable plugin setup processor
        {
            pluginSetupProcessor = new PluginSetupProcessor(pluginRepoRegistry);
        }

        // deploy the non-upgradeable DAO factory
        {
            daoFactory = new DAOFactory(daoRegistry, pluginSetupProcessor);
        }

        vm.stopPrank();
    }
}
