import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { addressBookSchema, type AddressBook, type ChainEnv } from "./schemas";

// Node-only entry point. Import from "@tessera/shared/address-book" (never the browser
// bundle) — the API, indexer, and deploy scripts read the address book from disk.

// Compiled to dist/address-book.js; the JSON files sit at the package root, one level up.
const PACKAGE_ROOT = join(__dirname, "..");

/** Absolute path to the address book for a chain environment. */
export function addressBookPath(env: ChainEnv): string {
  return join(PACKAGE_ROOT, `addresses.${env}.json`);
}

/**
 * Load and validate the address book for a chain environment. Throws if the file is
 * missing (e.g. before a local deploy has written `addresses.local.json`) so callers fail
 * loudly rather than reading an empty/stale book.
 */
export function loadAddressBook(env: ChainEnv): AddressBook {
  const path = addressBookPath(env);
  if (!existsSync(path)) {
    throw new Error(
      `Address book not found for env "${env}" at ${path}. Run a deploy to generate it.`,
    );
  }
  const raw = JSON.parse(readFileSync(path, "utf-8")) as unknown;
  return addressBookSchema.parse(raw);
}

/** Like {@link loadAddressBook} but returns `undefined` instead of throwing when absent. */
export function tryLoadAddressBook(env: ChainEnv): AddressBook | undefined {
  return existsSync(addressBookPath(env)) ? loadAddressBook(env) : undefined;
}
