// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

/// @title MockResolver
/// @dev This is a mock contract for the ENS resolver used for testing purposes.
contract MockResolver {
    mapping(bytes32 => address) public addresses;

    /// @dev Mimics setting an address for a node in the resolver.
    function setAddr(bytes32 _node, address _addr) external {
        addresses[_node] = _addr;
        emit AddrSet(_node, _addr);
    }

    /// @dev Mimics getting the address associated with a node in the resolver.
    function addr(bytes32 node) external view returns (address) {
        return addresses[node];
    }

    event AddrSet(bytes32 indexed node, address addr);
}

/// @title MockENS
/// @dev This is a mock contract for the ENS registry used for testing purposes.
contract MockENS {
    mapping(bytes32 => address) public owners;
    mapping(bytes32 => address) public resolvers;

    /// @dev Mimics setting a subnode owner in the ENS registry.
    function setSubnodeOwner(bytes32 _node, bytes32 _label, address _owner) external {
        bytes32 subnode = keccak256(abi.encodePacked(_node, _label));
        owners[subnode] = _owner;
        emit SubnodeOwnerSet(_node, _label, _owner);
    }

    /// @dev Mimics setting a resolver for a node in the ENS registry.
    function setResolver(bytes32 _node, address _resolver) external {
        resolvers[_node] = _resolver;
        emit ResolverSet(_node, _resolver);
    }

    /// @dev Mimics getting the owner of a node in the ENS registry.
    function owner(bytes32 node) external view returns (address) {
        return owners[node];
    }

    /// @dev Mimics getting the resolver for a node in the ENS registry.
    function resolver(bytes32 node) external view returns (address) {
        return resolvers[node];
    }

    event SubnodeOwnerSet(bytes32 indexed node, bytes32 indexed label, address indexed owner);
    event ResolverSet(bytes32 indexed node, address resolver);
}
