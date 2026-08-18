import {
  deleteItem as nativeDeleteItem,
  ensureItem as nativeEnsureItem,
  ensureRandomItem as nativeEnsureRandomItem,
  readItem as nativeReadItem,
  secretStatus as nativeSecretStatus,
  writeItem as nativeWriteItem,
} from "../dist_swift-node/index.mjs";

type AuthenticationPolicy = "biometrics-only" | "user-presence";

type OperationAuthentication = "none" | AuthenticationPolicy;

type ItemAccessControl = "none" | AuthenticationPolicy;

/**
 * Selects one authentication boundary. Item access control is persistent;
 * operation authentication applies only to this store call.
 */
type Authentication =
  | "none"
  | { accessControl: AuthenticationPolicy; operationAuth?: never }
  | { accessControl?: never; operationAuth: AuthenticationPolicy };

type KeychainStoreConfiguration<
  AccountNames extends readonly string[] = readonly [],
  MutableAccountNames extends readonly string[] = readonly [],
> = {
  /** The one authentication boundary used for this store's item operations. */
  authentication: Authentication;
  /** Synchronize this store's items to the user's iCloud Keychain. */
  iCloudSync: boolean;
  /**
   * An explicit namespace shared by separately signed apps. Its Keychain
   * access group is derived as `TeamID.keychainService` and must be entitled.
   * Omit it to use this app's private bundle-identifier namespace.
   */
  keychainService?: string | undefined;
  /** Immutable Keychain accounts this store can access. */
  accounts?: AccountNames | undefined;
  /** Mutable Keychain accounts this store can access. */
  mutableAccounts?: MutableAccountNames | undefined;
};

type KeychainStoreKeyStatus =
  | { status: "available" }
  | { status: "missing" }
  | { status: "requires-authentication" }
  | { status: "synchronization-migration-required" };

type KeychainStoreValue = Uint8Array | string;

type KeychainStoreValueType = "Uint8Array" | "string";

export type KeychainStore<
  AccountName extends string,
  MutableAccountName extends AccountName = never,
> = {
  /** Returns a stored item in the requested representation, or `null` when absent. */
  get: {
    (account: AccountName, type: "Uint8Array"): Promise<null | Uint8Array>;
    (account: AccountName, type: "string"): Promise<null | string>;
  };
  /**
   * Returns the existing item in the requested initial-value representation,
   * or creates it. With no initial value, creates 32 random bytes. A valid
   * concurrent winner is adopted and never overwritten.
   */
  getOrCreate: {
    (account: AccountName): Promise<Uint8Array>;
    (account: AccountName, initialValue: Uint8Array): Promise<Uint8Array>;
    (account: AccountName, initialValue: string): Promise<string>;
  };
  /** Creates or replaces one declared mutable item. */
  set: (account: MutableAccountName, value: KeychainStoreValue) => Promise<void>;
  /** Removes a declared mutable item and returns whether it existed. */
  remove: (account: MutableAccountName) => Promise<boolean>;
  /** Checks presence without returning data or prompting the user. */
  status: (account: AccountName) => Promise<KeychainStoreKeyStatus>;
};

type NativeTarget = {
  account: string;
  itemAccessControl: ItemAccessControl;
  keychainService?: string | undefined;
  operationAuthentication: OperationAuthentication;
  iCloudSync: boolean;
};

interface KeychainStoreError extends Error {
  readonly code: string;
  readonly details: {
    readonly osStatus?: number | undefined;
  };
}

const isAuthenticationPolicy = (value: unknown): value is AuthenticationPolicy =>
  value === "biometrics-only" || value === "user-presence";

const isKeychainStoreError = (error: unknown): error is KeychainStoreError => {
  if (!(error instanceof Error)) {
    return false;
  }
  const candidate = error as { code?: unknown; details?: unknown };
  if (typeof candidate.code !== "string" || typeof candidate.details !== "object") {
    return false;
  }
  if (candidate.details === null || Array.isArray(candidate.details)) {
    return false;
  }
  const osStatus = (candidate.details as { osStatus?: unknown }).osStatus;
  return osStatus === undefined || typeof osStatus === "number";
};

