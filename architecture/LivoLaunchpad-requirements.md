---

## **Technical Requirements for Livo Launchpad MVP (Phase 1\)**

---

## **Objective**

Deliver a Launchpad platform on Ethereum, enabling frictionless token deployment with integrated bonding curve mechanics and automatic liquidity migration to Uniswap V2 upon graduation, with LP tokens locked or burned to ensure liquidity permanence.

---

## **Core Features**

### **1-Click Token Deployment**

* Simple frontend for users to create tokens.

* Required inputs:

  * Token Name

  * Token Ticker

  * Logo / Basic Metadata

* Deployed tokens are automatically integrated into a Livo-controlled bonding curve contract.

---

### **Bonding Curve Mechanics**

* Bonding curve used to control price discovery and distribution.

* ETH collected during the bonding curve phase remains locked in the contract (minus fees).

* Tokens are not visible on external DEXs during this phase; trades occur through the Livo Launchpad frontend.

---

## **Graduation / Migration Process**

**Graduation Trigger:**

* Pre-defined milestone, e.g., token achieves $80k market cap.

* Graduation criteria by reading ETH/USD chainlink oracle, assuming MCAP is double that value when liquidity is provided.

**Graduation Actions:**

* Deploy liquidity to **Uniswap V2** pool.

* Provide liquidity using:

  * All ETH accumulated in bonding curve

  * Remaining tokens from bonding curve contract

* Lock or burn Uniswap V2 LP tokens to guarantee liquidity permanence.

* Disable the bonding curve contract for further trading post-graduation.

---

## **DEX Integration**

* **Uniswap V2** is selected for graduation phase for simplicity and standardized liquidity pools (50/50 ETH-token).

* Tokens become publicly tradable via Uniswap V2 post-graduation.

---

## **Fee Structure**

* **Bonding Curve Phase:** 

  * 1% fee on trading volume.  
    * Fee taken on ETH   
    * Fee shared between treasury/creator (50/50 initially).   
    * Make fee-share configurable for new tokens (immutable for already deployed ones).

* **Graduation / Migration:**

  * Graduation criteria: an amount of ETH collected, fx, 20 ETH (not based on USD denomination)  
  * Target after graduation (review these numbers):  
    * 80k mcap (roughly, but will depend on the ETH price)  
    * 20-25k liquidity

  * Graduation fee: 0.1 ETH to the treasury only  
  * Creator compensation: 1% of the token supply to the creator

* **Uniswap V2**

  * UniV2 offers only a 0.3% fee tier.  
  * For this MPV, LP tokens will be burned and we won’t collect fees.  
  


  
---

## **Frontend Requirements**

* Token status dashboard (bonding curve progress, approaching graduation, etc.).

* Project filters (New, Best Performing, Hot, etc.).

* Clear indication of tokens pre- and post-graduation status.

---

## 

## 

## **Summary Workflow**

**Phase 1 (Pre-Launch):**

1. User deploys token via Livo frontend.

2. Token enters bonding curve for price discovery.

3. Trades occur solely within Livo’s platform and smart contracts.  
4. Fees:  
   1. Tokens are burned  
   2. ETH collected goes 50/50% for creator/treasury

**Phase 2 (Graduation):**

1. Token meets graduation threshold.

2. ETH and tokens provided as liquidity to Uniswap V2.

3. LP tokens are locked in a Livo contract which cannot retrieve liquidity, but can collect trading fees. 

   * ETH collected is kept: 50/50% for creator/treasury  
   * Tokens are burned

4. Trading only happens in Uniswap V2 from here onwards
