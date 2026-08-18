import Foundation
import LocalAuthentication
import Security

private let secretByteCount = 32
private let valuePolicyPrefix = "keychain-store/v1:secure-value-access-control="
private let authenticationReason = "Access protected application data"

// @swift-node:codable
struct SecretTarget: Codable {
  let accessGroup: String?
  let account: String
  let itemAccessControl: String
  let keychainService: String?
  let operationAuthentication: String
  let iCloudSync: Bool

  func withSynchronization(_ iCloudSync: Bool) -> SecretTarget {
    SecretTarget(
      accessGroup: accessGroup,
      account: account,
      itemAccessControl: itemAccessControl,
      keychainService: keychainService,
      operationAuthentication: operationAuthentication,
      iCloudSync: iCloudSync,
    )
  }
}

private enum OperationAuthentication: String {
  case biometricsOnly = "biometrics-only"
  case none
  case userPresence = "user-presence"
}

private enum ItemAccessControl: String {
  case biometricsOnly = "biometrics-only"
  case none
  case userPresence = "user-presence"

  // Keep the marker compatible with items created before the public API name
  // changed from `biometry-any` to `biometrics-only`.
  var policyMarkerValue: String {
    self == .biometricsOnly ? "biometry-any" : rawValue
  }
}

private struct StructuredFailure: LocalizedError {
  let message: String
  let osStatus: OSStatus?
  let stage: String

  var errorDescription: String? {
    message
  }
}

#if !KEYCHAIN_STORE_SWIFT_PACKAGE
  extension StructuredFailure: SwiftNodeStructuredError {
    var code: String {
      stage
    }

    var details: [String: SwiftNodeJSONValue] {
      guard let osStatus else {
        return [:]
      }
      return ["osStatus": .number(Double(osStatus))]
    }
  }
#endif

private struct SigningIdentity {
  let accessGroups: [String]
  let bundleIdentifier: String?
  let signatureStatus: OSStatus?
  let teamId: String?
}

private enum AttributesResult {
  case authenticationRequired
  case failure(OSStatus)
  case missing
  case success([String: Any])
}

private enum DataResult {
  case failure(OSStatus)
  case missing
  case success(Data)
}

private enum CreateResult {
  case alreadyExists
  case failure(OSStatus)
  case success
}

private func keychainMessage(_ status: OSStatus) -> String {
  SecCopyErrorMessageString(status, nil) as String?
    ?? "Keychain operation failed with OSStatus \(status)"
}

private func failure(_ stage: String, _ message: String, osStatus: OSStatus? = nil)
  -> StructuredFailure
{
  StructuredFailure(message: message, osStatus: osStatus, stage: stage)
}

private func json(_ payload: [String: Any]) -> String {
  guard
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
    let encoded = String(data: data, encoding: .utf8)
  else {
    return #"{"status":"missing"}"#
  }
  return encoded
}

private func validateTarget(_ target: SecretTarget) throws -> (
  ItemAccessControl, OperationAuthentication
) {
  if let keychainService = target.keychainService {
    guard !keychainService.isEmpty else {
      throw failure("configuration_invalid", "keychainService must not be empty")
    }
  }
  guard !target.account.isEmpty else {
    throw failure("configuration_invalid", "Keychain account must not be empty")
  }
  guard let itemAccessControl = ItemAccessControl(rawValue: target.itemAccessControl) else {
    throw failure("configuration_invalid", "Unsupported item access-control policy")
  }
  guard
    let operationAuthentication = OperationAuthentication(rawValue: target.operationAuthentication)
  else {
    throw failure("configuration_invalid", "Unsupported operation-authentication policy")
  }
  guard itemAccessControl == .none || operationAuthentication == .none else {
    throw failure(
      "configuration_invalid",
      "Operation authentication and item access control cannot be combined",
    )
  }
  return (itemAccessControl, operationAuthentication)
}

