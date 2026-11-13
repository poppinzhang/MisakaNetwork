// Metadata-only helper for the LastOrder cleanup script. Never requests password data.
// Compile with LASTORDER_CLEANUP_TESTING to exercise pure classification without
// opening or changing a keychain. The normal executable accepts one JSON request
// on stdin and emits only aggregate counts on stdout.
import Foundation
import Security
import Darwin

enum LastOrderKeychainOwnership: Equatable {
    case lastOrder
    case anotherApplication
    case unknown
}

enum LastOrderKeychainDecision: Equatable {
    case remove
    case ignore
    case ambiguous
}

let lastOrderBundleIdentifier = "io.misakanetwork.lastOrder"
let lastOrderLegacyService = "flutter_secure_storage_service"
let lastOrderVaultService = "MisakaNetwork.LastOrder.vault"
let lastOrderMasterAccount = "macos.vault.master.v1"
let lastOrderIntegrationLabel = "LastOrder synthetic storage test"

func isLastOrderLegacyCandidate(_ account: String) -> Bool {
    if ["v2.cloud.preview.v1", "v2.cloud.ssh-identity.v1"].contains(account) {
        return true
    }
    return ["v2.account.", "v2.task.", "account.", "task."].contains {
        account.hasPrefix($0) && account.count > $0.count
    }
}

func isLastOrderIntegrationService(_ service: String) -> Bool {
    let prefix = "MisakaNetwork.LastOrder.integration."
    guard service.hasPrefix(prefix) else { return false }
    return UUID(uuidString: String(service.dropFirst(prefix.count))) != nil
}

// Cloud keys deliberately require ACL evidence. They are constant names in a
// shared service, unlike IDs obtained from LastOrder's own saved state.
func classifyLastOrderKeychainItem(
    service: String,
    account: String,
    label: String?,
    savedAccounts: Set<String>,
    ownership: LastOrderKeychainOwnership
) -> LastOrderKeychainDecision {
    if service == lastOrderVaultService {
        return account == lastOrderMasterAccount ? .remove : .ignore
    }
    if isLastOrderIntegrationService(service) {
        return account == lastOrderMasterAccount && label == lastOrderIntegrationLabel
            ? .remove : .ignore
    }
    guard service == lastOrderLegacyService, isLastOrderLegacyCandidate(account) else {
        return .ignore
    }
    let cloud = account == "v2.cloud.preview.v1" || account == "v2.cloud.ssh-identity.v1"
    if !cloud && savedAccounts.contains(account) { return .remove }
    switch ownership {
    case .lastOrder: return .remove
    case .anotherApplication: return .ignore
    case .unknown: return .ambiguous
    }
}

struct LastOrderCleanupRequest: Decodable {
    let accounts: [String]
    let apply: Bool
}

struct LastOrderCleanupSummary: Encodable {
    var deleted = 0
    var matched = 0
    var ambiguous = 0
}

enum LastOrderCleanupError: Error {
    case invalidRequest
    case loginKeychainUnavailable
    case malformedItem
    case operationFailed(api: String, status: OSStatus)
    case verificationFailed

    var diagnostic: String {
        switch self {
        case .invalidRequest: return "Invalid cleanup request."
        case .loginKeychainUnavailable: return "The login keychain is unavailable; no cleanup was started."
        case .malformedItem: return "Unexpected keychain metadata; no cleanup was started."
        case let .operationFailed(api, status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Security framework error"
            return "\(api) failed (OSStatus \(status)): \(message)\n"
                + lastOrderKeychainStatusHint(status)
                + "\n已停止，保留应用数据文件。不要使用 sudo 或先删除数据目录。"
        case .verificationFailed: return "Keychain deletion could not be verified; preserve application files."
        }
    }
}

// Status-only diagnostics never include an item's service, account, or value.
func lastOrderKeychainStatusHint(_ status: OSStatus) -> String {
    switch status {
    case errSecUserCanceled:
        return "系统报告操作被取消；请在本机图形会话中重试并核对钥匙串授权提示。"
    case errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired:
        return "请在钥匙串访问中确认登录钥匙串已解锁，再在本机终端重试并处理系统授权提示。"
    case errSecParam, errSecMissingEntitlement:
        return "请保留此错误码用于排查调用参数或访问权限；不要通过修改钥匙串访问控制绕过。"
    default:
        return "请保留此错误码和系统说明，以便定位失败原因。"
    }
}

func deleteLastOrderKeychainReference(using delete: () -> OSStatus) throws {
    let status = delete()
    guard status == errSecSuccess else {
        throw LastOrderCleanupError.operationFailed(api: "SecKeychainItemDelete", status: status)
    }
}

struct LastOrderKeychainItem {
    let reference: SecKeychainItem
    let persistentReference: Data
    let service: String
    let account: String
    let label: String?
}

// The ACL's trusted-application data is treated conservatively: only an
// absolute UTF-8 path into an existing .app with a readable, regular Info.plist
// provides evidence. Opaque requirements, missing old binaries, and broad ACLs
// remain unknown. Neither labels nor substrings of app paths establish identity.
func bundleIdentifierForTrustedApplication(_ application: SecTrustedApplication) -> String? {
    var value: CFData?
    guard SecTrustedApplicationCopyData(application, &value) == errSecSuccess,
          let data = value as Data? else { return nil }
    var bytes = [UInt8](data)
    while bytes.last == 0 { bytes.removeLast() }
    guard !bytes.contains(0), let path = String(bytes: bytes, encoding: .utf8),
          path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r") else { return nil }
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return nil }
    var bundle = URL(fileURLWithPath: path).standardizedFileURL
    while bundle.path != "/" && bundle.pathExtension != "app" {
        bundle.deleteLastPathComponent()
    }
    guard bundle.pathExtension == "app" else { return nil }
    let info = bundle.appendingPathComponent("Contents/Info.plist")
    guard let attributes = try? fm.attributesOfItem(atPath: info.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
          let raw = try? Data(contentsOf: info),
          let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil),
          let dictionary = plist as? [String: Any] else { return nil }
    return dictionary["CFBundleIdentifier"] as? String
}

