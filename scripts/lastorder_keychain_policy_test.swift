// Synthetic policy harness only. Compile alongside lastorder_keychain_cleanup.swift
// with -D LASTORDER_CLEANUP_TESTING; that flag removes the production entry point.
// This file never accesses keychain items, reads user files, or invokes cleanup.
import Foundation
import Security

@main
struct LastOrderKeychainPolicyTest {
    static func main() {
        var checked = 0
        func check(
            _ name: String,
            _ expected: LastOrderKeychainDecision,
            service: String = lastOrderLegacyService,
            account: String = "v2.account.synthetic",
            label: String? = nil,
            saved: Set<String> = [],
            ownership: LastOrderKeychainOwnership = .unknown
        ) {
            let actual = classifyLastOrderKeychainItem(
                service: service,
                account: account,
                label: label,
                savedAccounts: saved,
                ownership: ownership
            )
            guard actual == expected else {
                fatalError("Synthetic policy case failed: \(name)")
            }
            checked += 1
        }

        check("exact vault key", .remove,
              service: lastOrderVaultService, account: lastOrderMasterAccount)
        check("vault service is exact", .ignore,
              service: lastOrderVaultService + ".other", account: lastOrderMasterAccount)
        check("vault account is exact", .ignore,
              service: lastOrderVaultService, account: lastOrderMasterAccount + ".other")
        check("master account in another service", .ignore,
              service: "example.other.app", account: lastOrderMasterAccount)

        check("unknown generic service candidate", .ambiguous)
        check("generic service unrelated preference", .ignore,
              account: "theme", ownership: .lastOrder)
        check("empty candidate suffix", .ignore, account: "v2.account.")
        check("candidate service is exact", .ignore,
              service: lastOrderLegacyService + ".other",
              saved: ["v2.account.synthetic"], ownership: .lastOrder)
        check("metadata exact ID", .remove, saved: ["v2.account.synthetic"])
        check("metadata neighbouring ID", .ambiguous,
              account: "v2.account.synthetic-other", saved: ["v2.account.synthetic"])
        check("metadata account versus task", .ambiguous,
              account: "v2.task.synthetic", saved: ["v2.account.synthetic"])
        check("metadata exact task", .remove,
              account: "v2.task.synthetic", saved: ["v2.task.synthetic"])
        check("legacy account ACL", .remove, account: "account.synthetic", ownership: .lastOrder)
        check("legacy task ACL", .remove, account: "task.synthetic", ownership: .lastOrder)
        check("another application ACL", .ignore, ownership: .anotherApplication)
        check("unknown ACL", .ambiguous, ownership: .unknown)
        check("LastOrder ACL", .remove, ownership: .lastOrder)

        for cloud in ["v2.cloud.preview.v1", "v2.cloud.ssh-identity.v1"] {
            check("cloud whitelist cannot bypass ACL", .ambiguous, account: cloud, saved: [cloud])
            check("cloud LastOrder ACL", .remove, account: cloud, ownership: .lastOrder)
            check("cloud other ACL", .ignore, account: cloud, ownership: .anotherApplication)
        }
        check("unknown cloud key ignored", .ignore,
              account: "v2.cloud.unrecognized", ownership: .lastOrder)

        let integration = "MisakaNetwork.LastOrder.integration.11111111-2222-4333-8444-555555555555"
        check("exact integration identity", .remove,
              service: integration, account: lastOrderMasterAccount, label: lastOrderIntegrationLabel)
        check("integration label is exact", .ignore,
              service: integration, account: lastOrderMasterAccount, label: "other")
        check("integration label missing", .ignore,
              service: integration, account: lastOrderMasterAccount)
        check("integration account is exact", .ignore,
              service: integration, account: "another", label: lastOrderIntegrationLabel)
        check("integration UUID required", .ignore,
              service: "MisakaNetwork.LastOrder.integration.not-a-uuid",
              account: lastOrderMasterAccount, label: lastOrderIntegrationLabel)
        check("integration service is exact", .ignore,
              service: integration + ".other", account: lastOrderMasterAccount,
              label: lastOrderIntegrationLabel)
        check("test label is insufficient", .ignore,
              service: "another.app", account: lastOrderMasterAccount,
              label: lastOrderIntegrationLabel)

        print("\(checked) synthetic keychain policy checks passed; no keychain access.")

        // Inject statuses instead of calling either real deletion API. Verify
        // that failures preserve their numeric cause and cannot appear successful.
        var calls = 0
        do {
            try deleteLastOrderKeychainReference { calls += 1; return errSecSuccess }
        } catch { fatalError("Synthetic success was rejected") }
        guard calls == 1 else { fatalError("Deletion must be attempted once") }
        let failures: [OSStatus] = [
            errSecInvalidOwnerEdit, errSecUserCanceled, errSecAuthFailed,
            errSecInteractionNotAllowed, errSecParam, errSecItemNotFound, -99999,
        ]
        for status in failures {
            calls = 0
            do {
                try deleteLastOrderKeychainReference { calls += 1; return status }
                fatalError("Synthetic failure was treated as success")
            } catch let error as LastOrderCleanupError {
                guard case let .operationFailed(api, returned) = error,
                      returned == status, api == "SecKeychainItemDelete",
                      error.diagnostic.contains("OSStatus \(status)"), calls == 1 else {
                    fatalError("Deletion error lost its diagnostic")
                }
            } catch { fatalError("Unexpected synthetic error type") }
        }
        print("8 synthetic deletion-status checks passed; no keychain access.")
    }
}
