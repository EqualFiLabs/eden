# EDEN Production App + Agent Upgrade Spec

**Status:** Proposed
**Date:** 2026-03-23
**Purpose:** Define contract-level upgrades required to make EDEN production-grade for frontend development, protocol operations, integrations, and AI-agent usage.

---

## 1. Design Goal

EDEN should be queryable and operable as a complete system, not merely callable as a set of isolated primitives.

That means the protocol must expose:

1. **Discovery** — enumerate baskets, loans, configs, facets, and protocol state cleanly
2. **Portfolio introspection** — describe a user’s holdings, locked collateral, rewards, and open loans in a machine-readable way
3. **Deterministic previews** — quote outcomes for all user actions before execution
4. **Execution ergonomics** — batch calls, permit flows, one-shot convenience operations
5. **Agent-native surfaces** — dense state endpoints, permissions, action checks, metadata, and policy hooks
6. **Operational introspection** — make governance/config state visible and auditable without storage spelunking

This spec assumes **greenfield latitude**. It is explicitly optimized for production usefulness, not a stripped-down MVP.

---

## 2. High-Level Principles

### 2.1 Queryability over RPC archaeology
The frontend and agents should not need to reconstruct protocol state from many fragmented calls, raw storage assumptions, or event replays just to render the current system state.

### 2.2 Structured returns over parallel arrays
Where possible, prefer typed structs over loosely related arrays. Parallel arrays are error-prone for both UI code and agent reasoning.

### 2.3 Preview before signature
Every meaningful mutative path should have a deterministic preview or action-check surface.

### 2.4 Agent-safe by default
AI agents should be able to:
- understand user state
- quote next actions
- execute batched flows
- operate under delegated permissions
- inspect protocol metadata and versions

without fragile custom middleware.

### 2.5 Event completeness matters
Indexers, bots, agents, and admin tooling require explicit events for state changes that matter.

---

## 3. Recommended New Facets

To keep the production surface clean, add dedicated facets instead of overloading a single view contract.

- `EdenPortfolioFacet` — user portfolio, positions, rewards, loans
- `EdenMetadataFacet` — discovery, metadata, feature flags, versions
- `EdenAgentFacet` — delegated permissions, action checks, dense state objects
- `EdenBatchFacet` — multicall and one-shot convenience execution

Existing facets should also be expanded where natural:
- `EdenStEVEFacet` → reward previews + reward config reads
- `EdenLendingFacet` → loan indexing + lending previews
- `EdenAdminFacet` → admin reads + complete event coverage

---

## 4. Basket Discovery + Metadata Upgrades

### 4.1 Problem
Current contracts can fetch a basket by id, but do not expose a production-grade discovery surface for:
- basket enumeration
- summaries
- metadata
- feature detection
- creator provenance

### 4.2 Storage additions
```solidity
struct BasketMetadata {
    string name;
    string symbol;
    string uri;
    address creator;
    uint64 createdAt;
    uint8 basketType;
    bool lendingEnabled;
    bool flashEnabled;
}

mapping(uint256 => BasketMetadata) basketMetadata;
```

### 4.3 Read structs
```solidity
struct BasketSummary {
    uint256 basketId;
    address token;
    bool paused;
    bool lendingEnabled;
    bool flashEnabled;
    uint256 totalUnits;
    uint16 flashFeeBps;
    address[] assets;
    uint256[] bundleAmounts;
    string name;
    string symbol;
    string uri;
    address creator;
    uint64 createdAt;
    uint8 basketType;
}
```

### 4.4 New functions
```solidity
function basketCount() external view returns (uint256);
function steveBasketId() external view returns (uint256);
function getBasketIds(uint256 start, uint256 limit) external view returns (uint256[] memory);
function getBasketSummary(uint256 basketId) external view returns (BasketSummary memory);
function getBasketSummaries(uint256[] calldata basketIds) external view returns (BasketSummary[] memory);
function basketURI(uint256 basketId) external view returns (string memory);
function isStEVEBasket(uint256 basketId) external view returns (bool);
function isSingleAssetBasket(uint256 basketId) external view returns (bool);
function isBorrowEnabled(uint256 basketId) external view returns (bool);
function isFlashEnabled(uint256 basketId) external view returns (bool);
```

### 4.5 Why this matters
This makes the app able to:
- render basket lists without hacks
- route to basket pages cleanly
- support agent basket discovery
- expose creator/strategy/category context

---

## 5. User Portfolio + Position Introspection

### 5.1 Problem
The current protocol exposes primitives but not user state. The app and agents need a canonical “what does this wallet own / owe / earn?” surface.

