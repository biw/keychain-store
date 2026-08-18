import { openKeychainStore } from "../src/index.js";

const store = openKeychainStore({
  accounts: ["archive-key", "desktop-profile"],
  mutableAccounts: ["database-key", "desktop-token"],
  authentication: { accessControl: "user-presence" },
  iCloudSync: false,
});

const key = await store.get("archive-key", "Uint8Array");
const profile = await store.get("desktop-profile", "string");
const generatedKey = await store.getOrCreate("database-key");
const suppliedKey = await store.getOrCreate("archive-key", new Uint8Array(32));
const token = await store.getOrCreate("desktop-token", "token-value");

const acceptsNullOrBytes: null | Uint8Array = key;
const acceptsNullOrString: null | string = profile;
const acceptsBytes: Uint8Array = generatedKey;
const acceptsSuppliedBytes: Uint8Array = suppliedKey;
const acceptsString: string = token;
void [acceptsNullOrBytes, acceptsNullOrString, acceptsBytes, acceptsSuppliedBytes, acceptsString];

await store.set("desktop-token", "updated token");
await store.set("database-key", new Uint8Array(32));
await store.remove("desktop-token");
store.status("desktop-profile");

const keyStore = openKeychainStore({
  accounts: ["database-key"],
  mutableAccounts: ["desktop-token"],
  authentication: "none",
  iCloudSync: false,
  keychainService: "com.example.product",
});

keyStore.getOrCreate("database-key");
keyStore.set("desktop-token", "token-value");

// @ts-expect-error Immutable accounts cannot be updated.
keyStore.set("database-key", new Uint8Array(32));

// @ts-expect-error Immutable accounts cannot be removed.
keyStore.remove("database-key");

// @ts-expect-error Only declared accounts are accepted.
store.get("not-configured", "string");

// @ts-expect-error The representation is explicit.
store.get("archive-key");

// @ts-expect-error Only Uint8Array and string output representations are accepted.
store.get("archive-key", "Buffer");

// @ts-expect-error Only Uint8Array and string input values are accepted.
store.set("desktop-token", 42);

openKeychainStore({
  accounts: ["desktop-token"],
  authentication: "none",
  iCloudSync: false,
  // @ts-expect-error Accounts are immutable unless listed in mutableAccounts.
}).set("desktop-token", "token-value");

const mutableOnlyStore = openKeychainStore({
  mutableAccounts: ["desktop-token"],
  authentication: "none",
  iCloudSync: false,
});

mutableOnlyStore.set("desktop-token", "token-value");

openKeychainStore({
  accounts: ["database-key"],
  // @ts-expect-error The two authentication boundaries are mutually exclusive.
  authentication: { accessControl: "biometrics-only", operationAuth: "user-presence" },
  iCloudSync: false,
});
