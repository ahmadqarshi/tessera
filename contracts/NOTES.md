# T-REX / ONCHAINID interface reference

> **Purpose.** This is a read-only map of the vendored ERC-3643 (T-REX) and ONCHAINID
> sources under `contracts/lib/`, produced before we write any Solidity. Every signature,
> event, and behavioural note below is transcribed from the pinned submodule commits and
> cited with `file:line`. Where the vendored source contradicts our skills/CLAUDE docs, the
> **source wins** and the discrepancy is flagged in [§7 Deviations](#7-deviations-from-the-skill--claudemd-docs).
>
> Do not write a call from this document alone — re-open the cited file and confirm the
> signature before coding. Function names and argument order differ between T-REX versions.

---

## 0. Provenance (pinned commits)

Our ERC-3643 submodule is the community-maintained **ERC-3643/ERC-3643** fork. The original
`TokenySolutions/T-REX` repository is deprecated and now redirects there. We track tag
**4.1.3**, which is byte-identical in the core contracts to Tokeny's **4.1.6**. Both pin
**solc 0.8.17**, matching `contracts/foundry.toml` (`solc = "0.8.17"`, `evm_version = "paris"`).

| Submodule | Path | Tag | Pinned commit SHA |
| --- | --- | --- | --- |
| ERC-3643 (T-REX) | `contracts/lib/erc-3643` | `4.1.3` | `b6c5fabf86e733ede017fef754d59eeb8f80e3f4` |
| ONCHAINID | `contracts/lib/onchain-id-solidity` | `2.1.0` | `3f3b07ab9ddc0266e9d726c4a70605902fc86d48` |
| forge-std | `contracts/lib/forge-std` | `v1.9.7` | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` |
| openzeppelin-contracts | `contracts/lib/openzeppelin-contracts` | `v4.9.3` | `fd81a96f01cc42ef1c9a5399364968d0e07e9e90` |
| openzeppelin-contracts-upgradeable | `contracts/lib/openzeppelin-contracts-upgradeable` | `v4.9.3` | `3d4c0d5741b131c231e558d7a6213392ab3672a5` |

On-chain `Token.version()` returns the constant `_TOKEN_VERSION = "4.1.3"`
(`erc-3643/contracts/token/TokenStorage.sol:79`). The NatSpec in `IToken.sol` still says
"current version is 3.0.0" — that comment is stale; the constant is authoritative.

All source paths below are relative to `contracts/lib/`. `E/` abbreviates
`erc-3643/contracts/` and `O/` abbreviates `onchain-id-solidity/contracts/`.

---

## 1. Contracts we deploy — proxy model, init, and wiring signatures

### 1.0 Two implementation-authority patterns (read this first)

There are **two different, unrelated** "implementation authority" contracts in the vendored code:

- **T-REX** proxies (`E/proxy/TokenProxy.sol`, `IdentityRegistryProxy.sol`, …) delegate to a
  `TREXImplementationAuthority` (`E/proxy/authority/`) that exposes **per-contract** getters
  (`getTokenImplementation()`, `getCTRImplementation()`, …) and a versioning system. See
  `E/proxy/TokenProxy.sol:92` — the proxy calls `getTokenImplementation()`.
- **ONCHAINID** proxies (`O/proxy/IdentityProxy.sol`) delegate to a much simpler
  `ImplementationAuthority` (`O/proxy/ImplementationAuthority.sol`) with a single
  `getImplementation()`.

**Decision for our manual `Deploy.s.sol` (matches `contracts/CLAUDE.md` "build the manual
script first"):** deploy each T-REX logic contract **directly** (not behind `TokenProxy` /
`TREXImplementationAuthority`) and call its `init(...)` once. Every T-REX core contract is an
OZ-upgradeable contract guarded by the `initializer` modifier, so a direct-deployed instance
is fully usable after a single `init()` — no proxy required for a local/Amoy showcase. We only
need the ONCHAINID `ImplementationAuthority` + `IdFactory` for deploying investor identities.
Refactor to `TREXFactory` only after the manual path is green.

Each T-REX core contract inherits `OwnableUpgradeable`; `init()` calls `__Ownable_init()`,
setting `owner = msg.sender` (the deployer). The `initializer` modifier makes `init()`
callable exactly once.

### 1.1 ClaimTopicsRegistry — `E/registry/implementation/ClaimTopicsRegistry.sol`

- Upgradeable (OZ `OwnableUpgradeable` + `CTRStorage`). Initialize with `init()`.
- `function init() external initializer` — `:71`
- `function addClaimTopic(uint256 _claimTopic) external onlyOwner` — `:78` (max 15 topics; reverts on duplicate)
- `function removeClaimTopic(uint256 _claimTopic) external onlyOwner` — `:91`
- `function getClaimTopics() external view returns (uint256[] memory)` — `:106`

### 1.2 TrustedIssuersRegistry — `E/registry/implementation/TrustedIssuersRegistry.sol`

- Upgradeable (`OwnableUpgradeable` + `TIRStorage`). Initialize with `init()`.
- `function init() external initializer` — `:74`
- `function addTrustedIssuer(IClaimIssuer _trustedIssuer, uint256[] calldata _claimTopics) external onlyOwner` — `:81`
  (requires 1–15 topics, ≤50 issuers, issuer not already registered)
- `function removeTrustedIssuer(IClaimIssuer _trustedIssuer) external onlyOwner` — `:98`
- `function updateIssuerClaimTopics(IClaimIssuer _trustedIssuer, uint256[] calldata _claimTopics) external onlyOwner` — `:131`
- `function getTrustedIssuersForClaimTopic(uint256 claimTopic) external view returns (IClaimIssuer[] memory)` — `:166`
- `function isTrustedIssuer(address _issuer) external view returns (bool)` — `:173`
- `function hasClaimTopic(address _issuer, uint256 _claimTopic) external view returns (bool)` — `:191`

> `addTrustedIssuer` takes an `IClaimIssuer` (the ClaimIssuer **contract**, not the signing
> EOA) and the list of topics it may attest. For us: `addTrustedIssuer(claimIssuer, [1, 2])`.

### 1.3 IdentityRegistryStorage — `E/registry/implementation/IdentityRegistryStorage.sol`

- Upgradeable (`AgentRoleUpgradeable` + `IRSStorage`). Initialize with `init()`.
- `function init() external initializer` — `:73`
- `function addIdentityToStorage(address _userAddress, IIdentity _identity, uint16 _country) external onlyAgent` — `:80`
- `function modifyStoredIdentity(address _userAddress, IIdentity _identity) external onlyAgent` — `:98`
- `function modifyStoredInvestorCountry(address _userAddress, uint16 _country) external onlyAgent` — `:112`
- `function removeIdentityFromStorage(address _userAddress) external onlyAgent` — `:122`
- **`function bindIdentityRegistry(address _identityRegistry) external`** — `:133`
- `function unbindIdentityRegistry(address _identityRegistry) external` — `:144`
- `function storedIdentity(address _userAddress) external view returns (IIdentity)` — `:169`
- `function storedInvestorCountry(address _userAddress) external view returns (uint16)` — `:176`

> **`bindIdentityRegistry` has no explicit modifier but calls `addAgent(_identityRegistry)`
> internally (`:136`), and `addAgent` is `onlyOwner`** (`AgentRoleUpgradeable.sol:83`).
> Because it's an internal call, `msg.sender` is preserved — so **only the IRS owner can call
> `bindIdentityRegistry`**. Mechanically, binding = *adding the IdentityRegistry as an agent of
> the storage* so the IR can write identities. Omitting this step is the classic silent break:
> `registerIdentity` on the IR will revert with `AgentRole: caller does not have the Agent role`
> because the IR itself is not an agent of the storage.

### 1.4 IdentityRegistry — `E/registry/implementation/IdentityRegistry.sol`

- Upgradeable (`AgentRoleUpgradeable` + `IRStorage`). Initialize with `init(...)` (three registries).
- `function init(address _trustedIssuersRegistry, address _claimTopicsRegistry, address _identityStorage) external initializer` — `:87`
  ⚠️ **Argument order is `(trustedIssuers, claimTopics, storage)`** — note trusted-issuers comes
  first even though claim-topics is conceptually "first". Confirm at the call site.
- `function registerIdentity(address _userAddress, IIdentity _identity, uint16 _country) public onlyAgent` — `:266`
- `function batchRegisterIdentity(address[] calldata, IIdentity[] calldata, uint16[] calldata) external` — `:109`
- `function deleteIdentity(address _userAddress) external onlyAgent` — `:139`
- `function updateIdentity(address _userAddress, IIdentity _identity) external onlyAgent` — `:122`
- `function updateCountry(address _userAddress, uint16 _country) external onlyAgent` — `:131`
- `function isVerified(address _userAddress) external view returns (bool)` — `:173` (see [§1.4a](#14a-isverified-semantics))
- `function contains(address _userAddress) external view returns (bool)` — `:256`
- `function identity(address _userAddress) public view returns (IIdentity)` — `:278`
- `function investorCountry(address _userAddress) external view returns (uint16)` — `:228`
- Agent management (inherited from `AgentRoleUpgradeable`): `addAgent(address) onlyOwner`,
  `removeAgent(address) onlyOwner`, `isAgent(address) view`.

#### 1.4a `isVerified` semantics

Loop logic at `:173–223`:
1. If the wallet has **no** registered identity → `false` (`:174`).
2. If `ClaimTopicsRegistry.getClaimTopics()` is **empty** → `true` — *no required topics means
   everyone with an identity is verified* (`:176`).
3. For each required topic: fetch the trusted issuers for that topic; if none → `false` (`:190`).
   Build `claimId = keccak256(abi.encode(trustedIssuer, topic))` for each issuer, fetch that
   claim from the wallet's Identity via `getClaim(claimId)`, and call
   `IClaimIssuer(issuer).isClaimValid(identity, topic, sig, data)`. **Passing any one trusted
   issuer for the topic is enough**; the wallet is verified only if *every* required topic is
   satisfied. `isClaimValid` reverting is caught and treated as invalid (`try/catch`, `:201–216`).

### 1.5 ModularCompliance — `E/compliance/modular/ModularCompliance.sol`

- Upgradeable (`OwnableUpgradeable` + `MCStorage`). Initialize with `init()`.
- `function init() external initializer` — `:84`
- `function bindToken(address _token) external` — `:91` (owner, **or** the token itself when no
  token is yet bound — this is why `Token.setCompliance` can self-bind, see [§3](#3-itoken))
- `function unbindToken(address _token) external` — `:102`
- `function addModule(address _module) external onlyOwner` — `:113` (≤25 modules; if a module is
  not "plug and play" it must pass `module.canComplianceBind(this)`; calls `module.bindCompliance(this)`)
- `function removeModule(address _module) external onlyOwner` — `:131`
- `function callModuleFunction(bytes calldata callData, address _module) external onlyOwner` — `:189`
  (low-level `call` into a bound module; the owner-only escape hatch for module config)
- `function canTransfer(address _from, address _to, uint256 _value) external view returns (bool)` — `:245`
  (returns `false` if **any** bound module's `moduleCheck` returns `false`; `true` if no modules)
- `function transferred(address _from, address _to, uint256 _value) external onlyToken` — `:150`
- `function created(address _to, uint256 _value) external onlyToken` — `:165`
- `function destroyed(address _from, uint256 _value) external onlyToken` — `:177`
- `function getModules() external view returns (address[] memory)` — `:231`
- `function getTokenBound() external view returns (address)` — `:238`
- `function isModuleBound(address _module) external view returns (bool)` — `:224`

> `transferred`/`created`/`destroyed` are `onlyToken` and revert on zero-address or zero-value
> (`:151–155`, `:166–167`, `:178–179`). Each fans out to the matching hook on every bound module.

### 1.6 Token — `E/token/Token.sol` (+ `IToken.sol`, `TokenStorage.sol`)

- Upgradeable (`IToken` + `AgentRoleUpgradeable` + `TokenStorage`). Initialize with `init(...)`.
- `function init(address _identityRegistry, address _compliance, string memory _name, string memory _symbol, uint8 _decimals, address _onchainID) external initializer` — `:100`
  - Requires non-zero IR & compliance, non-empty name & symbol, `0 <= decimals <= 18`.
  - **Sets `_tokenPaused = true`** (`:128`) — a freshly initialized token is **paused**; an agent
    must `unpause()` before any `transfer` works. (mint/burn/forcedTransfer work while paused — see [§3a](#3a-which-operations-are-gated-by-pause).)
  - Calls `setIdentityRegistry(_identityRegistry)` and `setCompliance(_compliance)`; the latter
    calls `compliance.bindToken(address(this))` automatically (`:520`).
- All state-mutating agent ops require `onlyAgent`; all config setters require `onlyOwner`. Full
  function list in [§3](#3-itoken).

**Wiring consequence:** deploying and initializing the Token auto-binds the compliance
(`setCompliance` → `bindToken`). You still must `compliance.addModule(maxInvestorsModule)`
separately, and add the agent wallet to **both** Token and IdentityRegistry.

### 1.7 Identity (ONCHAINID) — `O/Identity.sol`

- **Not** OZ-upgradeable; it is the logic contract behind ONCHAINID's own `IdentityProxy`.
- `constructor(address initialManagementKey, bool _isLibrary)` — `:49`
  - `_isLibrary = true` → deploy as the shared **implementation/library** (sets `_initialized`,
    does not seed a management key).
  - `_isLibrary = false` → standalone identity; seeds `initialManagementKey` as a **purpose-1
    (MANAGEMENT)** key.
- `function initialize(address initialManagementKey) external` — `:64` (used by the proxy via
  delegatecall; seeds the management key).
- Deploy paths for investor identities:
  1. **Direct:** `new Identity(investorWallet, false)` — simplest for tests.
  2. **Proxy via factory:** `IdFactory.createIdentity(wallet, salt)` → deploys an `IdentityProxy`
     that delegatecalls `initialize(wallet)` on the implementation (see §1.9, §1.10).
- Key/claim functions are documented in [§5](#5-identity-claim--key-storage).

### 1.8 ClaimIssuer (ONCHAINID) — `O/ClaimIssuer.sol`

- `contract ClaimIssuer is IClaimIssuer, Identity` — it **is** an Identity plus revocation.
- `constructor(address initialManagementKey) Identity(initialManagementKey, false)` — `:11`
  → the `initialManagementKey` becomes a **purpose-1 MANAGEMENT** key on the issuer.
- `function isClaimValid(IIdentity _identity, uint256 claimTopic, bytes memory sig, bytes memory data) external view returns (bool)` — `:46`
- `function revokeClaimBySignature(bytes calldata signature) external onlyManager` — `:16`
- `function revokeClaim(bytes32 _claimId, address _identity) external onlyManager returns (bool)` — `:27`
- `function isClaimRevoked(bytes memory _sig) public view returns (bool)` — `:75`
- `function getRecoveredAddress(bytes memory sig, bytes32 dataHash) public pure returns (address)` — `:86`
- Claim-signer registration: the signing key must be a **purpose-3 (CLAIM)** key on the
  ClaimIssuer — **unless** you sign with the management key itself, which already satisfies every
  purpose (see [§5a](#5a-keyhaspurpose-management-key-is-a-superkey) and [§7](#7-deviations-from-the-skill--claudemd-docs)).
  Register a distinct signer with `addKey(keccak256(abi.encode(signerAddr)), 3, 1)`.

### 1.9 ImplementationAuthority (ONCHAINID) — `O/proxy/ImplementationAuthority.sol`

- `constructor(address implementation)` — `:13` (the deployed `Identity` **library** address)
- `function updateImplementation(address _newImplementation) external onlyOwner` — `:22`
- `function getImplementation() external view returns (address)` — `:31`
- Emits `UpdatedImplementation(address newAddress)`.

### 1.10 IdFactory (ONCHAINID) — `O/factory/IdFactory.sol`

- `constructor(address implementationAuthority)` — `:34` (the `ImplementationAuthority` above; `Ownable`, deployer = owner)
- `function createIdentity(address _wallet, string memory _salt) external onlyOwner returns (address)` — `:62`
  (deploys an `IdentityProxy` for `_wallet`; salt is namespaced `"OID"+_salt`; one identity per wallet)
- `function createIdentityWithManagementKeys(address _wallet, string memory _salt, bytes32[] memory _managementKeys) external onlyOwner returns (address)` — `:82`
- `function createTokenIdentity(address _token, address _tokenOwner, string memory _salt) external returns (address)` — `:123`
  (callable by a registered token factory or the owner)
- `function linkWallet(address _newWallet) external` — `:146` / `function unlinkWallet(address _oldWallet) external` — `:161`
- `function getIdentity(address _wallet) external view returns (address)` — `:181`
- `function isSaltTaken(string calldata _salt) external view returns (bool)` — `:193`
- `function getWallets(address _identity) external view returns (address[] memory)` — `:200`

### 1.11 IdentityProxy (ONCHAINID) — `O/proxy/IdentityProxy.sol`

- `constructor(address _implementationAuthority, address initialManagementKey)` — `:16`
  (delegatecalls `initialize(address)` on the current implementation; stores the authority at a
  fixed slot `0xc5f1…bcf7`). This is what `IdFactory` deploys.

---

## 2. `IModule` — what a custom compliance module must implement

Interface: `E/compliance/modular/modules/IModule.sol`. Base to inherit:
`E/compliance/modular/modules/AbstractModule.sol` (provides `bindCompliance`/`unbindCompliance`/
`isComplianceBound` and the `onlyComplianceCall` / `onlyBoundCompliance` modifiers).

**Events** (`IModule.sol:73,80`):
- `event ComplianceBound(address indexed _compliance);`
- `event ComplianceUnbound(address indexed _compliance);`

**Functions the module MUST provide** (those not already in `AbstractModule` must be implemented
by our `MaxInvestorsModule`):

| Function | Sig | Caller / semantics |
| --- | --- | --- |
| `bindCompliance` | `function bindCompliance(address _compliance) external` (`:93`) | provided by `AbstractModule:91`; only the compliance contract may call |
| `unbindCompliance` | `function unbindCompliance(address _compliance) external` (`:103`) | provided by `AbstractModule:102` |
| `moduleTransferAction` | `function moduleTransferAction(address _from, address _to, uint256 _value) external` (`:115`) | called by compliance from `transferred()`; **state update**, must be `onlyComplianceCall` |
| `moduleMintAction` | `function moduleMintAction(address _to, uint256 _value) external` (`:126`) | called from `created()` on mint |
| `moduleBurnAction` | `function moduleBurnAction(address _from, uint256 _value) external` (`:137`) | called from `destroyed()` on burn |
| `moduleCheck` | `function moduleCheck(address _from, address _to, uint256 _value, address _compliance) external view returns (bool)` (`:149`) | called from `canTransfer()`; **view pre-flight**, return `true` to allow |
| `isComplianceBound` | `function isComplianceBound(address _compliance) external view returns (bool)` (`:155`) | provided by `AbstractModule:112` |
| `canComplianceBind` | `function canComplianceBind(address _compliance) external view returns (bool)` (`:161`) | our module must implement; consulted by `addModule` only when `isPlugAndPlay()==false` |
| `isPlugAndPlay` | `function isPlugAndPlay() external pure returns (bool)` (`:166`) | our module must implement; `true` skips the `canComplianceBind` gate on add |
| `name` | `function name() external pure returns (string memory _name)` (`:172`) | our module must implement |

**Hook argument reality (critical for `MaxInvestorsModule`):**
- On **mint**, the compliance calls `moduleCheck(address(0), _to, value, compliance)` (from
  `Token.mint` → `canTransfer(address(0), _to, amount)`, `Token.sol:456`) and then
  `moduleMintAction(_to, value)`. So `_from == address(0)` signals a mint in `moduleCheck`.
- On **burn**: only `moduleBurnAction(_from, value)` runs (no `moduleCheck` — burn has no
  compliance pre-flight in `Token.burn`, `:464`).
- On **transfer / transferFrom**: `moduleCheck(from, to, value, compliance)` then
  `moduleTransferAction(from, to, value)`.
- On **forcedTransfer**: **`moduleCheck` is NOT called** — only `moduleTransferAction` runs (see
  the [§7 deviation](#7-deviations-from-the-skill--claudemd-docs)). A forced transfer can therefore
  drive a module's *action* (e.g. increment holder count) past a limit its *check* would have
  blocked. Our invariant tests must model this.

`AbstractModule` makes **no external calls** in its hooks; if `MaxInvestorsModule` keeps to pure
storage math it needs no reentrancy guard, but we must document that finding explicitly per the
contracts skill.

---

## 3. `IToken` — agent-op & lifecycle signatures

Source: `E/token/IToken.sol` (interface), `E/token/Token.sol` (impl). `IToken is IERC20`.

| Op | Signature | Impl | Access | Notes |
| --- | --- | --- | --- | --- |
| mint | `function mint(address _to, uint256 _amount) external` | `Token.sol:454` | `onlyAgent` | requires `isVerified(_to)` **and** `canTransfer(0, _to, amt)`; then `_mint` + `compliance.created` |
| burn | `function burn(address _userAddress, uint256 _amount) external` | `Token.sol:464` | `onlyAgent` | auto-unfreezes if `amt > free`; `_burn` + `compliance.destroyed` |
| forcedTransfer | `function forcedTransfer(address _from, address _to, uint256 _amount) external returns (bool)` | `Token.sol:431` | `onlyAgent` | auto-unfreezes if needed; checks **only** `isVerified(_to)` (no `canTransfer`); then `_transfer` + `compliance.transferred` |
| freezePartialTokens | `function freezePartialTokens(address _userAddress, uint256 _amount) external` | `Token.sol:488` | `onlyAgent` | requires `balance >= frozen + amt` |
| unfreezePartialTokens | `function unfreezePartialTokens(address _userAddress, uint256 _amount) external` | `Token.sol:498` | `onlyAgent` | requires `frozen >= amt` |
| setAddressFrozen | `function setAddressFrozen(address _userAddress, bool _freeze) external` | `Token.sol:479` | `onlyAgent` | whole-wallet freeze flag |
| pause | `function pause() external` | `Token.sol:188` | `onlyAgent` + `whenNotPaused` | |
| unpause | `function unpause() external` | `Token.sol:196` | `onlyAgent` + `whenPaused` | |
| recoveryAddress | `function recoveryAddress(address _lostWallet, address _newWallet, address _investorOnchainID) external returns (bool)` | `Token.sol:297` | `onlyAgent` | see [§3b](#3b-recoveryaddress-detail) |

**Config setters (all `onlyOwner`):** `setName` (`:161`), `setSymbol` (`:170`),
`setOnchainID` (`:180`), `setIdentityRegistry` (`:507`), `setCompliance` (`:515`).

**Batch variants** (loop the singular op, inherit its access control): `batchTransfer`,
`batchForcedTransfer`, `batchMint`, `batchBurn`, `batchSetAddressFrozen`,
`batchFreezePartialTokens`, `batchUnfreezePartialTokens` (`IToken.sol:313–389`).

**Views:** `decimals()`, `name()`, `symbol()`, `version()`, `onchainID()`,
`identityRegistry()`, `compliance()`, `paused()`, `isFrozen(address)`,
`getFrozenTokens(address)`, plus ERC-20 `totalSupply`/`balanceOf`/`allowance`.

### 3a. Which operations are gated by pause?

Only the *user-facing* ERC-20 moves carry `whenNotPaused`:
- `transfer` (`Token.sol:417`) and `transferFrom` (`:220`) — **blocked while paused**.
- `mint`, `burn`, `forcedTransfer`, `freeze*`, `setAddressFrozen`, `recoveryAddress` — **no
  pause modifier**; agents can operate on a paused token. Confirmed by reading each impl.

### 3b. `recoveryAddress` detail

`Token.sol:297–322`. Requires `balanceOf(_lostWallet) != 0`. Computes
`_key = keccak256(abi.encode(_newWallet))` and **requires the new wallet to be a purpose-1
(MANAGEMENT) key on the investor's ONCHAINID** — `_onchainID.keyHasPurpose(_key, 1)` (`:305`).
If so it: registers the new wallet in the IR with the lost wallet's country, `forcedTransfer`s
the full balance, re-applies frozen amount and address-freeze flag, deletes the lost wallet's
identity, and emits `RecoverySuccess`. Otherwise reverts `"Recovery not possible"`.

> The purpose here is **1 (MANAGEMENT)**, not 3. A wallet cannot be recovered to unless it is a
> management key on the identity. (And because a management key satisfies every `keyHasPurpose`
> query — see §5a — any purpose-1 key trivially passes.)

The transfer gate for ordinary `transfer` (`Token.sol:417–426`):
1. `!_frozen[to] && !_frozen[msg.sender]` else revert `"wallet is frozen"`.
2. `_amount <= balanceOf(sender) - _frozenTokens[sender]` else `"Insufficient Balance"`.
3. `identityRegistry.isVerified(to) && compliance.canTransfer(sender, to, amount)` — both true or
   revert `"Transfer not possible"`.
4. `_transfer` then `compliance.transferred(...)`.

---

## 4. Events for the indexer (name + full parameter list; `I` = indexed)

### 4.1 Token — `E/token/IToken.sol`

| Event | Parameters |
| --- | --- |
| `UpdatedTokenInformation` (`:84`) | `string I _newName, string I _newSymbol, uint8 _newDecimals, string _newVersion, address I _newOnchainID` |
| `IdentityRegistryAdded` (`:92`) | `address I _identityRegistry` |
| `ComplianceAdded` (`:99`) | `address I _compliance` |
| `RecoverySuccess` (`:108`) | `address I _lostWallet, address I _newWallet, address I _investorOnchainID` |
| `AddressFrozen` (`:119`) | `address I _userAddress, bool I _isFrozen, address I _owner` |
| `TokensFrozen` (`:127`) | `address I _userAddress, uint256 _amount` |
| `TokensUnfrozen` (`:135`) | `address I _userAddress, uint256 _amount` |
| `Paused` (`:142`) | `address _userAddress` |
| `Unpaused` (`:149`) | `address _userAddress` |
| `Transfer` / `Approval` | inherited from `IERC20` — `Transfer(address I from, address I to, uint256 value)`; `Approval(address I owner, address I spender, uint256 value)` |

> Note `UpdatedTokenInformation` marks **string** params `indexed` — indexed strings are stored
> as the keccak256 hash of the value in the topic, not the raw string. The indexer cannot recover
> the plaintext name/symbol from the topic; read them via `name()`/`symbol()` view calls instead.
> Mint is `Transfer(from=0x0, to, value)`; burn is `Transfer(from, to=0x0, value)`.

### 4.2 IdentityRegistry — `E/registry/interface/IIdentityRegistry.sol`

| Event | Parameters |
| --- | --- |
| `ClaimTopicsRegistrySet` (`:78`) | `address I claimTopicsRegistry` |
| `IdentityStorageSet` (`:85`) | `address I identityStorage` |
| `TrustedIssuersRegistrySet` (`:92`) | `address I trustedIssuersRegistry` |
| `IdentityRegistered` (`:100`) | `address I investorAddress, IIdentity I identity` |
| `IdentityRemoved` (`:108`) | `address I investorAddress, IIdentity I identity` |
| `IdentityUpdated` (`:116`) | `IIdentity I oldIdentity, IIdentity I newIdentity` |
| `CountryUpdated` (`:124`) | `address I investorAddress, uint16 I country` |

Agent role events (from `AgentRoleUpgradeable.sol:75`): `AgentAdded(address I _agent)`,
`AgentRemoved(address I _agent)` — emitted on the IR and IRS.

### 4.3 ModularCompliance — `E/compliance/modular/IModularCompliance.sol`

| Event | Parameters |
| --- | --- |
| `ModuleInteraction` (`:75`) | `address I target, bytes4 selector` |
| `TokenBound` (`:82`) | `address _token` (not indexed) |
| `TokenUnbound` (`:89`) | `address _token` (not indexed) |
| `ModuleAdded` (`:96`) | `address I _module` |
| `ModuleRemoved` (`:103`) | `address I _module` |

Supporting registries the indexer may also watch:
- **IdentityRegistryStorage** (`IIdentityRegistryStorage.sol`): `IdentityStored`,
  `IdentityUnstored`, `IdentityModified` (`IIdentity I old, IIdentity I new`),
  `CountryModified`, `IdentityRegistryBound`, `IdentityRegistryUnbound`.
- **TrustedIssuersRegistry** (`ITrustedIssuersRegistry.sol`): `TrustedIssuerAdded(IClaimIssuer I trustedIssuer, uint256[] claimTopics)`,
  `TrustedIssuerRemoved(IClaimIssuer I)`, `ClaimTopicsUpdated(IClaimIssuer I, uint256[])`.
- **ClaimTopicsRegistry** (`IClaimTopicsRegistry.sol`): `ClaimTopicAdded(uint256 I)`, `ClaimTopicRemoved(uint256 I)`.
- **ONCHAINID Identity** (ERC-735, per investor): `ClaimAdded`, `ClaimChanged`, `ClaimRemoved`
  (see §5) — relevant if we index KYC state changes directly from identities.

### 4.4 MaxInvestorsModule (our custom module) — `src/modules/MaxInvestorsModule.sol`

| Event | Parameters |
| --- | --- |
| `MaxInvestorsSet` | `address I _compliance, uint256 _maxInvestors` — cap (re)configured; `0` = unlimited |
| `HolderCountChanged` | `address I _compliance, uint256 _newCount` — distinct-holder count after a crossing |

> **Indexer contract for `HolderCountChanged`.** It fires from the mint/burn/transfer action hooks
> **only on an actual zero ↔ non-zero mirror crossing**, carrying the post-crossing count. Routine
> moves that create no crossing (top-ups, partial burns, transfers between two existing holders)
> emit nothing. This is the authoritative on-chain signal for the derived holder-count read model:
> the indexer should key it by `_compliance` and take `_newCount` as the value, rather than
> re-deriving counts from `Transfer` logs (which is slower and — critically — drifts after a reorg
> rollback, because a rolled-back `Transfer` must un-count exactly, whereas `HolderCountChanged` is
> replayed idempotently to the same value). Added for Phase 3; before it existed the module mutated
> the count silently, which is the L-2 finding this closes.

---

## 5. Identity: claim & key storage

Source: `O/Identity.sol`, structs in `O/storage/Structs.sol`, ERC interfaces in
`O/interface/IERC734.sol` (keys) and `IERC735.sol` (claims).

### Claims

- `function addClaim(uint256 _topic, uint256 _scheme, address _issuer, bytes memory _signature, bytes memory _data, string memory _uri) public onlyClaimKey returns (bytes32 claimRequestId)` — `Identity.sol:342`
  - Requires `msg.sender` to hold a **purpose-3 CLAIM** key on *this* identity (`onlyClaimKey`, `:37`) — i.e. the investor (or their claim key) adds the claim to their own identity.
  - If `_issuer != address(this)` it first calls `IClaimIssuer(_issuer).isClaimValid(this, topic, sig, data)` and reverts on invalid (`:356`).
  - **`claimId = keccak256(abi.encode(_issuer, _topic))`** (`:360`). One claim per (issuer, topic):
    re-adding the same claimId emits `ClaimChanged` instead of `ClaimAdded` (`:367–375`).
- `function getClaim(bytes32 _claimId) public view returns (uint256 topic, uint256 scheme, address issuer, bytes memory signature, bytes memory data, string memory uri)` — `Identity.sol:450`
- `function getClaimIdsByTopic(uint256 _topic) external view returns (bytes32[] memory)` — `Identity.sol:158`
- `function removeClaim(bytes32 _claimId) public onlyClaimKey returns (bool)` — `Identity.sol:390`

`Claim` struct (`Structs.sol:63`): `{ uint256 topic; uint256 scheme; address issuer; bytes signature; bytes data; string uri; }`.

ERC-735 events (`IERC735.sol:14,28,42`) — all three carry
`(bytes32 I claimId, uint256 I topic, uint256 scheme, address I issuer, bytes signature, bytes data, string uri)`:
`ClaimAdded`, `ClaimRemoved`, `ClaimChanged`.

### Keys

- `Key` struct (`Structs.sol:16`): `{ uint256[] purposes; uint256 keyType; bytes32 key; }`.
  The stored `key` is `keccak256(abi.encode(address))` — an address hash, not the raw address.
- `function addKey(bytes32 _key, uint256 _purpose, uint256 _type) public onlyManager returns (bool)` — `Identity.sol:181`
  (reverts `"Conflict: Key already has purpose"` if the key already holds that purpose)
- `function removeKey(bytes32 _key, uint256 _purpose) public onlyManager returns (bool)` — `Identity.sol:275`
- `function keyHasPurpose(bytes32 _key, uint256 _purpose) public view returns (bool)` — `Identity.sol:477`
- `function getKey(bytes32 _key) external view returns (uint256[] memory purposes, uint256 keyType, bytes32 key)` — `Identity.sol:112`
- `function getKeysByPurpose(uint256 _purpose) external view returns (bytes32[] memory)` — `Identity.sol:142`

**Key-purpose constants** (documented at `Identity.sol:169–173`, `:139`):
`1 = MANAGEMENT`, `2 = ACTION` (a.k.a. EXECUTION), `3 = CLAIM signer`, `4 = ENCRYPTION`.
`keyType` `1 = ECDSA`, `2 = RSA`. **The claim signer key is purpose 3.**

### 5a. `keyHasPurpose`: the management key is a super-key

`Identity.sol:477–493`:
```solidity
for (...) { uint256 purpose = key.purposes[i]; if (purpose == 1 || purpose == _purpose) return true; }
```
**A purpose-1 (MANAGEMENT) key returns `true` for *every* `keyHasPurpose(key, X)` query.** Direct
consequences:
- A `ClaimIssuer` whose only key is its `initialManagementKey` will validate claims signed by
  that same key **without** any explicit purpose-3 registration, because
  `ClaimIssuer.isClaimValid` checks `keyHasPurpose(hashedAddr, 3)` (`ClaimIssuer.sol:65`) and a
  management key passes it.
- Registering a **distinct** signing EOA as a purpose-3 key is only required when the signer
  differs from the issuer's management key. Our deploy should pick one convention and state it.

**Asymmetry rule (deliberate — read this before "fixing" the inconsistency).** Our two scripts
make opposite choices about the super-key, and that is intentional:
- **Issuer signer — we do NOT rely on the super-key.** `Deploy.s.sol` registers a *distinct*
  purpose-3 signer (`CLAIM_ISSUER_SIGNER_ADDRESS`) and signs claims with it, rather than signing
  with the issuer's management key. Rationale: a leaked signer must be able to sign claims **and
  nothing else** — it holds no management purpose, so it cannot re-key or administer the
  `ClaimIssuer`. Relying on the super-key here would hand full issuer administration to the
  claim-signing key.
- **Investor — we DO rely on the super-key.** `Seed.s.sol` has each investor broadcast `addClaim`
  on its own identity; it passes `onlyClaimKey` purely because the investor wallet is that
  identity's purpose-1 MANAGEMENT key (§5a). That is legitimate: the investor **is** their own
  identity's manager, so there is no extra privilege to leak — the wallet already controls the
  identity outright.

Rule of thumb: rely on the purpose-1 super-key only where the holder is already the legitimate
administrator of the contract in question. The issuer signer is not; the investor is.

### The exact claim signing scheme (from `ClaimIssuer.isClaimValid`)

`ClaimIssuer.sol:46–70` — this is **ERC-735 scheme 1 (`eth_sign` prefixed hash)**, not EIP-712:
```
dataHash      = keccak256(abi.encode(_identity, claimTopic, data))          // ClaimIssuer.sol:53
prefixedHash  = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash))  // :55
recovered     = ecrecover(prefixedHash, v, r, s)                            // via getRecoveredAddress :58
valid         = keyHasPurpose(keccak256(abi.encode(recovered)), 3) && !isClaimRevoked(sig)  // :65
```
- `_identity` is the **investor's Identity contract address** (the claim holder), not the issuer.
- `claimId = keccak256(abi.encode(issuerAddress, topic))` (`Identity.addClaim:360`) — note the
  claimId uses the **issuer address**, while the signed `dataHash` uses the **identity address**.
  Do not conflate them.
- Signature must be 65 bytes; `v < 27` is normalized to `+27` (`ClaimIssuer.sol:108`).

### 5b. Canonical claim `data` payload — PIN THIS (Phase 2 must reuse verbatim)

The `data` bytes sit **inside** the signed digest (`keccak256(abi.encode(identity, topic, data))`),
so the exact bytes are consensus-critical. If Phase 2's `ClaimIssuerModule` encodes the payload even
one byte differently from what was signed, `ecrecover` yields a *different* signer and `isClaimValid`
returns false — and the failure presents as a **signing bug**, not the encoding mismatch it actually
is. Freeze the format here so the seed script and the module emit byte-identical payloads.

**Canonical format:** `data` is the raw **UTF-8 bytes of a fixed per-topic label string** —
`bytes(label)` in Solidity, `toUtf8Bytes(label)` / `new TextEncoder().encode(label)` in TS. **No** ABI
wrapping, **no** length prefix, **no** trailing NUL, and **no** per-investor variation: the investor's
identity address already lives in the digest, so identical `data` still yields a unique signature per
holder. The same bytes are signed *and* stored via `addClaim`, because `isClaimValid` re-hashes the
stored `data`.

| Topic | Constant | Exact label string (UTF-8, verbatim) |
| --- | --- | --- |
| 1 (KYC) | `KYC_DATA` | `KYC verified by Tessera claim issuer` |
| 2 (AML) | `AML_DATA` | `AML/sanctions cleared by Tessera claim issuer` |

Source of truth: `contracts/script/Seed.s.sol` (`KYC_DATA` / `AML_DATA`). Phase 2 MUST reproduce these
strings character-for-character — do **not** re-word them; changing a single character silently
invalidates every claim signed against the old text. (The strings carry no PII, per golden rule 2 —
they are topic labels only; the backing personal data stays with the KYC/AML provider.)

---

## 6. Deployment wiring order (reconciled with the source)

Confirmed against the impls; this matches `contracts/CLAUDE.md` with source citations:

1. Deploy + `init()` the three leaf registries: `ClaimTopicsRegistry.init()`,
   `TrustedIssuersRegistry.init()`, `IdentityRegistryStorage.init()`.
2. Deploy `IdentityRegistry`; `init(trustedIssuersRegistry, claimTopicsRegistry, storage)` —
   **note arg order** (`IdentityRegistry.sol:87`).
3. **`identityRegistryStorage.bindIdentityRegistry(identityRegistry)`** — must be sent by the IRS
   **owner** (it calls the `onlyOwner` `addAgent`). Skipping this makes `registerIdentity` revert.
4. Deploy `ModularCompliance`; `init()`. Deploy `Token`;
   `init(identityRegistry, compliance, name, symbol, decimals, tokenOnchainID)` — this
   auto-calls `compliance.bindToken(token)` (`Token.setCompliance:520`). Then
   `compliance.addModule(maxInvestorsModule)`.
5. `token.addAgent(agentWallet)` **and** `identityRegistry.addAgent(agentWallet)` (both owner-only).
6. ONCHAINID: deploy `Identity(deployer, true)` as the library →
   `ImplementationAuthority(identityLibrary)` → `IdFactory(implementationAuthority)`.
   Deploy `ClaimIssuer(claimIssuerManagementKey)`.
7. Register the claim-issuer **signing** key as a purpose-3 CLAIM key on the ClaimIssuer:
   `claimIssuer.addKey(keccak256(abi.encode(signerAddr)), 3, 1)` — **skip if you sign with the
   issuer's management key** (§5a).
8. `trustedIssuersRegistry.addTrustedIssuer(claimIssuer, [1, 2])`.
9. `claimTopicsRegistry.addClaimTopic(1)`; `addClaimTopic(2)`. (Topics: `1` KYC, `2` AML.)
10. Per investor: deploy Identity (`new Identity(wallet, false)` or `idFactory.createIdentity`) →
    `identityRegistry.registerIdentity(wallet, identity, country)` (agent) → sign the claim
    off-chain per §5 → `identity.addClaim(topic, 1, claimIssuer, sig, data, uri)` (must be sent by
    a purpose-3 claim key on that identity — typically the investor wallet, which is its own
    purpose-1 management key and therefore passes `onlyClaimKey`).

---

## 7. Deviations from the SKILL / CLAUDE.md docs

Listed most-material first. **Where these differ, the vendored source is authoritative.**

1. **`forcedTransfer` does NOT run the compliance module check (gate 3).** Both
   `.claude/skills/trex-contracts/SKILL.md` ("Gates 2 and 3 still run") and
   `contracts/CLAUDE.md` ("forcedTransfer bypasses **sender consent only**. Gates 2 and 3 still
   run") are **incorrect** on gate 3. `Token.forcedTransfer` (`Token.sol:431–449`) checks only
   `isVerified(_to)` (gate 2) and then calls `compliance.transferred(...)` (the state update) —
   it never calls `compliance.canTransfer(...)` (gate 3). So a forced transfer:
   - **cannot** send to an unverified receiver (gate 2 holds — the docs are right there), but
   - **can** violate a module rule such as the `MaxInvestorsModule` holder cap, because
     `moduleCheck` is skipped while `moduleTransferAction` still increments the count.
   **Test/impl impact:** the planned unit test "`forcedTransfer` to an unverified receiver still
   reverts" is valid. But any test asserting a *rule-violating* forced transfer reverts would be
   wrong. Our invariant "distinct holders ≤ maxInvestors" must treat forcedTransfer as a path
   that can breach the cap; if we need forced transfers to respect the cap we must enforce it
   ourselves (e.g. in `moduleTransferAction`, which cannot revert without bricking the transfer —
   so this is a design decision to record, not a bug to "fix" in vendored code). By contrast,
   `mint` **does** enforce gate 3 (`Token.mint:456` calls `canTransfer(0, _to, amt)`).

2. **A MANAGEMENT (purpose-1) key satisfies every `keyHasPurpose` check** (`Identity.sol:489`).
   The skill's step "register the claim-issuer signing key as a claim key (purpose 3)" is only
   strictly necessary when the signer differs from the issuer's management key. Documented in §5a
   so our deploy script states its convention explicitly rather than relying on the implicit pass.

3. **`recoveryAddress` requires a purpose-1 (MANAGEMENT) key, not purpose 3.** `Token.sol:305`
   checks `keyHasPurpose(keccak256(abi.encode(_newWallet)), 1)`. The docs don't specify a purpose;
   recording it here so the recovery test seeds the new wallet as a management key on the
   investor's ONCHAINID.

4. **A freshly initialized Token is paused** (`_tokenPaused = true`, `Token.sol:128`). Neither doc
   mentions this. Deploy/seed must `unpause()` (as an agent) before demonstrating a `transfer`,
   and `mint` during seeding works precisely because mint ignores pause (§3a).

5. **`bindIdentityRegistry` is not an `onlyOwner`-annotated function** — its access control is
   *implicit* via the internal `onlyOwner addAgent` call (§1.3). Same end result (owner-only) but
   worth knowing when reading the signature: there is no visible modifier on the function itself.

6. **`Token.version()` returns `"4.1.3"`** (`TokenStorage.sol:79`), while `IToken.sol` NatSpec
   still claims "3.0.0". The constant is authoritative; the comment is stale upstream.

7. **Argument order of `IdentityRegistry.init` is `(trustedIssuers, claimTopics, storage)`**
   (`IdentityRegistry.sol:87`) — trusted-issuers first. Easy to transpose against the "topics,
   issuers, storage" mental ordering in the deploy doc. No behavioural doc conflict, just a
   footgun flagged here.

**No other substantive deviations found.** The claim-signing scheme, deployment order, transfer
gate for ordinary transfers, and the IModule hook surface all match the docs as written.

---

## 8. Reentrancy audit of our custom code (2026-08-24; revised for M-1 bind gate)

**Finding: NEGATIVE — no HOOK in our custom code makes any external or low-level call, so there
is no reentrancy surface on the transfer/mint/burn path and no reentrancy test is warranted.**
This is the exact obligation `contracts/CLAUDE.md` sets ("If a module hook makes an external call,
it needs a reentrancy test") — the antecedent is false for every hook, evidenced below.

⚠️ **Update (M-1 fix).** The module now makes **one** external call in the whole codebase:
`canComplianceBind` reads `IToken(compliance.getTokenBound()).totalSupply()`. This does **not**
invalidate the negative above, for a precise reason: `canComplianceBind` is a `view` reached only
from `ModularCompliance.addModule` at **bind time**, never from an action hook and never on a live
transfer/mint/burn path. Reentrancy requires an external call that hands control away *before the
caller's state settles mid-operation*; a bind-time view that mutates no state and runs once, before
the module tracks anything, has no state to corrupt and no operation to re-enter. The four IModule
hooks — `moduleCheck`, `moduleTransferAction`, `moduleMintAction`, `moduleBurnAction` — remain free
of external calls (table below), so the "hooks make no external call ⇒ no guard needed" conclusion
is unchanged. Read this section as: *the hook path is still clean; the one external call is off it.*

### 8.1 What "external call" means here

An external call is any `call`/`delegatecall`/`staticcall` to another address that could hand
control to attacker code before our state settles — a `.call{...}`, a `token.foo()` on an
interface, `transfer`/`send`, or an untrusted callback. Reads of our OWN storage mappings, emits,
`revert`s, and calls to `internal`/`private` functions in the same contract are *not* external
calls and cannot re-enter.

### 8.2 Every function in `src/modules/MaxInvestorsModule.sol`, checked

The only custom contract. Line numbers are current as of this audit.

| Function | Kind | External call? | What it actually does |
| --- | --- | --- | --- |
| `setMaxInvestors` (`:92`) | state | **No** | writes `_maxInvestors[msg.sender]`, emits `MaxInvestorsSet` |
| `moduleTransferAction` (`:113`) | hook, state | **No** | two `internal` calls: `_decreaseBalance` then `_increaseBalance` |
| `moduleMintAction` (`:128`) | hook, state | **No** | one `internal` call: `_increaseBalance` |
| `moduleBurnAction` (`:137`) | hook, state | **No** | one `internal` call: `_decreaseBalance` |
| `moduleCheck` (`:157`) | hook, view | **No** | reads `_maxInvestors` / `_balances` / `_investorCount` mappings only |
| `investorCount` (`:184`) | view | **No** | reads a mapping |
| `maxInvestors` (`:189`) | view | **No** | reads a mapping |
| `mirroredBalance` (`:196`) | view | **No** | reads a mapping |
| `canComplianceBind` | bind-time **view** | **YES (1)** | reads `IToken(compliance.getTokenBound()).totalSupply()` — the ONLY external call in our code; off the hook path (see the M-1 update above) |
| `isPlugAndPlay` | pure | **No** | returns `false` |
| `name` | pure | **No** | returns a string literal |
| `_increaseBalance` | private | **No** | mapping math + count crossing; emits `HolderCountChanged` on a crossing |
| `_decreaseBalance` | private | **No** | saturating mapping math + count crossing; emits `HolderCountChanged` on a crossing |

All four IModule hooks — `moduleCheck`, `moduleTransferAction`, `moduleMintAction`,
`moduleBurnAction` — are on this list and make no external call. The sole external call in the
module, `canComplianceBind`, is a bind-time view and is NOT a hook. The design is deliberate: the
module keeps its OWN balance mirror instead of calling back into `token.balanceOf` (see the
contract-level NatSpec, `:22`–`:26`), which is precisely what removes the external-call surface.

`script/Deploy.s.sol` and `script/Seed.s.sol` do make external calls (they deploy and wire the
suite), but scripts run in a forge cheatcode VM, are never on a live transaction's call path, and
hold no state an attacker can re-enter. Out of scope for reentrancy.

### 8.3 Inherited surface (`AbstractModule`, vendored)

`bindCompliance` / `unbindCompliance` / `isComplianceBound` come from the audited
`AbstractModule` and make **no external calls** in their hooks — confirmed in [§2](#2-imodule)
and by upstream audit. We neither override nor extend them. Vendored, out of our audit scope, but
noted so the negative is complete.

### 8.4 Call ordering — is the module the reentrancy surface? (answers the §2/§3 question)

Yes in principle, no in fact. Per the ordinary-transfer gate ([§3b](#3b-recoveryaddress-detail),
step 4) and the mint/transfer/burn flows ([§2](#2-imodule), "Hook argument reality"), the Token
moves balances **first** and calls `compliance.transferred(...)` / `created` / `destroyed`
**after** — which fires `moduleTransferAction` / `moduleMintAction` / `moduleBurnAction`
**post-balance-move**. So the action hooks run when the token's balances are already final and the
module's own mirror is the last state to update. That ordering means a *stateful* module — this
one — would be the reentrancy surface, not the token, IF a hook made an external call before the
mirror settled: an attacker could re-enter with the token consistent but the module mid-update.

It doesn't, so the hazard is latent, not live: `moduleTransferAction` performs only internal
mapping writes and yields control to no one. There is no interaction step to precede the effects,
so CEI is trivially satisfied (there are no external interactions at all). The token's own
`_transfer`-then-`transferred` ordering is vendored/audited and unchanged by us.

**Guardrail for future edits:** the moment any hook in this module gains an external call — e.g. a
callback, an oracle read, an ERC-20 transfer — this post-balance-move position turns the latent
hazard live, and `test/unit/Reentrancy.t.sol` with a malicious re-entering compliance stub plus a
`nonReentrant` guard (or provably-last effects) becomes mandatory. Until then, none exists by
design.

---

## 9. Fail-open default on `MaxInvestorsModule` (`maxInvestors == 0` = UNLIMITED)

**Decision: keep `0 = unlimited` as a deliberate, documented sentinel. Do NOT invert to
fail-closed.** The reasoning is captured in the `_maxInvestors` NatSpec (`MaxInvestorsModule.sol`)
and summarised here.

**The concern (valid).** On a compliance contract, a fail-open default is normally the wrong
instinct: a module bound without a cap set enforces nothing, and a silent no-op on a control is a
classic footgun. An operator who binds the module and forgets `setMaxInvestors` gets no cap and no
error.

**Why fail-open is nonetheless correct here.**

1. **Vendored-convention parity.** `0 = unset = no limit` is the canonical T-REX modular-compliance
   idiom; CLAUDE.md forbids surprising deviations from the audited patterns.
2. **Inverting breaks the required deploy order (CLAUDE.md rule 4).** The wiring order is
   `addModule` → `setMaxInvestors` → first `mint`. A fail-closed default (unset ⇒ block) would
   make the first mint's `moduleCheck` return `false` and revert, breaking
   `pnpm contracts:deploy:local` on a fresh clone. Add-before-configure structurally requires an
   add-time default that PERMITS. (Note: the M-1 fix makes `isPlugAndPlay() == false` so the *bind*
   gate runs, but that gate only checks holder count at add time — it does not set the cap. The
   `moduleCheck` cap default is a separate concern and remains fail-open for exactly this reason.)
3. **The fail-open window is bounded to zero-holder state.** By the binding invariant (the module
   is added before the token has holders), the only interval where the cap is 0 is between
   `addModule` and `setMaxInvestors` — when the holder count is 0 regardless. "Enforces nothing"
   never applies to a token that already carries investors on the deploy path. **Since the M-1 fix
   this binding invariant is enforced on-chain** (`canComplianceBind` rejects binding to a token
   with holders; §8 / `isPlugAndPlay() == false`), so the "added before the token has holders"
   premise this point rests on is no longer merely a deploy convention — the module cannot bind any
   other way.

**Where the residual risk is handled.** Not by changing the sentinel — by a **wire-time
assertion**. `script/Deploy.s.sol` asserts the cap reads back as the configured value after wiring
(`maxInvestorsModule.maxInvestors(compliance) == expectedMaxInvestors`), which is the correct place
to catch a forgotten cap. Any future production wiring of this module on a new compliance should
carry the same post-wire assertion.

**Alternative considered and rejected:** a two-field design (`_configured` bool + `_cap`) with an
unset default of "reject holder-creating moves". Rejected because it (a) still needs an add-time
permit to satisfy plug-and-play, pushing the fail-open to the `_configured == false` path anyway,
and (b) adds a storage slot and branch for a risk already closed at wire time.

### 9.1 Residual the bind gate does NOT close: `unbindToken` → `bindToken(tokenWithHolders)`

**Do not overstate the M-1 guarantee.** `canComplianceBind` (§8, `isPlugAndPlay() == false`) makes
the module refuse to bind to a compliance unless a token is bound **and** that token has
`totalSupply() == 0`. Requiring a *bound* token — rather than waving through the token-less case —
forces `addModule` to run **after** `bindToken`, which closes the accidental ordering
`addModule` → `bindToken(tokenWithHolders)` (that path never re-runs `canComplianceBind`, since
`bindToken` does not consult already-added modules, and is reachable via
`Token.setCompliance(preloadedCompliance)`).

**What remains open.** The gate fires **only at `addModule` time**. `ModularCompliance.bindToken`
never consults its modules. So an owner can still defeat the mirror with a deliberate rebind after
the module is already added:

```
1. addModule(maxInvestorsModule)      // gate passes: token T0 bound, totalSupply(T0) == 0
2. setMaxInvestors(cap)
3. ... T0 mints to N holders ...       // mirror tracks all N correctly
4. unbindToken(T0)                     // no module callback
5. bindToken(T1)                       // T1 already has M holders; no module callback, no re-check
   → the module's mirror for this compliance still reflects T0, not T1: the count is desynced,
     and the cap under-enforces against T1's true holder set.