### 5.2 Storage additions
```solidity
mapping(address => uint256[]) userBasketIds;
mapping(address => mapping(uint256 => bool)) userHasBasket;
```

### 5.3 New structs
```solidity
struct UserBasketPosition {
    uint256 basketId;
    address token;
    uint256 walletUnits;
    uint256 lockedUnits;
    uint256 totalUnits;
    uint256 nav;
    address[] assets;
    uint256[] bundleAmounts;
    uint256[] redeemableUnderlying;
    uint256[] feePotShare;
}

struct UserPortfolio {
    address user;
    uint256 eveBalance;
    uint256 claimableRewards;
    uint256 stEveBalance;
    uint256 stEveLocked;
    uint256 basketCount;
    uint256 loanCount;
    UserBasketPosition[] baskets;
    LoanView[] loans;
}
```

### 5.4 New functions
```solidity
function getUserBasketIds(address user) external view returns (uint256[] memory);
function getUserBasketPosition(address user, uint256 basketId) external view returns (UserBasketPosition memory);
function getUserBasketPositions(address user, uint256[] calldata basketIds) external view returns (UserBasketPosition[] memory);
function getUserPortfolio(address user) external view returns (UserPortfolio memory);
```

### 5.5 Why this matters
This removes the need for the app or an agent to stitch together balances, locks, NAV, rewards, and loans from many independent calls.

---

## 6. Loan Indexing + Lifecycle Views

### 6.1 Problem
`getLoan(loanId)` is not enough. Production UI and agents need borrower-scoped loan discovery.

### 6.2 Storage additions
```solidity
mapping(address => uint256[]) borrowerLoanIds;
mapping(uint256 => bool) loanClosed;
mapping(uint256 => uint256) loanCreatedAt;
```

Optional:
```solidity
mapping(uint256 => uint256) loanClosedAt;
```

### 6.3 New struct
```solidity
struct LoanView {
    uint256 loanId;
    address borrower;
    uint256 basketId;
    uint256 collateralUnits;
    uint16 ltvBps;
    uint40 maturity;
    uint256 createdAt;
    bool active;
    bool expired;
    address[] assets;
    uint256[] principals;
    uint256 extensionFeeNative;
}
```

### 6.4 New functions
```solidity
function loanCount() external view returns (uint256);
function getLoanView(uint256 loanId) external view returns (LoanView memory);
function getLoanIdsByBorrower(address user) external view returns (uint256[] memory);
function getActiveLoanIdsByBorrower(address user) external view returns (uint256[] memory);
function getLoansByBorrower(address user) external view returns (LoanView[] memory);
function getActiveLoansByBorrower(address user) external view returns (LoanView[] memory);
```

### 6.5 Why this matters
Without loan indexing:
- the app can’t show “your loans” naturally
- agents can’t safely manage positions
- notifications become awkward

---

## 7. Reward Introspection Upgrades

### 7.1 Problem
`claimRewards()` exists, but there is no canonical preview surface for claimable rewards.

### 7.2 New structs
```solidity
struct RewardConfig {
    uint256 genesisTimestamp;
    uint256 epochDuration;
    uint256 halvingInterval;
    uint256 maxPeriods;
    uint256 baseRewardPerEpoch;
    uint256 totalEpochs;
    uint256 rewardReserve;
    uint256 rewardPerEpochOverride;
    uint256 maxRewardPerEpochOverride;
}

struct RewardPreview {
    address user;
    uint256 fromEpoch;
    uint256 toEpoch;
    uint256 totalClaimable;
}

struct RewardEpochBreakdown {
    uint256 epoch;
    uint256 reward;
    uint256 userTwab;
    uint256 totalTwab;
}
```

### 7.3 New functions
```solidity
function getRewardConfig() external view returns (RewardConfig memory);
function claimableRewards(address user) external view returns (uint256);
function previewClaimRewards(address user) external view returns (RewardPreview memory);
function claimableRewardsThroughEpoch(address user, uint256 epoch) external view returns (uint256);
function getRewardEpochBreakdown(address user, uint256 startEpoch, uint256 endEpoch)
    external
    view
    returns (RewardEpochBreakdown[] memory);
```

### 7.4 Why this matters
Critical for:
- UI claim screens
- cron jobs
- agent auto-claim logic
- analytics
- user trust

---

## 8. Protocol Config + Lending Config Reads

