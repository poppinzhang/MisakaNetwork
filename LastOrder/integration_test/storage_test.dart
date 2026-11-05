import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:last_order/src/services.dart';
import 'package:uuid/uuid.dart';

Future<T> storageOperation<T>(
  String operation,
  Future<T> Function() action,
) async {
  try {
    return await action();
  } on PlatformException catch (error) {
    // Identify the failed operation without logging keys or stored values.
    throw TestFailure('$operation failed (${error.code}).');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'sandboxed macOS Keychain isolates current and previous namespaces',
    (tester) async {
      expect(Platform.isMacOS, true);
      expect(defaultTargetPlatform, TargetPlatform.macOS);
      final store = LocalStore();
      final key = 'integration.storage.namespace.${const Uuid().v4()}';
      final failures = <String>[];
      try {
        // Both entries are synthetic probes created by this test.
        await storageOperation(
          'write previous probe',
          () => store.secure.write(key: key, value: 'previous-test-value'),
        );
        expect(
          await storageOperation(
            'read empty current probe',
            () => store.readSecret(key),
          ),
          isNull,
        );
        await storageOperation(
          'write current probe',
          () => store.writeSecret(key, 'current-test-value'),
        );
        expect(
          await storageOperation(
            'read current probe',
            () => store.readSecret(key),
          ),
          'current-test-value',
        );
        expect(
          await storageOperation(
            'read previous probe',
            () => store.secure.read(key: key),
          ),
          'previous-test-value',
        );
        await storageOperation(
          'delete current probe',
          () => store.deleteSecret(key),
        );
        expect(
          await storageOperation(
            'verify current deletion',
            () => store.readSecret(key),
          ),
          isNull,
        );
        expect(
          await storageOperation(
            'verify previous preserved',
            () => store.secure.read(key: key),
          ),
          'previous-test-value',
        );
      } catch (error) {
        failures.add(error.toString());
      }
      // Clean up before the test variant restores the default target platform.
      // Attempt both entries and retain any earlier failure in the report.
      for (final cleanup in <(String, Future<void> Function())>[
        ('cleanup current probe', () => store.deleteSecret(key)),
        ('cleanup previous probe', () => store.secure.delete(key: key)),
      ]) {
        try {
          await storageOperation(cleanup.$1, cleanup.$2);
        } catch (error) {
          failures.add(error.toString());
        }
      }
      if (failures.isNotEmpty) fail(failures.join('\n'));
    },
    // Flutter test defaults to Android even on macOS. The native plugin selects
    // its Keychain options using this value, so exercise the actual host target.
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
