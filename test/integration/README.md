# Signed Keychain integration fixture

This fixture intentionally runs only inside a host that has a valid Apple code signature and a
matching `keychain-access-groups` entitlement. It is not part of `pnpm test`, so ordinary unit tests
do not need a developer account, a signed application, iCloud Keychain, or authentication hardware.

Use [entitlements.plist](entitlements.plist) as the shape for the host's entitlement file, replacing
`ABCDE12345.com.example.keychain-store.fixture` with the complete access group your signed host is
entitled to use. Run the fixture from that signed host's Node/Electron main-process test command.
The executable that launches Node must be the signed host; every store operation verifies that
process before accessing Keychain.

Set the service suffix used in that access group:

```bash
export KEYCHAIN_STORE_INTEGRATION_SERVICE="com.example.keychain-store.fixture"
pnpm test:integration
```

To also test local-to-iCloud migration on an iCloud-enabled, correctly provisioned host:

```bash
KEYCHAIN_STORE_INTEGRATION_ICLOUD=1 pnpm test:integration
```

To allow the fixture to show user-presence prompts for both operation authentication and persistent
item access control:

```bash
KEYCHAIN_STORE_INTEGRATION_INTERACTIVE=1 pnpm test:integration
```

Those two suites are opt-in because they require real user interaction and account/hardware setup.