private func readSigningIdentity() -> SigningIdentity {
  var dynamicCode: SecCode?
  let selfStatus = SecCodeCopySelf(SecCSFlags(), &dynamicCode)
  guard selfStatus == errSecSuccess, let dynamicCode else {
    return SigningIdentity(
      accessGroups: [],
      bundleIdentifier: nil,
      signatureStatus: selfStatus,
      teamId: nil,
    )
  }

  let validityStatus = SecCodeCheckValidity(dynamicCode, SecCSFlags(), nil)
  guard validityStatus == errSecSuccess else {
    return SigningIdentity(
      accessGroups: [],
      bundleIdentifier: nil,
      signatureStatus: validityStatus,
      teamId: nil,
    )
  }

  var staticCode: SecStaticCode?
  let staticStatus = SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode)
  guard staticStatus == errSecSuccess, let staticCode else {
    return SigningIdentity(
      accessGroups: [],
      bundleIdentifier: nil,
      signatureStatus: staticStatus,
      teamId: nil,
    )
  }

  var signingInformation: CFDictionary?
  let informationStatus = SecCodeCopySigningInformation(
    staticCode,
    SecCSFlags(rawValue: kSecCSSigningInformation),
    &signingInformation,
  )
  guard
    informationStatus == errSecSuccess,
    let information = signingInformation as? [String: Any]
  else {
    return SigningIdentity(
      accessGroups: [],
      bundleIdentifier: nil,
      signatureStatus: informationStatus,
      teamId: nil,
    )
  }

  let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
  let accessGroups = entitlements?["keychain-access-groups"] as? [String] ?? []

  return SigningIdentity(
    accessGroups: accessGroups.sorted(),
    bundleIdentifier: information[kSecCodeInfoIdentifier as String] as? String,
    signatureStatus: nil,
    teamId: information[kSecCodeInfoTeamIdentifier as String] as? String,
  )
}

private func requireValidHost() throws -> SigningIdentity {
  let identity = readSigningIdentity()
  if let signatureStatus = identity.signatureStatus {
    throw failure(
      "host_identity_invalid",
      "The running host does not have a valid code signature (OSStatus \(signatureStatus))",
    )
  }
  guard let bundleIdentifier = identity.bundleIdentifier, !bundleIdentifier.isEmpty else {
    throw failure(
      "host_identity_invalid",
      "The running host does not have a bundle identifier in its code signature",
    )
  }
  return identity
}

private func resolveTarget(_ target: SecretTarget) throws -> SecretTarget {
  let identity = try requireValidHost()

  guard let configuredService = target.keychainService else {
    guard let bundleIdentifier = identity.bundleIdentifier else {
      throw failure("host_identity_invalid", "The running host has no bundle identifier")
    }
    return SecretTarget(
      accessGroup: nil,
      account: target.account,
      itemAccessControl: target.itemAccessControl,
      keychainService: bundleIdentifier,
      operationAuthentication: target.operationAuthentication,
      iCloudSync: target.iCloudSync,
    )
  }

  guard let teamId = identity.teamId, !teamId.isEmpty else {
    throw failure("host_identity_invalid", "The running host does not have a Team ID")
  }
  let accessGroup = "\(teamId).\(configuredService)"
  guard identity.accessGroups.contains(accessGroup) else {
    throw failure(
      "host_identity_invalid",
      "The running host is not entitled for Keychain access group \(accessGroup)",
    )
  }
  return SecretTarget(
    accessGroup: accessGroup,
    account: target.account,
    itemAccessControl: target.itemAccessControl,
    keychainService: configuredService,
    operationAuthentication: target.operationAuthentication,
    iCloudSync: target.iCloudSync,
  )
}

private func authenticate(_ mode: OperationAuthentication) async throws {
  guard mode != .none else { return }

  let context = LAContext()
  let policy: LAPolicy =
    mode == .biometricsOnly
    ? .deviceOwnerAuthenticationWithBiometrics
    : .deviceOwnerAuthentication
  var evaluationError: NSError?
  guard context.canEvaluatePolicy(policy, error: &evaluationError) else {
    throw failure(
      "operation_authentication_unavailable",
      evaluationError?.localizedDescription ?? "The configured authentication policy is unavailable",
    )
  }

  do {
    let succeeded = try await context.evaluatePolicy(policy, localizedReason: authenticationReason)
    guard succeeded else {
      throw failure("operation_authentication_failed", "Authentication was not successful")
    }
  } catch let structured as StructuredFailure {
    throw structured
  } catch {
    throw failure("operation_authentication_failed", error.localizedDescription)
  }
}

private func makeAuthenticationContext(interactionNotAllowed: Bool) -> LAContext {
  let context = LAContext()
  context.localizedReason = authenticationReason
  context.interactionNotAllowed = interactionNotAllowed
  return context
}