func lastOrderOwnershipOfItem(_ item: SecKeychainItem) -> LastOrderKeychainOwnership {
    var access: SecAccess?
    guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return .unknown }
    var list: CFArray?
    guard SecAccessCopyACLList(access, &list) == errSecSuccess,
          let acls = list as? [SecACL] else { return .unknown }
    var foundAnotherApplication = false
    for acl in acls {
        var applications: CFArray?
        var description: CFString?
        var prompt = SecKeychainPromptSelector()
        guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess,
              let trusted = applications as? [SecTrustedApplication] else { continue }
        for application in trusted {
            guard let identifier = bundleIdentifierForTrustedApplication(application) else { continue }
            if identifier == lastOrderBundleIdentifier { return .lastOrder }
            foundAnotherApplication = true
        }
    }
    return foundAnotherApplication ? .anotherApplication : .unknown
}

func queryLastOrderKeychain(
    _ keychain: SecKeychain,
    attributes: [CFString: Any]
) throws -> [LastOrderKeychainItem] {
    var query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecMatchSearchList: [keychain],
        kSecMatchLimit: kSecMatchLimitAll,
        kSecReturnAttributes: true,
        kSecReturnRef: true,
        kSecReturnPersistentRef: true,
        kSecUseDataProtectionKeychain: false,
        kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
    ]
    query.merge(attributes) { _, new in new }
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else {
        throw LastOrderCleanupError.operationFailed(api: "SecItemCopyMatching", status: status)
    }
    guard let rows = result as? [[String: Any]] else { throw LastOrderCleanupError.malformedItem }
    return try rows.map { row in
        guard let service = row[kSecAttrService as String] as? String,
              let account = row[kSecAttrAccount as String] as? String,
              let rawReference = row[kSecValueRef as String],
              CFGetTypeID(rawReference as CFTypeRef) == SecKeychainItemGetTypeID(),
              let persistent = row[kSecValuePersistentRef as String] as? Data else {
            throw LastOrderCleanupError.malformedItem
        }
        return LastOrderKeychainItem(
            reference: rawReference as! SecKeychainItem,
            persistentReference: persistent,
            service: service,
            account: account,
            label: row[kSecAttrLabel as String] as? String
        )
    }
}

func openLastOrderLoginKeychain() throws -> SecKeychain {
    // Ignore HOME and Foundation's environment-derived home directory. The
    // helper may only inspect the invoking user's login keychain.
    guard let account = getpwuid(getuid()), let home = account.pointee.pw_dir else {
        throw LastOrderCleanupError.loginKeychainUnavailable
    }
    let path = URL(fileURLWithPath: String(cString: home))
        .appendingPathComponent("Library/Keychains/login.keychain-db").path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          attributes[.type] as? FileAttributeType == .typeRegular else {
        throw LastOrderCleanupError.loginKeychainUnavailable
    }
    var keychain: SecKeychain?
    let status = SecKeychainOpen(path, &keychain)
    guard status == errSecSuccess else {
        throw LastOrderCleanupError.operationFailed(api: "SecKeychainOpen", status: status)
    }
    guard let keychain else {
        throw LastOrderCleanupError.loginKeychainUnavailable
    }
    return keychain
}