const requireNonEmpty = (value: string, label: string): string => {
  const normalized = value.trim();
  if (normalized.length === 0) {
    throw new TypeError(`${label} must not be empty`);
  }
  return normalized;
};

const normalizeAuthentication = (
  authentication: Authentication,
): { itemAccessControl: ItemAccessControl; operationAuthentication: OperationAuthentication } => {
  if (authentication === "none") {
    return { itemAccessControl: "none", operationAuthentication: "none" };
  }

  if (
    typeof authentication !== "object" ||
    authentication === null ||
    Array.isArray(authentication)
  ) {
    throw new TypeError('authentication must be "none", accessControl, or operationAuth');
  }

  const keys = Object.keys(authentication);
  if (keys.length !== 1) {
    throw new TypeError("authentication must set exactly one of accessControl or operationAuth");
  }

  if ("accessControl" in authentication) {
    if (!isAuthenticationPolicy(authentication.accessControl)) {
      throw new TypeError(
        `Unsupported accessControl authentication: ${authentication.accessControl}`,
      );
    }
    return { itemAccessControl: authentication.accessControl, operationAuthentication: "none" };
  }

  if ("operationAuth" in authentication) {
    if (!isAuthenticationPolicy(authentication.operationAuth)) {
      throw new TypeError(
        `Unsupported operationAuth authentication: ${authentication.operationAuth}`,
      );
    }
    return { itemAccessControl: "none", operationAuthentication: authentication.operationAuth };
  }

  throw new TypeError("authentication must set exactly one of accessControl or operationAuth");
};

const normalizeConfiguration = <
  AccountNames extends readonly string[],
  MutableAccountNames extends readonly string[],
>(
  configuration: KeychainStoreConfiguration<AccountNames, MutableAccountNames>,
) => {
  const normalizedAuthentication = normalizeAuthentication(configuration.authentication);
  const keychainService =
    configuration.keychainService === undefined
      ? undefined
      : requireNonEmpty(configuration.keychainService, "keychainService");

  if (typeof configuration.iCloudSync !== "boolean") {
    throw new TypeError("iCloudSync must be a boolean");
  }
  if (configuration.accounts !== undefined && !Array.isArray(configuration.accounts)) {
    throw new TypeError("accounts must be an array");
  }

  const accounts = new Set<string>();
  const normalizeAccount = (account: string, label: string): string => {
    const normalizedAccount = requireNonEmpty(account, label);
    if (normalizedAccount !== account) {
      throw new TypeError(`${label} must not have surrounding whitespace`);
    }
    return normalizedAccount;
  };
  const normalizedAccounts = (configuration.accounts ?? []).map((account) => {
    const normalizedAccount = normalizeAccount(account, "Keychain account");
    if (accounts.has(normalizedAccount)) {
      throw new TypeError(`Keychain account appears more than once: ${normalizedAccount}`);
    }
    accounts.add(normalizedAccount);
    return normalizedAccount;
  });
  if (
    configuration.mutableAccounts !== undefined &&
    !Array.isArray(configuration.mutableAccounts)
  ) {
    throw new TypeError("mutableAccounts must be an array");
  }
  const mutableAccounts = new Set<string>();
  for (const account of configuration.mutableAccounts ?? []) {
    const normalizedAccount = normalizeAccount(account, "Mutable Keychain account");
    if (mutableAccounts.has(normalizedAccount)) {
      throw new TypeError(`Mutable Keychain account appears more than once: ${normalizedAccount}`);
    }
    if (accounts.has(normalizedAccount)) {
      throw new TypeError(
        `Keychain account cannot be both immutable and mutable: ${normalizedAccount}`,
      );
    }
    mutableAccounts.add(normalizedAccount);
  }
  if (accounts.size + mutableAccounts.size === 0) {
    throw new TypeError("Declare at least one Keychain account");
  }
  return {
    ...normalizedAuthentication,
    accounts: [...normalizedAccounts, ...mutableAccounts],
    iCloudSync: configuration.iCloudSync,
    keychainService,
    mutableAccounts,
  };
};

const valueTypeError = (): never => {
  throw new TypeError("Keychain item values must be a Uint8Array or a string");
};