private func secretAuthenticationContext(_ policy: ItemAccessControl) -> LAContext? {
  guard policy != .none else { return nil }
  return makeAuthenticationContext(interactionNotAllowed: false)
}

private func baseQuery(_ target: SecretTarget) -> [CFString: Any] {
  guard let keychainService = target.keychainService else {
    preconditionFailure("Keychain target must be resolved before use")
  }
  var query: [CFString: Any] = [
    kSecAttrAccount: target.account,
    kSecAttrService: keychainService,
    kSecAttrSynchronizable: target.iCloudSync,
    kSecClass: kSecClassGenericPassword,
    kSecUseDataProtectionKeychain: true,
  ]
  if let accessGroup = target.accessGroup {
    query[kSecAttrAccessGroup] = accessGroup
  }
  return query
}

private func readAttributes(
  _ target: SecretTarget,
  context: LAContext?,
) -> AttributesResult {
  var query = baseQuery(target)
  query[kSecMatchLimit] = kSecMatchLimitOne
  query[kSecReturnAttributes] = true
  if let context {
    query[kSecUseAuthenticationContext] = context
  }

  var result: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &result)
  switch status {
  case errSecSuccess:
    guard let attributes = result as? [String: Any] else {
      return .failure(errSecDecode)
    }
    return .success(attributes)
  case errSecItemNotFound:
    return .missing
  case errSecInteractionNotAllowed, errSecAuthFailed:
    return .authenticationRequired
  default:
    return .failure(status)
  }
}

private func readData(_ target: SecretTarget, context: LAContext?) -> DataResult {
  var query = baseQuery(target)
  query[kSecMatchLimit] = kSecMatchLimitOne
  query[kSecReturnData] = true
  if let context {
    query[kSecUseAuthenticationContext] = context
  }

  var result: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &result)
  switch status {
  case errSecSuccess:
    guard let data = result as? Data else {
      return .failure(errSecDecode)
    }
    return .success(data)
  case errSecItemNotFound:
    return .missing
  default:
    return .failure(status)
  }
}

private func expectedPolicyMarker(_ policy: ItemAccessControl, iCloudSync: Bool) -> String {
  valuePolicyPrefix + policy.policyMarkerValue + (iCloudSync ? ":icloud" : "")
}

private func requireExpectedPolicy(
  _ attributes: [String: Any],
  policy: ItemAccessControl,
  target: SecretTarget,
) throws {
  guard
    attributes[kSecAttrDescription as String] as? String
      == expectedPolicyMarker(policy, iCloudSync: target.iCloudSync)
  else {
    throw failure(
      "item_policy_mismatch",
      "A Keychain item with this account already exists, but its kind or stored protection does not match the requested configuration. It may have been created with an earlier configuration. To avoid changing or weakening that protection, keychain-store will not read, change, or migrate this item. Reopen it with the configuration used to create it or use a new account.",
    )
  }

  guard
    attributes[kSecAttrAccessible as String] as? String
      == (expectedAccessibility(policy, iCloudSync: target.iCloudSync) as String)
  else {
    throw failure(
      "item_policy_mismatch",
      "A Keychain item with this account already exists, but its accessibility class does not match the requested access-control and iCloud synchronization configuration. To avoid changing or weakening that protection, keychain-store will not read, change, or migrate this item. Reopen it with the configuration used to create it or use a new account.",
    )
  }

  if policy != .none {
    guard
      let accessControl = attributes[kSecAttrAccessControl as String],
      CFGetTypeID(accessControl as CFTypeRef) == SecAccessControlGetTypeID()
    else {
      throw failure(
        "item_policy_mismatch",
        "A Keychain item with this account already exists, but it is missing the requested access-control metadata. To avoid changing or weakening that protection, keychain-store will not read, change, or migrate this item. Reopen it with the configuration used to create it or use a new account.",
      )
    }
  }
}

private func expectedAccessibility(
  _ policy: ItemAccessControl,
  iCloudSync: Bool,
) -> CFString {
  switch policy {
  case .none:
    return iCloudSync
      ? kSecAttrAccessibleAfterFirstUnlock
      : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
  case .biometricsOnly:
    return iCloudSync
      ? kSecAttrAccessibleWhenUnlocked
      : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  case .userPresence:
    return iCloudSync
      ? kSecAttrAccessibleWhenUnlocked
      : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  }
}