func performLastOrderKeychainCleanup(
    request: LastOrderCleanupRequest,
    summary: inout LastOrderCleanupSummary
) throws -> Int32 {
    guard request.accounts.count <= 100_000,
          request.accounts.allSatisfy({ $0.utf8.count <= 1_024 && isLastOrderLegacyCandidate($0) }) else {
        throw LastOrderCleanupError.invalidRequest
    }
    let keychain = try openLastOrderLoginKeychain()
    let savedAccounts = Set(request.accounts)
    let vaultItems = try queryLastOrderKeychain(keychain, attributes: [
        kSecAttrService: lastOrderVaultService,
        kSecAttrAccount: lastOrderMasterAccount,
    ])
    let legacyItems = try queryLastOrderKeychain(keychain, attributes: [
        kSecAttrService: lastOrderLegacyService,
    ])
    let integrationItems = try queryLastOrderKeychain(keychain, attributes: [
        kSecAttrLabel: lastOrderIntegrationLabel,
        kSecAttrAccount: lastOrderMasterAccount,
    ])
    var planned: [LastOrderKeychainItem] = []
    var seen = Set<Data>()
    for item in vaultItems + legacyItems + integrationItems {
        guard seen.insert(item.persistentReference).inserted else { continue }
        let needsOwnership = item.service == lastOrderLegacyService
            && isLastOrderLegacyCandidate(item.account)
            && (!savedAccounts.contains(item.account) || item.account.contains("cloud."))
        let ownership = needsOwnership ? lastOrderOwnershipOfItem(item.reference) : .unknown
        switch classifyLastOrderKeychainItem(
            service: item.service,
            account: item.account,
            label: item.label,
            savedAccounts: savedAccounts,
            ownership: ownership
        ) {
        case .remove: planned.append(item)
        case .ignore: break
        case .ambiguous: summary.ambiguous += 1
        }
    }
    summary.matched = planned.count
    guard request.apply else { return 0 }
    // No keychain changes at all when an old candidate cannot be attributed.
    guard summary.ambiguous == 0 else { return 2 }
    for item in planned {
        do {
            try deleteLastOrderKeychainReference {
                // We explicitly open a file-based login keychain and have
                // already verified ownership. SecItemDelete's legacy wrapper
                // can reject a separate cleanup tool as a different app owner.
                // The classic API deletes this exact reference, still subject
                // to system authorization, without changing its ACL.
                SecKeychainItemDelete(item.reference)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "删除第 \(summary.deleted + 1)/\(summary.matched) 条已确认归属的钥匙串记录时失败。\n".utf8
            ))
            throw error
        }
        summary.deleted += 1
        // Re-enumerate live items by exact metadata instead of querying a
        // deleted reference: traditional Keychain implementations may report
        // an invalid reference rather than item-not-found for the latter.
        let remaining: [LastOrderKeychainItem]
        do {
            remaining = try queryLastOrderKeychain(keychain, attributes: [
                kSecAttrService: item.service,
                kSecAttrAccount: item.account,
            ])
        } catch let error as LastOrderCleanupError {
            // Keep the underlying OSStatus when verification cannot query the
            // keychain. A generic verification failure would hide its cause.
            if case .operationFailed = error { throw error }
            throw LastOrderCleanupError.verificationFailed
        }
        guard !remaining.contains(where: { $0.persistentReference == item.persistentReference }) else {
            throw LastOrderCleanupError.verificationFailed
        }
    }
    return 0
}

#if !LASTORDER_CLEANUP_TESTING
@main
struct LastOrderKeychainCleanupMain {
    static func main() {
        var summary = LastOrderCleanupSummary()
        var code: Int32 = 1
        do {
            let input = FileHandle.standardInput.readData(ofLength: 16_777_217)
            guard input.count <= 16_777_216,
                  let request = try? JSONDecoder().decode(LastOrderCleanupRequest.self, from: input) else {
                throw LastOrderCleanupError.invalidRequest
            }
            code = try performLastOrderKeychainCleanup(request: request, summary: &summary)
            if code == 2 {
                FileHandle.standardError.write(Data("Unattributed legacy keychain items remain; no keychain items were deleted.\n".utf8))
            }
        } catch let error as LastOrderCleanupError {
            FileHandle.standardError.write(Data((error.diagnostic + "\n").utf8))
        } catch {
            FileHandle.standardError.write(Data("Keychain cleanup failed. Preserve application files.\n".utf8))
        }
        if let output = try? JSONEncoder().encode(summary) {
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([10]))
        }
        exit(code)
    }
}
#endif