const encodeValue = (value: KeychainStoreValue): Uint8Array => {
  if (value instanceof Uint8Array) {
    return value;
  }
  if (typeof value === "string") {
    return new TextEncoder().encode(value);
  }
  return valueTypeError();
};

const decodeString = (value: Uint8Array): string => {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(value);
  } catch {
    throw Object.assign(new Error("The existing Keychain item is not a valid UTF-8 string"), {
      code: "item_not_utf8",
      details: {},
    });
  }
};

/**
 * Opens an opinionated Data Protection Keychain namespace for declared
 * application items. The running signed host selects the private namespace by
 * default; an explicit keychainService selects an entitled shared namespace.
 */
export const openKeychainStore = <
  const AccountNames extends readonly string[] = readonly [],
  const MutableAccountNames extends readonly string[] = readonly [],
>(
  configuration: KeychainStoreConfiguration<AccountNames, MutableAccountNames>,
): KeychainStore<
  AccountNames[number] | MutableAccountNames[number],
  MutableAccountNames[number]
> => {
  const normalized = normalizeConfiguration(configuration);
  const accounts = new Set(normalized.accounts);
  type AccountName = AccountNames[number] | MutableAccountNames[number];

  const targetFor = (account: AccountName): NativeTarget => {
    if (!accounts.has(account)) {
      throw new TypeError(`Keychain account is not configured: ${account}`);
    }

    return {
      account,
      itemAccessControl: normalized.itemAccessControl,
      operationAuthentication: normalized.operationAuthentication,
      iCloudSync: normalized.iCloudSync,
      ...(normalized.keychainService === undefined
        ? {}
        : { keychainService: normalized.keychainService }),
    };
  };

  const assertMutable = (account: MutableAccountNames[number]): void => {
    if (!normalized.mutableAccounts.has(account)) {
      throw new TypeError(`Keychain account is immutable: ${account}`);
    }
  };

  async function get(account: AccountName, type: "Uint8Array"): Promise<null | Uint8Array>;
  async function get(account: AccountName, type: "string"): Promise<null | string>;
  async function get(
    account: AccountName,
    type: KeychainStoreValueType,
  ): Promise<null | KeychainStoreValue> {
    if (type !== "Uint8Array" && type !== "string") {
      throw new TypeError('Keychain item type must be "Uint8Array" or "string"');
    }
    try {
      const value = await nativeReadItem(targetFor(account));
      return type === "Uint8Array" ? value : decodeString(value);
    } catch (error) {
      if (isKeychainStoreError(error) && error.code === "item_missing") {
        return null;
      }
      throw error;
    }
  }

  async function getOrCreate(account: AccountName): Promise<Uint8Array>;
  async function getOrCreate(account: AccountName, initialValue: Uint8Array): Promise<Uint8Array>;
  async function getOrCreate(account: AccountName, initialValue: string): Promise<string>;
  async function getOrCreate(
    account: AccountName,
    initialValue?: KeychainStoreValue,
  ): Promise<KeychainStoreValue> {
    const target = targetFor(account);
    if (initialValue === undefined) {
      return nativeEnsureRandomItem(target);
    }
    const value = await nativeEnsureItem(target, encodeValue(initialValue));
    return typeof initialValue === "string" ? decodeString(value) : value;
  }

  const set = async (
    account: MutableAccountNames[number],
    value: KeychainStoreValue,
  ): Promise<void> => {
    const target = targetFor(account);
    assertMutable(account);
    await nativeWriteItem(target, encodeValue(value));
  };

  const remove = async (account: MutableAccountNames[number]): Promise<boolean> => {
    const target = targetFor(account);
    assertMutable(account);
    return nativeDeleteItem(target);
  };

  const status = async (account: AccountName): Promise<KeychainStoreKeyStatus> => {
    const payload = await nativeSecretStatus(targetFor(account));
    return JSON.parse(payload) as KeychainStoreKeyStatus;
  };

  return Object.freeze({
    get,
    getOrCreate,
    remove,
    set,
    status,
  }) as KeychainStore<AccountName, MutableAccountNames[number]>;
};
