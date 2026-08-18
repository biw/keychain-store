# keychain-store

[![CI](https://badgen.net/github/checks/biw/keychain-store)](https://github.com/biw/keychain-store/actions)
[![npm version](https://badgen.net/npm/v/keychain-store)](https://www.npmjs.com/package/keychain-store)
[![npm downloads](https://badgen.net/npm/dt/keychain-store)](https://www.npmjs.com/package/keychain-store)

Secure storage for signed Electron and Node apps, backed by the modern macOS [**Data Protection Keychain**](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web).

- Protect items with code-signing access groups; share only with explicitly entitled apps (no `security` CLI access)
- Restrict package access to item names your app declares
- Optionally require device-owner authentication (Touch ID or password), or Touch ID only
- Store UTF-8 strings and binary values

## Install

```bash
pnpm add keychain-store
```

## Quick start

```ts
import { openKeychainStore } from "keychain-store";

const store = openKeychainStore({
  // touch ID only
  authentication: { accessControl: "biometrics-only" },
  // build in iCloud sync
  iCloudSync: true,
  // support for immutable and mutable accounts
  accounts: ["installation-id"],
  mutableAccounts: ["desktop-token", "desktop-refresh-token"],
});

// Uint8Array containing 32 random bytes
const installationId = await store.getOrCreate("installation-id");

await store.set("desktop-token", "an application token");
// string | null
const token = await store.get("desktop-token", "string");
// Uint8Array | null
const token = await store.get("desktop-token", "Uint8Array");
```

`accounts` declares immutable Keychain items; `mutableAccounts` declares mutable ones. The store
can access their union, while only mutable accounts may be changed or removed. A name belongs in
exactly one list, and either list may be omitted.

## API

| Method                        | What it does                                                       |
| ----------------------------- | ------------------------------------------------------------------ |
| `get(account, "Uint8Array")`  | Returns stored binary data, or `null`.                             |
| `get(account, "string")`      | Returns a stored UTF-8 string, or `null`.                          |
| `getOrCreate(account)`        | Returns an existing value or creates 32 random bytes.              |
| `getOrCreate(account, value)` | Returns an existing value or creates the supplied string or bytes. |
| `set(account, value)`         | Creates or replaces a mutable item.                                |
| `remove(account)`             | Removes a mutable item and reports whether it existed.             |
| `status(account)`             | Checks an item’s state without returning its value.                |

## Setup

The running Electron or Node host must have a valid Apple code signature. By default, the package
uses the host’s bundle identifier as its Keychain service and lets macOS use the host’s private
Keychain access group. No package identity configuration is required.

| Option            | Purpose                                                     |
| ----------------- | ----------------------------------------------------------- |
| `keychainService` | Optional shared namespace for separately signed apps.       |
| `authentication`  | Whether macOS should ask the user to authenticate.          |
| `iCloudSync`      | Whether items should synchronize through iCloud Keychain.   |
| `accounts`        | Immutable item names the store can access.                  |
| `mutableAccounts` | Mutable item names the store can access, change, or remove. |

### Data Protection Keychain

This package stores generic-password items in macOS's **Data Protection Keychain**. Its native
implementation uses the `SecItem` API with `kSecUseDataProtectionKeychain: true`, rather than the
legacy file-based Keychain used by the older Keychain and `SecKeychain` APIs. Apple recommends the
Data Protection Keychain for new work because it supports modern access groups, iCloud Keychain,
and biometric access control. See [Apple's keychain implementation guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

| Aspect                   | Legacy file-based Keychain                                                  | Data Protection Keychain (this package)                                               |
| ------------------------ | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| API target               | Keychain and `SecKeychain`; `SecItem` when no Data Protection target is set | `SecItem` with `kSecUseDataProtectionKeychain: true`                                  |
| Access model             | Per-item access control lists (`SecAccess`)                                 | Code-signing entitlement access groups, optionally supplemented by `SecAccessControl` |
| iCloud Keychain          | Not supported                                                               | Supported with `iCloudSync: true`                                                     |
| Biometric protection     | Not supported by its legacy access model                                    | Supported with `authentication: { accessControl: "biometrics-only" }`                 |
| Command-line inspection  | The `security` CLI can inspect keychain files                               | The `security` CLI does not directly inspect these items                              |
| Keychain Access location | Login, System, and other file-based keychains                               | **Local Items**, or **iCloud Keychain** for synchronized items                        |
| Availability             | Can be used by processes outside a user-login context                       | Requires a user-login context                                                         |

Items created through a legacy file-based Keychain API are not automatically available here; migrate
them explicitly if needed. The `security` CLI is likewise not an inspection path for this store's
items. Use Keychain Access instead: items appear under **Local Items** when `iCloudSync` is `false`,
or **iCloud Keychain** when it is `true`.

## Local development

  <details>
  <summary>Set up a signed Electron development runtime</summary>

An unmodified Electron runtime identifies itself as Electron, so it is not a good namespace for
your app’s development secrets. Instead, run Electron Vite with a cached Electron runtime signed as
a separate development app, such as `com.example.product.dev`. With no `keychainService`, the same
`openKeychainStore()` call then uses that bundle identifier automatically, keeping local values
separate from production.

### 1. Create a development signing profile

In the Apple Developer portal, register `com.example.product.dev` and create a macOS development
provisioning profile for it. Enable Keychain Sharing. The profile must allow this complete access
group:

```text
ABCDE12345.com.example.product.dev
```

Replace `ABCDE12345` with your Apple Developer Team ID. Xcode can create the profile for you: make
a temporary macOS app target with that bundle identifier, choose your Team, add the Keychain Sharing
capability, and build it once.

### 2. Sign a copy of Electron

Keep this copy in a user cache outside `node_modules`; recreate it whenever the Electron version,
development certificate, or provisioning profile changes. Create a main entitlement file containing
your complete identifiers and Electron’s normal runtime entitlements:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>ABCDE12345.com.example.product.dev</string>
  <key>com.apple.developer.team-identifier</key>
  <string>ABCDE12345</string>
  <key>keychain-access-groups</key>
  <array>
    <string>ABCDE12345.com.example.product.dev</string>
  </array>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
```

Sign Electron’s helper apps first. They do not need your Keychain access group; this minimal helper
entitlement file is enough for a standard Electron development runtime:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
```

Save the two files as `electron-development.entitlements.plist` and
`electron-helper.entitlements.plist`, then run:

```bash
export DEVELOPMENT_BUNDLE_ID="com.example.product.dev"
export DEVELOPMENT_SIGNING_IDENTITY="Apple Development: Your Name (ABCDE12345)"
export DEVELOPMENT_PROVISIONING_PROFILE="/path/to/development.provisionprofile"
export RUNTIME_DIR="$HOME/Library/Caches/example-product/electron-dev"

ditto node_modules/electron/dist "$RUNTIME_DIR"
export ELECTRON_APP="$RUNTIME_DIR/Electron.app"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEVELOPMENT_BUNDLE_ID" \
  "$ELECTRON_APP/Contents/Info.plist"
cp "$DEVELOPMENT_PROVISIONING_PROFILE" "$ELECTRON_APP/Contents/embedded.provisionprofile"

for helper in "$ELECTRON_APP"/Contents/Frameworks/Electron\ Helper*.app; do
  codesign --force --sign "$DEVELOPMENT_SIGNING_IDENTITY" --options runtime \
    --timestamp=none --entitlements electron-helper.entitlements.plist "$helper"
done

codesign --force --sign "$DEVELOPMENT_SIGNING_IDENTITY" --options runtime --timestamp=none \
  --generate-entitlement-der --entitlements electron-development.entitlements.plist "$ELECTRON_APP"

codesign --verify --deep --strict --verbose=2 "$ELECTRON_APP"
```

### 3. Use that runtime for development

Set these before your Electron Vite launch (usually in the script that starts `electron-vite dev`):

```bash
export ELECTRON_OVERRIDE_DIST_PATH="$RUNTIME_DIR"
export ELECTRON_EXEC_PATH="$ELECTRON_APP/Contents/MacOS/Electron"
```

Keep `keychainService` omitted unless you intentionally share items between apps. A shared service
also needs its matching Keychain access-group entitlement in the development runtime.

  </details>

## Who can access these items?

macOS gives access to every app signed with matching Keychain access-group entitlements. Keep your
signing certificates, private keys, and entitlement configuration secure.

## Authentication

Authentication controls whether macOS asks the user to verify access. It does not decide which apps
can access an item: the signed host identity and Keychain access group always do that.

Choose one authentication boundary. The package does not combine them, so one operation does not
produce two prompts.

### Item access control

`authentication: { accessControl: ... }` stores the requirement with the item. It applies whenever
an entitled app reads that item, even if that app does not use this package.

| Value             | Result                                                       |
| ----------------- | ------------------------------------------------------------ |
| `user-presence`   | Requires macOS device-owner authentication to read the item. |
| `biometrics-only` | Requires Touch ID to read the item.                          |

`user-presence` permits macOS device-owner authentication, such as Touch ID or the user’s password.
`biometrics-only` fails on a Mac without enrolled Touch ID; it does not use an Apple Watch or a nearby
iPhone.

### Operation authentication

`authentication: { operationAuth: ... }` asks the current app to authenticate before each package
operation. It does not change the stored item, so another entitled app is not required to make the
same prompt.

| Value             | Result                                      |
| ----------------- | ------------------------------------------- |
| `user-presence`   | Requires macOS device-owner authentication. |
| `biometrics-only` | Requires Touch ID.                          |

Use `authentication: "none"` when no extra user-verification prompt is required. It does not make
items public; only apps that satisfy the configured signing and entitlement policy can access them.

### Change item access control with a new account

An item’s `accessControl` policy is persistent. To change it, create a new account with the new
policy and migrate your application data to it. For an encryption key, that normally means
re-encrypting the application data with the new key. `operationAuth` is not stored with the item and
can change independently.

## iCloud synchronization

Set `iCloudSync: true` to ask macOS to synchronize the store’s items through iCloud Keychain.
Changing the setting never deletes an existing item.

`get()` remains read-only. If an item exists only with the opposite synchronization setting, it
rejects with `synchronization_migration_required`. `getOrCreate()` adds a copy in the configured
scope; it does not overwrite or remove the existing copy.

The package does not check whether the user is signed in to an Apple Account or has iCloud Keychain
enabled. Creation can succeed locally even when macOS cannot currently synchronize the item; success
means only that Keychain accepted it, not that another device received it. If the Security framework
cannot create or access an item, the operation rejects with its Keychain error.

## Value representation

Use strings for UTF-8 text and `Uint8Array` for binary data. Choose the representation explicitly
when calling `get()`. A request for `"string"` rejects with `item_not_utf8` if the item does not
contain valid UTF-8 text.

## Share keys with another app

Set the same `keychainService` in every app that shares this store. The package derives the access
group as the running app’s Team ID followed by this value.

```ts
const sharedStore = openKeychainStore({
  keychainService: "com.example.product.shared",
  authentication: "none",
  iCloudSync: false,
  accounts: ["installation-id"],
  mutableAccounts: ["desktop-token"],
});
```

Each app must include the resulting complete access group in its signing entitlements. With
[Electron Builder](https://www.electron.build/mac/), add it to the macOS entitlements plist. With
[Electron Forge](https://www.electronforge.io/guides/code-signing/code-signing-macos), pass that
plist through `packagerConfig.osxSign`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>keychain-access-groups</key>
  <array>
    <string>ABCDE12345.com.example.product.shared</string>
  </array>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <!-- other entitlements -->
</dict>
</plist>
```

## Use from Swift

This repository also provides the `KeychainStore` Swift Package Manager library for signed native
macOS targets. It is distributed through Swift Package Manager, not the npm package. Add the
`KeychainStore` library product from this repository:

```swift
.package(url: "https://github.com/biw/keychain-store.git", branch: "main")
```

Use a version requirement instead once the repository has a tagged release. The Swift library uses
the same item format and declared-account policy as the Node package.

```swift
import KeychainStore

let store = try KeychainStoreSwift(
  accounts: ["installation-id"],
  authentication: .accessControl(.userPresence),
  mutableAccounts: ["desktop-token"],
)

try await store.ensure("installation-id")
let token = try await store.get("desktop-token")
```

`ensure()` creates an item without returning its bytes, which is useful when native code owns the
encryption workflow.

### Synchronous Swift API

`KeychainStoreSwiftSync` offers the same declared-account methods, but uses only
`authentication: .none`. Its operations can block the calling thread, so use the async store unless
a synchronous boundary is required.

```swift
import KeychainStore

let store = try KeychainStoreSwiftSync(
  accounts: ["installation-id"],
  mutableAccounts: ["desktop-token"],
)

try store.ensure("installation-id")
let id = try store.get("installation-id")
```

## License

MIT
