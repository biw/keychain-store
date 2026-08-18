import assert from "node:assert/strict";
import process from "node:process";
import test from "node:test";

import { openKeychainStore } from "../../dist/index.js";

const requiredEnvironment = ["KEYCHAIN_STORE_INTEGRATION_SERVICE"];
const missingEnvironment = requiredEnvironment.filter((name) => !process.env[name]);
const accountPrefix = `keychain-store-fixture-${Date.now()}-${process.pid}`;

const requireEnvironment = (name) => {
  const value = process.env[name];
  assert.ok(value, `${name} must be set to run signed integration tests`);
  return value;
};

const configurationFor = (accounts, authentication, iCloudSync, mutableAccounts = []) => ({
  accounts,
  authentication,
  iCloudSync,
  keychainService: requireEnvironment("KEYCHAIN_STORE_INTEGRATION_SERVICE"),
  mutableAccounts,
});

const expectCode = (code) => (error) => {
  assert.ok(error instanceof Error);
  assert.equal(error.code, code);
  return true;
};

test(
  "signed fixture creates, reads, and rejects a persistent-policy mismatch",
  { skip: missingEnvironment.length > 0 && `Missing ${missingEnvironment.join(", ")}` },
  async () => {
    const account = `${accountPrefix}-local`;
    const valueAccount = `${accountPrefix}-value`;
    const byteAccount = `${accountPrefix}-bytes`;
    const configuration = configurationFor([account], "none", false, [valueAccount, byteAccount]);
    const store = openKeychainStore(configuration);
    const created = await store.getOrCreate(account);
    assert.equal(created.byteLength, 32);
    assert.deepEqual(await store.get(account, "Uint8Array"), created);
    assert.deepEqual(await store.status(account), { status: "available" });
    assert.equal(await store.get(valueAccount, "string"), null);
    assert.equal(await store.getOrCreate(valueAccount, "first value"), "first value");
    assert.equal(await store.get(valueAccount, "string"), "first value");
    await store.set(valueAccount, "updated value");
    assert.equal(await store.get(valueAccount, "string"), "updated value");
    assert.equal(await store.remove(valueAccount), true);
    assert.equal(await store.remove(valueAccount), false);

    const textBytes = new TextEncoder().encode("bytes as text");
    await store.set(byteAccount, textBytes);
    assert.deepEqual(await store.get(byteAccount, "Uint8Array"), textBytes);
    assert.equal(await store.get(byteAccount, "string"), "bytes as text");
    assert.equal(await store.remove(byteAccount), true);

    const protectedStore = openKeychainStore({
      ...configuration,
      authentication: { accessControl: "user-presence" },
    });
    await assert.rejects(protectedStore.status(account), expectCode("item_policy_mismatch"));
  },
);

test(
  "signed fixture migrates one key between local and iCloud Keychain",
  {
    skip:
      missingEnvironment.length > 0 || process.env.KEYCHAIN_STORE_INTEGRATION_ICLOUD !== "1"
        ? "Set KEYCHAIN_STORE_INTEGRATION_SERVICE and KEYCHAIN_STORE_INTEGRATION_ICLOUD=1 on an iCloud-enabled host"
        : false,
  },
  async () => {
    const account = `${accountPrefix}-icloud`;
    const local = openKeychainStore(configurationFor([account], "none", false));
    const localKey = await local.getOrCreate(account);

    const synced = openKeychainStore(configurationFor([account], "none", true));
    await assert.rejects(
      synced.get(account, "Uint8Array"),
      expectCode("synchronization_migration_required"),
    );
    assert.deepEqual(await synced.getOrCreate(account), localKey);
    assert.deepEqual(await local.getOrCreate(account), localKey);
  },
);

test(
  "signed fixture prompts for operation and item authentication",
  {
    skip:
      missingEnvironment.length > 0 || process.env.KEYCHAIN_STORE_INTEGRATION_INTERACTIVE !== "1"
        ? "Set KEYCHAIN_STORE_INTEGRATION_SERVICE and KEYCHAIN_STORE_INTEGRATION_INTERACTIVE=1 to allow macOS prompts"
        : false,
  },
  async () => {
    const operationAccount = `${accountPrefix}-operation-auth`;
    const operationStore = openKeychainStore(
      configurationFor([operationAccount], { operationAuth: "user-presence" }, false),
    );
    const operationKey = await operationStore.getOrCreate(operationAccount);
    assert.deepEqual(await operationStore.get(operationAccount, "Uint8Array"), operationKey);

    const itemAccount = `${accountPrefix}-item-auth`;
    const itemStore = openKeychainStore(
      configurationFor([itemAccount], { accessControl: "user-presence" }, false),
    );
    const itemKey = await itemStore.getOrCreate(itemAccount);
    assert.deepEqual(await itemStore.get(itemAccount, "Uint8Array"), itemKey);

    const valueAccount = `${accountPrefix}-value-auth`;
    const valueStore = openKeychainStore(
      configurationFor([], { accessControl: "user-presence" }, false, [valueAccount]),
    );
    await valueStore.set(valueAccount, "protected value");
    assert.equal(await valueStore.get(valueAccount, "string"), "protected value");
  },
);