private func readExistingData(
  _ target: SecretTarget,
  policy: ItemAccessControl,
  context: LAContext? = nil,
) throws -> DataResult {
  var attributesWereValidated = false
  switch readAttributes(target, context: makeAuthenticationContext(interactionNotAllowed: true)) {
  case .authenticationRequired:
    if policy == .none {
      return .failure(errSecInteractionNotAllowed)
    }
  case .failure(let status):
    return .failure(status)
  case .missing:
    return .missing
  case .success(let attributes):
    try requireExpectedPolicy(attributes, policy: policy, target: target)
    attributesWereValidated = true
  }

  let authenticationContext = context ?? secretAuthenticationContext(policy)
  let result = readData(target, context: authenticationContext)
  guard case .success = result, !attributesWereValidated else { return result }

  switch readAttributes(target, context: authenticationContext) {
  case .authenticationRequired:
    return .failure(errSecInteractionNotAllowed)
  case .failure(let status):
    return .failure(status)
  case .missing:
    return .missing
  case .success(let attributes):
    try requireExpectedPolicy(attributes, policy: policy, target: target)
    return result
  }
}

private func hasOppositeSynchronizationItem(
  _ target: SecretTarget,
  policy: ItemAccessControl,
) throws -> Bool {
  let oppositeTarget = target.withSynchronization(!target.iCloudSync)
  let context = makeAuthenticationContext(interactionNotAllowed: true)
  switch readAttributes(oppositeTarget, context: context) {
  case .authenticationRequired:
    return true
  case .failure(let status):
    throw failure(
      "synchronization_migration_check_failed",
      keychainMessage(status),
      osStatus: status,
    )
  case .missing:
    return false
  case .success(let attributes):
    try requireExpectedPolicy(attributes, policy: policy, target: oppositeTarget)
    return true
  }
}

private func synchronizationMigrationRequired() throws -> Never {
  throw failure(
    "synchronization_migration_required",
    "The configured Keychain item exists with the opposite iCloud synchronization setting; call getOrCreate() to copy it or set() to write it in the configured scope",
  )
}

private func migrateItemData(
  _ data: Data,
  to target: SecretTarget,
  policy: ItemAccessControl,
) throws -> Data {
  switch try create(target, policy: policy, data: data) {
  case .failure(let status):
    throw failure(
      "synchronization_migration_create_failed",
      keychainMessage(status),
      osStatus: status,
    )
  case .alreadyExists, .success:
    break
  }

  switch try readExistingData(target, policy: policy) {
  case .failure(let status):
    throw failure(
      "synchronization_migration_verify_failed",
      keychainMessage(status),
      osStatus: status,
    )
  case .missing:
    throw failure(
      "synchronization_migration_verify_failed",
      keychainMessage(errSecItemNotFound),
      osStatus: errSecItemNotFound,
    )
  case .success(let destination):
    guard destination == data else {
      throw failure(
        "synchronization_migration_conflict",
        "The Keychain item created concurrently has different bytes",
        osStatus: errSecDecode,
      )
    }
    return destination
  }
}

private func randomSecret() throws -> Data {
  var bytes = [UInt8](repeating: 0, count: secretByteCount)
  let status = bytes.withUnsafeMutableBytes { buffer in
    guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
    return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
  }
  guard status == errSecSuccess else {
    throw failure(
      "random_generation_failed",
      keychainMessage(status),
      osStatus: status,
    )
  }
  return Data(bytes)
}

private func create(
  _ target: SecretTarget,
  policy: ItemAccessControl,
  data: Data,
) throws -> CreateResult {
  var attributes = baseQuery(target)
  attributes[kSecAttrDescription] = expectedPolicyMarker(policy, iCloudSync: target.iCloudSync)
  attributes[kSecValueData] = data

  switch policy {
  case .none:
    attributes[kSecAttrAccessible] = expectedAccessibility(
      policy,
      iCloudSync: target.iCloudSync,
    )
  case .biometricsOnly, .userPresence:
    let accessControlFlag: SecAccessControlCreateFlags =
      policy == .biometricsOnly ? .biometryAny : .userPresence
    var accessControlError: Unmanaged<CFError>?
    guard
      let accessControl = SecAccessControlCreateWithFlags(
        nil,
        expectedAccessibility(policy, iCloudSync: target.iCloudSync),
        accessControlFlag,
        &accessControlError,
      )
    else {
      let message =
        accessControlError?.takeRetainedValue().localizedDescription
        ?? "Could not create the Keychain item access-control policy"
      throw failure("item_access_control_failed", message)
    }
    attributes[kSecAttrAccessControl] = accessControl
  }

  let status = SecItemAdd(attributes as CFDictionary, nil)
  switch status {
  case errSecSuccess:
    return .success
  case errSecDuplicateItem:
    return .alreadyExists
  default:
    return .failure(status)
  }
}