### 8.1 New structs
```solidity
struct ProtocolConfig {
    address owner;
    address timelock;
    address treasury;
    uint16 treasuryFeeBps;
    uint16 feePotShareBps;
    uint16 protocolFeeSplitBps;
    uint256 basketCreationFee;
}

struct BasketFeeConfig {
    uint256 basketId;
    uint16[] mintFeeBps;
    uint16[] burnFeeBps;
    uint16 flashFeeBps;
}

struct LendingConfigView {
    uint256 basketId;
    bool enabled;
    uint40 minDuration;
    uint40 maxDuration;
    uint16 ltvBps;
    BorrowFeeTier[] tiers;
}
```

### 8.2 New functions
```solidity
function getProtocolConfig() external view returns (ProtocolConfig memory);
function getBasketFeeConfig(uint256 basketId) external view returns (BasketFeeConfig memory);
function getLendingConfig(uint256 basketId) external view returns (LendingConfigView memory);
function getBorrowFeeTiers(uint256 basketId) external view returns (BorrowFeeTier[] memory);
function getFrozenFacets() external view returns (address[] memory);
function facetFrozen(address facet) external view returns (bool);
```

---

## 9. Deterministic Preview Surfaces

### 9.1 New structs
```solidity
struct BorrowPreview {
    uint256 basketId;
    uint256 collateralUnits;
    uint40 duration;
    address[] assets;
    uint256[] principals;
    uint256 feeNative;
    uint40 maturity;
    uint256 resultingLockedCollateral;
    bool invariantSatisfied;
}

struct ExtendPreview {
    uint256 loanId;
    uint40 addedDuration;
    uint40 newMaturity;
    uint256 feeNative;
}

struct RepayPreview {
    uint256 loanId;
    address[] assets;
    uint256[] principals;
    uint256 unlockedCollateralUnits;
}
```

### 9.2 New functions
```solidity
function previewBorrow(uint256 basketId, uint256 collateralUnits, uint40 duration)
    external
    view
    returns (BorrowPreview memory);

function previewExtend(uint256 loanId, uint40 addedDuration)
    external
    view
    returns (ExtendPreview memory);

function previewRepay(uint256 loanId)
    external
    view
    returns (RepayPreview memory);
```

---

## 10. Action Validation Surfaces

### 10.1 New struct
```solidity
struct ActionCheck {
    bool ok;
    uint8 code;
    string reason;
}
```

### 10.2 New functions
```solidity
function canMint(address user, uint256 basketId, uint256 units) external view returns (ActionCheck memory);
function canBurn(address user, uint256 basketId, uint256 units) external view returns (ActionCheck memory);
function canBorrow(address user, uint256 basketId, uint256 collateralUnits, uint40 duration)
    external
    view
    returns (ActionCheck memory);
function canRepay(address user, uint256 loanId) external view returns (ActionCheck memory);
function canExtend(address user, uint256 loanId, uint40 addedDuration) external view returns (ActionCheck memory);
function canClaimRewards(address user) external view returns (ActionCheck memory);
```

---

## 11. Batched Execution + Convenience Writes

### 11.1 New facet
Add `EdenBatchFacet`.

### 11.2 New functions
```solidity
function multicall(bytes[] calldata calls) external payable returns (bytes[] memory results);
function claimAndMintStEVE(uint256 minUnitsOut, address to) external returns (uint256 unitsMinted);
function repayAndUnlock(uint256 loanId) external;
function extendMany(uint256[] calldata loanIds, uint40[] calldata addedDurations) external payable;
```

---

## 12. Permit Execution Surfaces

### 12.1 New functions
```solidity
function mintWithPermit(
    uint256 basketId,
    uint256 units,
    address to,
    PermitData[] calldata permits
) external returns (uint256 minted);

function repayWithPermit(
    uint256 loanId,
    PermitData[] calldata permits
) external;

function fundRewardsWithPermit(
    uint256 amount,
    PermitData calldata permit
) external;
```

---

## 13. Agent Delegation + Permissions

### 13.1 Storage additions
```solidity
struct OperatorPermissions {
    bool canMint;
    bool canBurn;
    bool canClaim;
    bool canBorrow;
    bool canRepay;
    bool canExtend;
    uint64 expiry;
}

mapping(address => mapping(address => OperatorPermissions)) operatorPermissions;
```

### 13.2 New functions
```solidity
function setOperatorPermissions(address operator, OperatorPermissions calldata permissions) external;
function revokeOperator(address operator) external;
function getOperatorPermissions(address owner, address operator) external view returns (OperatorPermissions memory);
function isOperatorAuthorized(address owner, address operator, uint8 action) external view returns (bool);
```