```

**Why it is not closeable from inside the module.** The module has no hook on `bindToken`/
`unbindToken` (those are `ModularCompliance` functions that touch only the compliance's own token
pointer), and it must not scan holders (CLAUDE.md: no unbounded loops), so it cannot re-derive a
new token's holder set at rebind time even if it were notified. The vendored `ModularCompliance` is
audited infrastructure we do not fork (golden rule 1), so we cannot add a module callback to
`bindToken`.

**Classification: owner operational responsibility, not a module defect.** A `ModularCompliance`
is a 1:1 companion to its token; rebinding a *different, already-populated* token onto a compliance
that carries a stateful holder-cap module is a misconfiguration, not a normal operation. The honest
mitigation is a constraint, not a clever workaround: **this module is a genesis-time control** —
correct only when the compliance, the module, and the token are wired together while the token has
zero supply and are never repointed afterward. There is deliberately no supported way to attach an
accurate cap to an already-populated token, because that would require the holder scan M-1 forbids;
`addModule` against a populated token reverts by design (§8), so the *accidental* form is blocked and
only the *deliberate* `unbind`/`rebind` sequence above remains. If a populated token genuinely must
come under a holder cap, that is a migration (snapshot holders off-chain, deploy a fresh
compliance+module against a fresh token, re-issue) — not a rebind. Surfaced in the README security
notes so it is visible to operators, not buried here.