private func updateData(_ target: SecretTarget, data: Data, context: LAContext?) -> OSStatus {
  var query = baseQuery(target)
  if let context {
    query[kSecUseAuthenticationContext] = context
  }
  return SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
}

private func deleteData(_ target: SecretTarget, context: LAContext?) -> OSStatus {
  var query = baseQuery(target)
  if let context {
    query[kSecUseAuthenticationContext] = context
  }
  return SecItemDelete(query as CFDictionary)
}

private func throwReadFailure(_ stage: String, status: OSStatus) throws -> Never {
  throw failure(stage, keychainMessage(status), osStatus: status)
}

private func itemStatus(_ target: SecretTarget, policy: ItemAccessControl) throws -> String {
  let context = makeAuthenticationContext(interactionNotAllowed: true)
  switch readAttributes(target, context: context) {
  case .authenticationRequired:
    return "requires-authentication"
  case .failure(let status):
    try throwReadFailure("status_failed", status: status)
  case .missing:
    return try hasOppositeSynchronizationItem(target, policy: policy)
      ? "synchronization-migration-required"
      : "missing"
  case .success(let attributes):
    try requireExpectedPolicy(attributes, policy: policy, target: target)
    return policy == .none ? "available" : "requires-authentication"
  }
}

private func readItemData(_ target: SecretTarget, policy: ItemAccessControl) throws -> Data {
  switch try readExistingData(target, policy: policy) {
  case .failure(let status):
    try throwReadFailure("item_read_failed", status: status)
  case .missing:
    if try hasOppositeSynchronizationItem(target, policy: policy) {
      try synchronizationMigrationRequired()
    }
    throw failure(
      "item_missing", "The configured Keychain item does not exist", osStatus: errSecItemNotFound)
  case .success(let data):
    return data
  }
}

private func ensureItemData(
  target: SecretTarget,
  policy: ItemAccessControl,
  initialValue: Data,
) throws -> Data {
  switch try readExistingData(target, policy: policy) {
  case .failure(let status):
    try throwReadFailure("item_read_failed", status: status)
  case .success(let data):
    return data
  case .missing:
    break
  }

  let oppositeTarget = target.withSynchronization(!target.iCloudSync)
  switch try readExistingData(oppositeTarget, policy: policy) {
  case .failure(let status):
    try throwReadFailure("synchronization_migration_read_failed", status: status)
  case .missing:
    break
  case .success(let data):
    return try migrateItemData(data, to: target, policy: policy)
  }

  switch try create(target, policy: policy, data: initialValue) {
  case .failure(let status):
    throw failure("item_create_failed", keychainMessage(status), osStatus: status)
  case .alreadyExists, .success:
    break
  }

  switch try readExistingData(target, policy: policy) {
  case .failure(let status):
    try throwReadFailure("item_verify_failed", status: status)
  case .missing:
    throw failure(
      "item_verify_failed",
      keychainMessage(errSecItemNotFound),
      osStatus: errSecItemNotFound,
    )
  case .success(let data):
    return data
  }
}

