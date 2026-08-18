import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { openKeychainStore } from "../dist/index.js";

const configuration = {
  authentication: "none",
  iCloudSync: false,
  accounts: ["archive-key", "database-key", "desktop-profile"],
  mutableAccounts: ["desktop-token"],
} as const;

const openInvalidKeychainStore = (invalidConfiguration: unknown) =>
  openKeychainStore(invalidConfiguration as never);

test("creates a frozen API for its declared Keychain accounts", () => {
  const storage = openKeychainStore(configuration);

  assert.deepEqual(Object.keys(storage), ["get", "getOrCreate", "remove", "set", "status"]);
  assert.equal(Object.isFrozen(storage), true);
  assert.equal("setValue" in storage, false);
  assert.equal("getValue" in storage, false);
});

test("validates configuration before crossing the native boundary", () => {
  assert.throws(
    () => openInvalidKeychainStore({ ...configuration, accounts: "database-key" }),
    /accounts must be an array/,
  );
  assert.throws(
    () => openInvalidKeychainStore({ ...configuration, accounts: [], mutableAccounts: [] }),
    /Declare at least one/,
  );
  assert.throws(
    () =>
      openInvalidKeychainStore({
        ...configuration,
        accounts: ["same-account", "same-account"],
      }),
    /appears more than once/,
  );
  assert.throws(
    () =>
      openInvalidKeychainStore({
        ...configuration,
        accounts: [" "],
      }),
    /Keychain account must not be empty/,
  );
  assert.throws(
    () =>
      openInvalidKeychainStore({
        ...configuration,
        accounts: [" desktop-token "],
      }),
    /Keychain account must not have surrounding whitespace/,
  );
  assert.throws(
    () =>
      openInvalidKeychainStore({
        ...configuration,
        accounts: [],
        mutableAccounts: ["database-key", "database-key"],
      }),
    /Mutable Keychain account appears more than once/,
  );
  assert.throws(
    () =>
      openInvalidKeychainStore({
        ...configuration,
        accounts: ["database-key"],
        mutableAccounts: ["database-key"],
      }),
    /cannot be both immutable and mutable/,
  );
  assert.doesNotThrow(() =>
    openKeychainStore({
      ...configuration,
      accounts: [],
      mutableAccounts: ["database-key"],
    }),
  );
  assert.throws(
    () =>
      openInvalidKeychainStore({
        ...configuration,
        authentication: { accessControl: "none" },
      }),
    /Unsupported accessControl authentication/,
  );
  assert.throws(
    () =>
      openInvalidKeychainStore({ ...configuration, authentication: { operationAuth: "touch-id" } }),
    /Unsupported operationAuth authentication/,
  );
  assert.throws(
    () =>
      openInvalidKeychainStore({
        ...configuration,
        authentication: { accessControl: "biometrics-only", operationAuth: "user-presence" },
      }),
    /exactly one/,
  );
  assert.throws(
    () => openInvalidKeychainStore({ ...configuration, iCloudSync: "yes" }),
    /iCloudSync must be a boolean/,
  );
  assert.throws(
    () => openInvalidKeychainStore({ ...configuration, keychainService: " " }),
    /keychainService must not be empty/,
  );
});

test("rejects accounts that were not declared in the store", async () => {
  const storage = openKeychainStore(configuration);

  await assert.rejects(
    storage.get("not-configured" as never, "Uint8Array"),
    /Keychain account is not configured/,
  );
  await assert.rejects(
    storage.get("not-configured" as never, "string"),
    /Keychain account is not configured/,
  );
  await assert.rejects(
    storage.set("not-configured" as never, "value"),
    /Keychain account is not configured/,
  );
  await assert.rejects(
    storage.remove("not-configured" as never),
    /Keychain account is not configured/,
  );
  await assert.rejects(storage.set("desktop-token", 42 as never), /Uint8Array or a string/);
  await assert.rejects(storage.get("desktop-token", "bytes" as never), /Uint8Array.*string/);

  const immutableStorage = openKeychainStore({
    ...configuration,
    accounts: ["database-key"],
    mutableAccounts: ["desktop-token"],
  });
  await assert.rejects(
    immutableStorage.set("database-key" as never, new Uint8Array(32)),
    /immutable/,
  );
  await assert.rejects(immutableStorage.remove("database-key" as never), /immutable/);
});

test("fails closed before a host without the requested shared-group entitlement can query the Keychain", async () => {
  const storage = openKeychainStore({
    ...configuration,
    keychainService: "com.example.product.shared",
  });

  await assert.rejects(storage.status("database-key"), (error) => {
    assert.ok(error instanceof Error);
    assert.equal((error as { code?: unknown }).code, "host_identity_invalid");
    assert.equal((error as { details?: { osStatus?: unknown } }).details?.osStatus, undefined);
    return true;
  });
});

test("uses the signed host's default Keychain namespace without identity configuration", async () => {
  const account = `keychain-store-default-namespace-${process.pid}`;
  const storage = openKeychainStore({
    accounts: [account],
    authentication: "none",
    iCloudSync: false,
  });

  assert.deepEqual(await storage.status(account), { status: "missing" });
});

test("native implementation stores declared items as arbitrary protected bytes", async () => {
  const source = await readFile(new URL("../src/native.swift", import.meta.url), "utf8");

  assert.match(source, /kSecUseDataProtectionKeychain:\s*true/);
  assert.match(source, /kSecAttrSynchronizable:\s*target\.iCloudSync/);
  assert.match(source, /if let accessGroup = target\.accessGroup/);
  assert.ok(source.includes('let accessGroup = "\\(teamId).\\(configuredService)"'));
  assert.match(source, /The running host is not entitled for Keychain access group/);
  assert.match(source, /synchronization_migration_required/);
  assert.match(source, /case userPresence = "user-presence"/);
  assert.match(source, /case biometricsOnly = "biometrics-only"/);
  assert.match(source, /func readItem/);
  assert.match(source, /func ensureItem/);
  assert.match(source, /func ensureRandomItem/);
  assert.match(source, /func writeItem/);
  assert.match(source, /func deleteItem/);
  assert.match(source, /public struct KeychainStoreSwift/);
  assert.match(source, /public func ensure\(_ account: String/);
  assert.match(source, /keychain-store\/v1:secure-value-access-control=/);
  assert.match(source, /Reopen it with the configuration used to create it or use a new account/);
  assert.match(source, /SecAccessControlGetTypeID/);
  assert.match(source, /SecItemUpdate/);
  assert.match(source, /SecItemDelete/);
  assert.match(source, /extension StructuredFailure: SwiftNodeStructuredError/);
  assert.doesNotMatch(source, /var payload: \[String: Any\]/);
  assert.doesNotMatch(source, /kSecUseKeychain/);
});
