// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRoleStore {
    function getRoleMembers(bytes32 roleKey, uint256 start, uint256 end)
        external
        view
        returns (address[] memory);
    
    function grantRole(address account, bytes32 roleKey) external;
    function hasRole(address account, bytes32 roleKey) external view returns (bool);
}