private func writeItemData(
  _ target: SecretTarget,
  policy: ItemAccessControl,
  value: Data,
) throws {
  let context = secretAuthenticationContext(policy)
  switch try readExistingData(target, policy: policy, context: context) {
  case .failure(let status):
    try throwReadFailure("item_write_failed", status: status)
  case .success:
    let status = updateData(target, data: value, context: context)
    guard status == errSecSuccess else {
      throw failure("item_write_failed", keychainMessage(status), osStatus: status)
    }
    return
  case .missing:
    break
  }

  // A write is authoritative for the configured synchronization scope. Still
  // validate an opposite-scope item so a protection mismatch is never ignored.
  _ = try hasOppositeSynchronizationItem(target, policy: policy)

  switch try create(target, policy: policy, data: value) {
  case .failure(let status):
    throw failure("item_create_failed", keychainMessage(status), osStatus: status)
  case .success:
    return
  case .alreadyExists:
    break
  }

  switch try readExistingData(target, policy: policy, context: context) {
  case .failure(let status):
    try throwReadFailure("item_write_failed", status: status)
  case .missing:
    throw failure(
      "item_write_failed",
      keychainMessage(errSecItemNotFound),
      osStatus: errSecItemNotFound,
    )
  case .success:
    let status = updateData(target, data: value, context: context)
    guard status == errSecSuccess else {
      throw failure("item_write_failed", keychainMessage(status), osStatus: status)
    }
  }
}

private func deleteItemData(_ target: SecretTarget, policy: ItemAccessControl) throws -> Bool {
  let context = secretAuthenticationContext(policy)
  switch try readExistingData(target, policy: policy, context: context) {
  case .failure(let status):
    try throwReadFailure("item_delete_failed", status: status)
  case .missing:
    return false
  case .success:
    break
  }

  let status = deleteData(target, context: context)
  switch status {
  case errSecSuccess:
    return true
  case errSecItemNotFound:
    return false
  default:
    throw failure("item_delete_failed", keychainMessage(status), osStatus: status)
  }
}

// @swift-node:export
func secretStatus(_ input: SecretTarget) async throws -> String {
  let (itemAccessControl, _) = try validateTarget(input)
  let target = try resolveTarget(input)
  return json(["status": try itemStatus(target, policy: itemAccessControl)])
}

private func ensureItemData(_ input: SecretTarget, initialValue: Data) async throws -> Data {
  let (itemAccessControl, operationAuthentication) = try validateTarget(input)
  let target = try resolveTarget(input)
  try await authenticate(operationAuthentication)
  return try ensureItemData(
    target: target,
    policy: itemAccessControl,
    initialValue: initialValue,
  )
}

// @swift-node:export
func readItem(_ input: SecretTarget) async throws -> Data {
  let (itemAccessControl, operationAuthentication) = try validateTarget(input)
  let target = try resolveTarget(input)
  try await authenticate(operationAuthentication)
  return try readItemData(target, policy: itemAccessControl)
}

// @swift-node:export
func ensureRandomItem(_ target: SecretTarget) async throws -> Data {
  try await ensureItemData(target, initialValue: randomSecret())
}

// @swift-node:export
func ensureItem(_ target: SecretTarget, _ initialValue: Data) async throws -> Data {
  try await ensureItemData(target, initialValue: initialValue)
}

// @swift-node:export
func writeItem(_ input: SecretTarget, _ value: Data) async throws {
  let (itemAccessControl, operationAuthentication) = try validateTarget(input)
  let target = try resolveTarget(input)
  try await authenticate(operationAuthentication)
  try writeItemData(target, policy: itemAccessControl, value: value)
}

// @swift-node:export
func deleteItem(_ input: SecretTarget) async throws -> Bool {
  let (itemAccessControl, operationAuthentication) = try validateTarget(input)
  let target = try resolveTarget(input)
  try await authenticate(operationAuthentication)
  return try deleteItemData(target, policy: itemAccessControl)
}

// MARK: - Swift package API

/// A policy applied either to a stored Keychain item or to an operation
/// performed by this process.
public enum KeychainStoreSwiftAuthenticationPolicy: String, Sendable {
  case biometricsOnly = "biometrics-only"
  case userPresence = "user-presence"
}

/// Selects the single authentication boundary for a Swift store.
public enum KeychainStoreSwiftAuthentication: Sendable {
  case accessControl(KeychainStoreSwiftAuthenticationPolicy)
  case none
  case operationAuth(KeychainStoreSwiftAuthenticationPolicy)
}

/// Metadata-only state for one declared Swift store account.
public enum KeychainStoreSwiftStatus: String, Sendable {
  case available
  case missing
  case requiresAuthentication = "requires-authentication"
  case synchronizationMigrationRequired = "synchronization-migration-required"
}

private struct KeychainStoreSwiftStorage: Sendable {
  private let authentication: KeychainStoreSwiftAuthentication
  private let iCloudSync: Bool
  private let keychainService: String?
  private let accounts: Set<String>
  private let mutableAccounts: Set<String>

