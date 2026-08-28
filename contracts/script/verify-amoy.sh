#!/usr/bin/env bash
#
# verify-amoy.sh — re-verify every Amoy-deployed Tessera contract on PolygonScan in one pass.
#
# `forge script --verify` already verifies during a fresh broadcast; this helper is the
# idempotent re-run for the common case where verification was skipped, rate-limited, or raced
# the explorer's indexer (a just-deployed contract PolygonScan hasn't seen yet). It reads the
# deployed addresses from packages/shared/addresses.amoy.json, reconstructs the constructor
# arguments for the four contracts that take them (from the same address book + env the deploy
# used, so they are byte-identical to what was broadcast), and calls `forge verify-contract`
# for each of the 11 contracts. It continues past a failure and reports a per-contract tally,
# exiting non-zero if any contract failed — so CI can gate on it.
#
# Compiler settings (solc 0.8.17, optimizer 200 runs, evm paris) come from contracts/foundry.toml
# automatically; the verifier must see the SAME settings the deploy used or the bytecode won't
# match — run `forge clean && forge build` first if you suspect stale artifacts.
#
# Usage:
#   pnpm contracts:verify:amoy:all           # verify every contract in addresses.amoy.json
#   DRY_RUN=1 pnpm contracts:verify:amoy:all  # print the forge commands without running them
#   ADDRESS_BOOK=packages/shared/addresses.local.json DRY_RUN=1 bash contracts/script/verify-amoy.sh
#
# Env consumed (from repo-root .env): POLYGONSCAN_API_KEY, DEPLOYER_PRIVATE_KEY,
# CLAIM_ISSUER_MANAGEMENT_ADDRESS. Overridable: VERIFY_CHAIN (default amoy), ADDRESS_BOOK,
# DRY_RUN. Written for bash 3.2 (macOS default) — no associative arrays or mapfile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTRACTS_DIR="$REPO_ROOT/contracts"

# Load repo-root .env so the keys/addresses match the deployment. Never echo secrets.
set -a
# shellcheck disable=SC1091
[ -f "$REPO_ROOT/.env" ] && . "$REPO_ROOT/.env"
set +a

CHAIN="${VERIFY_CHAIN:-amoy}"
ADDRESS_BOOK="${ADDRESS_BOOK:-$REPO_ROOT/packages/shared/addresses.amoy.json}"
DRY_RUN="${DRY_RUN:-0}"

# ── Preconditions ───────────────────────────────────────────────────────────────────────────
[ -f "$ADDRESS_BOOK" ] || { echo "ERROR: address book not found: $ADDRESS_BOOK" >&2; exit 1; }
if [ "$DRY_RUN" != "1" ] && [ -z "${POLYGONSCAN_API_KEY:-}" ]; then
    echo "ERROR: POLYGONSCAN_API_KEY is empty — needed to verify. Set it in .env." >&2
    exit 1
fi

# Read one contract address from the book by name; fail loudly if the key is missing.
addr() {
    python3 - "$ADDRESS_BOOK" "$1" <<'PY'
import json, sys
book = json.load(open(sys.argv[1]))
contracts = book.get("contracts", {})
name = sys.argv[2]
if name not in contracts:
    sys.stderr.write("address book is missing contract '%s'\n" % name)
    sys.exit(3)
print(contracts[name])
PY
}

# ── Reconstruct constructor args for the four contracts that take them ───────────────────────
# These mirror Deploy.s.sol exactly: Identity(deployer, true), ImplementationAuthority(idLib),
# IdFactory(implAuth), ClaimIssuer(claimIssuerManagement). cast runs offline.
DEPLOYER_ADDR="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
IDENTITY_LIB="$(addr IdentityLibrary)"
IMPL_AUTH="$(addr ImplementationAuthority)"

ARGS_IDENTITY="$(cast abi-encode 'constructor(address,bool)' "$DEPLOYER_ADDR" true)"
ARGS_IMPLAUTH="$(cast abi-encode 'constructor(address)' "$IDENTITY_LIB")"
ARGS_IDFACTORY="$(cast abi-encode 'constructor(address)' "$IMPL_AUTH")"
ARGS_CLAIMISSUER="$(cast abi-encode 'constructor(address)' "$CLAIM_ISSUER_MANAGEMENT_ADDRESS")"

# In dry-run, show the env-var reference rather than the resolved key so output is safe to paste.
if [ "$DRY_RUN" = "1" ]; then KEY_DISPLAY='${POLYGONSCAN_API_KEY}'; else KEY_DISPLAY="$POLYGONSCAN_API_KEY"; fi

PASS=0
FAIL=0
FAILED_NAMES=""

# verify <bookName> <path:Name> [constructorArgsHex]
verify() {
    local name="$1" contract="$2" ctor="${3:-}"
    local address
    address="$(addr "$name")"

    local cmd
    cmd=(forge verify-contract "$address" "$contract"
        --chain "$CHAIN" --etherscan-api-key "$KEY_DISPLAY" --watch)
    [ -n "$ctor" ] && cmd=("${cmd[@]}" --constructor-args "$ctor")

    echo "── $name  ($address)"
    if [ "$DRY_RUN" = "1" ]; then
        printf '   '; printf '%q ' "${cmd[@]}"; printf '\n'
        return 0
    fi
    if ( cd "$CONTRACTS_DIR" && "${cmd[@]}" ); then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES="$FAILED_NAMES $name"
    fi
}

echo "Verifying contracts from $ADDRESS_BOOK on chain '$CHAIN'${DRY_RUN:+ }${DRY_RUN:+(DRY_RUN=$DRY_RUN)}"
echo

# No constructor args (OZ-upgradeable init pattern + the plain module):
verify ClaimTopicsRegistry     "lib/erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol:ClaimTopicsRegistry"
verify TrustedIssuersRegistry  "lib/erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol:TrustedIssuersRegistry"
verify IdentityRegistryStorage "lib/erc-3643/contracts/registry/implementation/IdentityRegistryStorage.sol:IdentityRegistryStorage"
verify IdentityRegistry        "lib/erc-3643/contracts/registry/implementation/IdentityRegistry.sol:IdentityRegistry"
verify ModularCompliance       "lib/erc-3643/contracts/compliance/modular/ModularCompliance.sol:ModularCompliance"
verify MaxInvestorsModule      "src/modules/MaxInvestorsModule.sol:MaxInvestorsModule"
verify Token                   "lib/erc-3643/contracts/token/Token.sol:Token"

# With constructor args (ONCHAINID stack):
verify IdentityLibrary         "lib/onchain-id-solidity/contracts/Identity.sol:Identity"                                     "$ARGS_IDENTITY"
verify ImplementationAuthority "lib/onchain-id-solidity/contracts/proxy/ImplementationAuthority.sol:ImplementationAuthority" "$ARGS_IMPLAUTH"
verify IdFactory               "lib/onchain-id-solidity/contracts/factory/IdFactory.sol:IdFactory"                           "$ARGS_IDFACTORY"
verify ClaimIssuer             "lib/onchain-id-solidity/contracts/ClaimIssuer.sol:ClaimIssuer"                               "$ARGS_CLAIMISSUER"

echo
if [ "$DRY_RUN" = "1" ]; then
    echo "DRY_RUN complete — 11 verify commands printed, none executed."
    exit 0
fi
echo "Verified: $PASS   Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed contracts:$FAILED_NAMES" >&2
    echo "Re-run this script (verification is idempotent) or inspect the constructor-args / compiler settings for the above." >&2
    exit 1
fi
echo "All contracts verified on $CHAIN."
