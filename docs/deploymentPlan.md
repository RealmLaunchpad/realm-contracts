# Deployment guidelines

- foundry.toml: optimization runs : 200 or more
- deploy token implementation 
- deploy bonding curve
- deploy Livo Launchpad
- deploy graduatorV2
- deploy Univ4 liquidity lock
- deploy graduatorV4
- whitelist set of implementation,curve,graduator, with graduation parameters:
    ```
        uint256 constant GRADUATION_THRESHOLD = 7956000000000052224; // ~8 ether
        uint256 constant MAX_EXCESS_OVER_THRESHOLD = 0.1 ether;
        uint256 constant GRADUATION_ETH_FEE = 0.5 ether;
    ```

- update launchpad address in envio