### 13.3 Execution model
Mutative functions should accept authorized operators where appropriate:
- operator may claim rewards for user to user’s address
- operator may mint to user
- operator may borrow on behalf of user if explicitly authorized
- operator may repay / extend if authorized

---

## 14. Dense Agent State Endpoints

### 14.1 New structs
```solidity
struct FeatureFlags {
    bool rewardsEnabled;
    bool lendingEnabled;
    bool flashEnabled;
    bool permissionlessCreationEnabled;
    bool operatorDelegationEnabled;
}

struct ProtocolState {
    ProtocolConfig config;
    RewardConfig rewards;
    uint256 basketCount;
    uint256 loanCount;
    uint256 steveBasketId;
    address[] frozenFacets;
    FeatureFlags featureFlags;
}
```

### 14.2 New functions
```solidity
function getUserState(address user) external view returns (UserPortfolio memory);
function getBasketState(uint256 basketId) external view returns (BasketSummary memory);
function getLoanState(uint256 loanId) external view returns (LoanView memory);
function getProtocolState() external view returns (ProtocolState memory);
```

---

## 15. Metadata + Versioning

### 15.1 New functions
```solidity
function protocolURI() external view returns (string memory);
function contractVersion() external pure returns (string memory);
function facetVersion(address facet) external view returns (string memory);
function featureFlags() external view returns (FeatureFlags memory);
```

---

## 16. Event Upgrades

Add explicit admin/config events.

```solidity
event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
event TimelockUpdated(address indexed oldTimelock, address indexed newTimelock);
event BasketPausedUpdated(uint256 indexed basketId, bool paused);
event BasketFeeConfigUpdated(uint256 indexed basketId, uint16[] mintFeeBps, uint16[] burnFeeBps, uint16 flashFeeBps);
event BasketCreationFeeUpdated(uint256 oldFee, uint256 newFee);
event LendingConfigUpdated(uint256 indexed basketId, uint40 minDuration, uint40 maxDuration, uint16 ltvBps);
event BorrowFeeTiersUpdated(uint256 indexed basketId, uint256[] minCollateralUnits, uint256[] flatFeeNative);
event RewardConfigUpdated(uint256 genesisTimestamp, uint256 epochDuration, uint256 halvingInterval, uint256 maxPeriods, uint256 baseRewardPerEpoch, uint256 totalEpochs, uint256 maxRewardOverride);
event RewardOverrideUpdated(uint256 oldRate, uint256 newRate);
event OperatorPermissionsUpdated(address indexed owner, address indexed operator, OperatorPermissions permissions);
event OperatorRevoked(address indexed owner, address indexed operator);
```

---

## 17. Admin / Operations Query Surface

```solidity
function getAdminState() external view returns (ProtocolState memory);
function getFacetRegistry() external view returns (address[] memory facets, bool[] memory frozen);
function getFacetSelectors(address facet) external view returns (bytes4[] memory);
```

---

## 18. Production Build Order

### Phase 1 — Read surface completion
- Basket enumeration + summaries + metadata
- Reward config + claimable rewards
- Loan indexing + loan views
- Protocol config + lending config reads
- Feature flags + versions

### Phase 2 — Portfolio / agent state
- User basket indexes
- User basket positions
- User portfolio aggregation
- Dense agent state endpoints
- Action validation (`can*`)

### Phase 3 — Execution ergonomics
- multicall
- previewBorrow / previewRepay / previewExtend structs
- claimAndMintStEVE
- permit-assisted mint / repay / fundRewards

### Phase 4 — Agent permissions
- operator permissions
- action-scoped authorization
- events + admin tooling support

---

## 19. Strong Recommendations

1. **Do not make the frontend index raw events just to discover user state.** The protocol should expose canonical portfolio views.
2. **Do not rely on parallel arrays for production interfaces** when a struct can express the same state more safely.
3. **Add loan discovery before UI work proceeds seriously.** It is one of the biggest current gaps.
4. **Add `claimableRewards(address)` before building the rewards experience.** Without it, the UX is half-blind.
5. **Treat AI agents as first-class users.** Add delegated permissions and action validation now, while the contract surface is still greenfield.
6. **Add multicall early.** It will simplify both frontend work and agent orchestration.
7. **Emit full config-change events.** Future-you will want protocol observability without guessing.

---

## 20. Final Position

The biggest missing piece in EDEN is not core financial logic. It is **protocol introspection and execution ergonomics**.

Once these upgrades land, EDEN becomes:
- app-buildable without hacks
- indexer-friendly
- agent-native
- safer to automate
- easier to govern
- easier to explain

That is the right production target for a greenfield system.
