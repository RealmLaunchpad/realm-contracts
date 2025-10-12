# Natspects and function documentation

For all the contracts in `src/`, I want you to go through all the state variables and functions (except internals) and add natspect documentation **to those functions that don't already have it**.

## Rules
- If a function/state variable has some documentation but not as complete as I suggest below, add the missing fields
- Be as concise as possible in the comments
- ONLY add comments. Do NOT change any code
- See instructions below on how to document functions and variables

### Functions

The format I want you to use is the triple slash. Example:

```
/// @notice This describes the purpose of the function
/// @dev This gives some indications for devs (not always necessary)
/// @param token Description of the `token` input argument
/// @param amount Description of the `amount` input argument
/// @return Description of the returned value
function deposit(address token, uint256 amount) external returns (uint256) {
    // ... 
}
```

### Storage variables

Also follow the triple slash convention for comments. Document all the state variables in all the contracts. Example:


```
contract Vault {
    /// @notice Description of the `deadline` parameter
    /// @dev units of the parameter if relevant
    uint256 public deadline;

    /// @notice Description of the `MAX_DEPOSIT` parameter
    /// @dev units of `MAX_DEPOSIT` only if relevant 
    uint256 internal constant MAX_DEPOSIT;
}
```