  init(
    accounts: [String],
    authentication: KeychainStoreSwiftAuthentication,
    iCloudSync: Bool,
    keychainService: String?,
    mutableAccounts: [String],
  ) throws {
    if let keychainService {
      guard !keychainService.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw failure("configuration_invalid", "keychainService must not be empty")
      }
    }

    var declaredAccounts: Set<String> = []
    for account in accounts {
      guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw failure("configuration_invalid", "Keychain account must not be empty")
      }
      guard account == account.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw failure(
          "configuration_invalid",
          "Keychain account must not have surrounding whitespace",
        )
      }
      guard declaredAccounts.insert(account).inserted else {
        throw failure("configuration_invalid", "Keychain account appears more than once")
      }
    }
    var declaredMutableAccounts: Set<String> = []
    for account in mutableAccounts {
      guard !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw failure("configuration_invalid", "Mutable Keychain account must not be empty")
      }
      guard account == account.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw failure(
          "configuration_invalid",
          "Mutable Keychain account must not have surrounding whitespace",
        )
      }
      guard declaredMutableAccounts.insert(account).inserted else {
        throw failure("configuration_invalid", "Mutable Keychain account appears more than once")
      }
      guard !declaredAccounts.contains(account) else {
        throw failure(
          "configuration_invalid", "Keychain account cannot be both immutable and mutable")
      }
      declaredAccounts.insert(account)
    }
    guard !declaredAccounts.isEmpty else {
      throw failure("configuration_invalid", "Declare at least one Keychain account")
    }
    self.authentication = authentication
    self.iCloudSync = iCloudSync
    self.keychainService = keychainService
    self.accounts = declaredAccounts
    self.mutableAccounts = declaredMutableAccounts
  }

  func target(for account: String) throws -> SecretTarget {
    guard accounts.contains(account) else {
      throw failure("configuration_invalid", "Keychain account is not configured")
    }

    let itemAccessControl: String
    let operationAuthentication: String
    switch authentication {
    case .accessControl(let policy):
      itemAccessControl = policy.rawValue
      operationAuthentication = OperationAuthentication.none.rawValue
    case .none:
      itemAccessControl = ItemAccessControl.none.rawValue
      operationAuthentication = OperationAuthentication.none.rawValue
    case .operationAuth(let policy):
      itemAccessControl = ItemAccessControl.none.rawValue
      operationAuthentication = policy.rawValue
    }

    return SecretTarget(
      accessGroup: nil,
      account: account,
      itemAccessControl: itemAccessControl,
      keychainService: keychainService,
      operationAuthentication: operationAuthentication,
      iCloudSync: iCloudSync,
    )
  }

  func mutableTarget(for account: String) throws -> SecretTarget {
    let target = try target(for: account)
    guard mutableAccounts.contains(account) else {
      throw failure("configuration_invalid", "Keychain account is immutable")
    }
    return target
  }
}

/// A Data Protection Keychain store for use from a signed native macOS target.
/// It shares item policy and storage format with the Node package API, but
/// keeps item bytes inside native code unless the caller explicitly requests
/// them.
public struct KeychainStoreSwift: Sendable {
  private let storage: KeychainStoreSwiftStorage

  public init(
    accounts: [String] = [],
    authentication: KeychainStoreSwiftAuthentication = .none,
    iCloudSync: Bool = false,
    keychainService: String? = nil,
    mutableAccounts: [String] = [],
  ) throws {
    storage = try KeychainStoreSwiftStorage(
      accounts: accounts,
      authentication: authentication,
      iCloudSync: iCloudSync,
      keychainService: keychainService,
      mutableAccounts: mutableAccounts,
    )
  }

  /// Returns a copy of the account's bytes, or `nil` when it is absent.
  public func get(_ account: String) async throws -> Data? {
    do {
      return try await readItem(storage.target(for: account))
    } catch let error as StructuredFailure where error.stage == "item_missing" {
      return nil
    }
  }

  /// Returns existing bytes or add-only creates the supplied bytes.
  public func getOrCreate(_ account: String, initialValue: Data) async throws -> Data {
    try await ensureItem(storage.target(for: account), initialValue)
  }

  /// Returns existing bytes or add-only creates 32 random bytes.
  public func getOrCreate(_ account: String) async throws -> Data {
    try await ensureRandomItem(storage.target(for: account))
  }

