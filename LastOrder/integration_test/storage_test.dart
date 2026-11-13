import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:last_order/src/encrypted_vault.dart';
import 'package:last_order/src/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Counts calls while keeping the real native Keychain implementation.
class CountingKeychain extends FlutterSecureStorage {
  CountingKeychain(String service)
    : super(
        mOptions: MacOsOptions(
          usesDataProtectionKeychain: false,
          accountName: service,
          label: 'LastOrder synthetic storage test',
        ),
      );

  int reads = 0, writes = 0;
  final requestedKeys = <String>[];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    reads++;
    requestedKeys.add(key);
    return super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    writes++;
    requestedKeys.add(key);
    return super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

Future<T> storageOperation<T>(
  String operation,
  Future<T> Function() action,
) async {
  try {
    return await action();
  } on PlatformException catch (error) {
    // Report the operation and code, never native details or stored values.
    throw TestFailure('$operation failed (${error.code}).');
  } on TestFailure {
    rethrow;
  } catch (error) {
    throw TestFailure('$operation failed (${error.runtimeType}).');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'sandboxed macOS stores one master key and reopens encrypted records',
    (tester) async {
      expect(Platform.isMacOS, true);
      expect(defaultTargetPlatform, TargetPlatform.macOS);

      // Both the filesystem and Keychain service are unique synthetic fixtures.
      // Never use the production service or the user's application support dir.
      final temporary = await Directory.systemTemp.createTemp(
        'lastorder-vault-',
      );
      final keychain = CountingKeychain(
        'MisakaNetwork.LastOrder.integration.${const Uuid().v4()}',
      );
      final store = LocalStore(
        supportDirectory: () async => temporary,
        secure: keychain,
        useEncryptedVault: true,
      );
      const probes = {
        'account.synthetic': 'synthetic-cookie-for-vault-integration',
        'task.synthetic': 'synthetic-buyer-for-vault-integration',
        'cloud.synthetic': 'synthetic-cloud-secret-for-vault-integration',
      };
      final failures = <String>[];
      try {
        await storageOperation('initialize isolated store', store.load);
        await storageOperation(
          'write encrypted records',
          () => Future.wait([
            for (final entry in probes.entries)
              store.writeSecret(entry.key, entry.value),
          ]),
        );
        for (final entry in probes.entries) {
          final value = await storageOperation(
            'read encrypted record',
            () => store.readSecret(entry.key),
          );
          // Boolean comparisons keep decrypted values out of failure output.
          expect(value == entry.value, isTrue);
        }
        final secondStore = LocalStore(
          supportDirectory: () async => temporary,
          secure: keychain,
          useEncryptedVault: true,
        );
        await storageOperation('reuse session store', secondStore.load);
        expect(keychain.reads, 1);
        expect(keychain.writes, 1);
        expect(
          keychain.requestedKeys.every(
            (key) => key == LocalStore.masterKeyName,
          ),
          isTrue,
        );

        final directory = Directory(await store.directory());
        final encrypted = File(p.join(directory.path, EncryptedVault.filename));
        final ciphertext = await encrypted.readAsString();
        for (final probe in [...probes.keys, ...probes.values]) {
          expect(ciphertext.contains(probe), isFalse);
        }
        expect((await directory.stat()).mode & 0x1ff, 0x1c0);
        expect((await encrypted.stat()).mode & 0x1ff, 0x180);

        // A fresh engine has no in-memory key and must decrypt using the one
        // persisted by the native plugin, as a new process would.
        final reopened = EncryptedVault(
          directory: directory,
          readMasterKey: () => keychain.read(key: LocalStore.masterKeyName),
          writeMasterKey: (value) =>
              keychain.write(key: LocalStore.masterKeyName, value: value),
          protect: restrictPermissions,
        );
        for (final entry in probes.entries) {
          final value = await storageOperation(
            'read reopened encrypted record',
            () => reopened.read(entry.key),
          );
          expect(value == entry.value, isTrue);
        }
        expect(keychain.reads, 2);
        expect(keychain.writes, 1);

        for (final key in probes.keys) {
          await storageOperation(
            'delete encrypted record',
            () => store.deleteSecret(key),
          );
          await storageOperation(
            'repeat encrypted deletion',
            () => store.deleteSecret(key),
          );
          expect(
            await storageOperation('verify deletion', () => reopened.read(key)),
            isNull,
          );
        }
        expect(keychain.reads, 2);
        expect(keychain.writes, 1);
        expect(
          keychain.requestedKeys,
          List.filled(3, LocalStore.masterKeyName),
        );

        // Production uses exact-key reads, not readAll. The Darwin plugin's
        // match-all attributes/data query fails in the sandboxed login-Keychain
        // integration environment. Check the known record keys individually;
        // any native error still fails this test, rather than becoming absence.
        final inspector = FlutterSecureStorage(mOptions: keychain.mOptions);
        for (final key in probes.keys) {
          for (final candidate in [key, '${LocalStore.secretNamespace}$key']) {
            expect(
              await storageOperation(
                'verify no per-record Keychain entry',
                () => inspector.read(key: candidate),
              ),
              isNull,
            );
          }
        }
      } catch (error) {
        failures.add(
          error is TestFailure
              ? error.message ?? 'Storage integration assertion failed.'
              : '${error.runtimeType}',
        );
      }

      // Remove synthetic ciphertext before its key. Retain the key if cleanup
      // fails, so even a failing test does not strand recoverable ciphertext.
      var filesRemoved = false;
      try {
        await storageOperation('remove synthetic files', () async {
          await temporary.delete(recursive: true);
        });
        filesRemoved = true;
      } catch (_) {
        failures.add('Synthetic file cleanup failed.');
      }
      if (filesRemoved) {
        try {
          await storageOperation('remove synthetic master key', () async {
            // Avoid the native plugin's absent-item deletion edge case.
            if (await keychain.read(key: LocalStore.masterKeyName) != null) {
              await keychain.delete(key: LocalStore.masterKeyName);
            }
          });
        } catch (_) {
          failures.add('Synthetic Keychain cleanup failed.');
        }
      }
      if (failures.isNotEmpty) fail(failures.join('\n'));
    },
    // The native plugin selects platform options from this value.
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
