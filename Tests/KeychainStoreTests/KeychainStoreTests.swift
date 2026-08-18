import XCTest

@testable import KeychainStore

final class KeychainStoreTests: XCTestCase {
  func testAccountsAreImmutableByDefault() async throws {
    let store = try KeychainStoreSwift(accounts: ["desktop-token"])

    do {
      try await store.set("desktop-token", value: Data())
      XCTFail("Expected an undeclared mutable account to be rejected")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Keychain account is immutable")
    }
  }

  func testAllowsMutableAccountsWithoutImmutableAccounts() {
    XCTAssertNoThrow(try KeychainStoreSwift(mutableAccounts: ["desktop-token"]))
  }

  func testRejectsAnAccountDeclaredAsBothImmutableAndMutable() {
    XCTAssertThrowsError(
      try KeychainStoreSwift(
        accounts: ["desktop-token"],
        mutableAccounts: ["desktop-token"],
      ))
  }

  func testAsynchronousStoreSupportsAuthenticationPolicies() {
    XCTAssertNoThrow(
      try KeychainStoreSwift(
        accounts: ["desktop-token"],
        authentication: .accessControl(.userPresence),
      ))
    XCTAssertNoThrow(
      try KeychainStoreSwift(
        accounts: ["desktop-token"],
        authentication: .operationAuth(.biometricsOnly),
      ))
  }

  func testSynchronousStoreOperationsDoNotRequireAsyncContext() throws {
    let store = try KeychainStoreSwiftSync(accounts: ["desktop-token"])

    let get: (String) throws -> Data? = store.get
    let getOrCreateRandom: (String) throws -> Data = store.getOrCreate
    let getOrCreateValue: (String, Data) throws -> Data = store.getOrCreate
    let ensure: (String, Data?) throws -> Void = store.ensure
    let set: (String, Data) throws -> Void = { account, value in
      try store.set(account, value: value)
    }
    let remove: (String) throws -> Bool = store.remove
    let status: (String) throws -> KeychainStoreSwiftStatus = store.status

    _ = (get, getOrCreateRandom, getOrCreateValue, ensure, set, remove, status)
  }

  func testSynchronousStoreEnforcesDeclaredAccountsBeforeAccessingKeychain() throws {
    let store = try KeychainStoreSwiftSync(
      accounts: ["database-key"],
      mutableAccounts: ["desktop-token"],
    )

    XCTAssertThrowsError(try store.get("not-configured"))
    XCTAssertThrowsError(try store.set("database-key", value: Data()))
    XCTAssertThrowsError(try store.remove("database-key"))
  }
}