  /// Ensures an item exists without returning its bytes to the caller.
  public func ensure(_ account: String, initialValue: Data? = nil) async throws {
    if let initialValue {
      _ = try await ensureItem(storage.target(for: account), initialValue)
    } else {
      _ = try await ensureRandomItem(storage.target(for: account))
    }
  }

  /// Creates or replaces bytes in one mutable declared account.
  public func set(_ account: String, value: Data) async throws {
    try await writeItem(try storage.mutableTarget(for: account), value)
  }

  /// Removes one mutable declared account and reports whether it existed.
  public func remove(_ account: String) async throws -> Bool {
    try await deleteItem(try storage.mutableTarget(for: account))
  }

  /// Checks one declared account without returning bytes or prompting.
  public func status(_ account: String) async throws -> KeychainStoreSwiftStatus {
    let input = try storage.target(for: account)
    let (itemAccessControl, _) = try validateTarget(input)
    let target = try resolveTarget(input)
    let rawStatus = try itemStatus(target, policy: itemAccessControl)
    guard let status = KeychainStoreSwiftStatus(rawValue: rawStatus) else {
      throw failure("status_failed", "The Keychain status response was invalid")
    }
    return status
  }

}

/// A synchronous Data Protection Keychain store for native code that cannot
/// suspend. It accepts only `authentication: .none`, so its operations never
/// trigger a LocalAuthentication prompt and may block the calling thread.
public struct KeychainStoreSwiftSync: Sendable {
  private let storage: KeychainStoreSwiftStorage

  public init(
    accounts: [String] = [],
    iCloudSync: Bool = false,
    keychainService: String? = nil,
    mutableAccounts: [String] = [],
  ) throws {
    storage = try KeychainStoreSwiftStorage(
      accounts: accounts,
      authentication: .none,
      iCloudSync: iCloudSync,
      keychainService: keychainService,
      mutableAccounts: mutableAccounts,
    )
  }

  /// Returns a copy of the account's bytes, or `nil` when it is absent.
  public func get(_ account: String) throws -> Data? {
    let target = try target(for: account)
    switch try readExistingData(target, policy: .none) {
    case .failure(let status):
      try throwReadFailure("item_read_failed", status: status)
    case .missing:
      if try hasOppositeSynchronizationItem(target, policy: .none) {
        try synchronizationMigrationRequired()
      }
      return nil
    case .success(let data):
      return data
    }
  }

  /// Returns existing bytes or add-only creates the supplied bytes.
  public func getOrCreate(_ account: String, initialValue: Data) throws -> Data {
    try ensureItemData(
      target: target(for: account),
      policy: .none,
      initialValue: initialValue,
    )
  }

  /// Returns existing bytes or add-only creates 32 random bytes.
  public func getOrCreate(_ account: String) throws -> Data {
    try ensureItemData(
      target: target(for: account),
      policy: .none,
      initialValue: randomSecret(),
    )
  }

  /// Ensures an item exists without returning its bytes to the caller.
  public func ensure(_ account: String, initialValue: Data? = nil) throws {
    if let initialValue {
      _ = try ensureItemData(
        target: target(for: account),
        policy: .none,
        initialValue: initialValue,
      )
    } else {
      _ = try ensureItemData(
        target: target(for: account),
        policy: .none,
        initialValue: randomSecret(),
      )
    }
  }

  /// Creates or replaces bytes in one mutable declared account.
  public func set(_ account: String, value: Data) throws {
    try writeItemData(
      try resolveTarget(storage.mutableTarget(for: account)),
      policy: .none,
      value: value,
    )
  }

  /// Removes one mutable declared account and reports whether it existed.
  public func remove(_ account: String) throws -> Bool {
    try deleteItemData(try resolveTarget(storage.mutableTarget(for: account)), policy: .none)
  }

  /// Checks one declared account without returning bytes or prompting.
  public func status(_ account: String) throws -> KeychainStoreSwiftStatus {
    let target = try target(for: account)
    guard let status = KeychainStoreSwiftStatus(rawValue: try itemStatus(target, policy: .none))
    else {
      throw failure("status_failed", "The Keychain status response was invalid")
    }
    return status
  }

  private func target(for account: String) throws -> SecretTarget {
    try resolveTarget(storage.target(for: account))
  }
}
