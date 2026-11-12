import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:last_order/src/services.dart';
import 'package:uuid/uuid.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('misaka/embedded');

  testWidgets('Android embedded client uses the shared protocol', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    final runtime = LocalRuntime();
    final status = await runtime.call('ping', {});
    expect(status['version'], '0.2.1');
    expect(status['ready'], isTrue);
    expect(status['bili_version'], '2.15.18');
    final validation = await runtime.call('validate', {'config': {}});
    expect(validation['ok'], isFalse);
    final rejected = jsonDecode(
      (await channel.invokeMethod<String>(
        'runtime',
        jsonEncode({'op': 'run', 'params': {}}),
      ))!,
    ) as Map<String, dynamic>;
    expect(rejected['ok'], isFalse);
    expect(activeChildProcessCount, 0);
  });

  testWidgets('Android JNI creates private identities and confines paths', (
    tester,
  ) async {
    final directory = await Directory(await LocalStore().directory())
        .createTemp('integration-android-pki-');
    try {
      final identity = await LocalHelper().call({
        'action': 'init_pki',
        'directory': directory.path,
      });
      for (final name in ['ca_cert', 'client_cert', 'client_key']) {
        final file = File(identity[name] as String);
        expect(await file.exists(), isTrue);
        expect((await file.stat()).mode & 0x1ff, 0x180);
        expect(
          await channel.invokeMethod<bool>('protectFile', {
            'path': file.path,
            'mode': '600',
          }),
          isTrue,
        );
      }
      final rejected = jsonDecode(
        (await channel.invokeMethod<String>(
          'helper',
          jsonEncode({'action': 'init_pki', 'directory': '/sdcard/identity'}),
        ))!,
      ) as Map<String, dynamic>;
      expect(rejected['ok'], isFalse);
      await expectLater(
        channel.invokeMethod<bool>('protectFile', {
          'path': '/system',
          'mode': '700',
        }),
        throwsA(isA<PlatformException>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('Android resources extracts every offline deployment target', (
    tester,
  ) async {
    final root = await channel.invokeMethod<String>('resources');
    expect(root, isNotNull);
    for (final target in [
      'linux-amd64',
      'linux-arm64',
      'macos-amd64',
      'macos-arm64',
    ]) {
      final bundle = File('$root/bundles/$target.tar.gz');
      expect(await bundle.exists(), isTrue);
      expect(await bundle.length(), greaterThan(0));
    }
    expect(await channel.invokeMethod<String>('resources'), root);
  });

  testWidgets('Android Keystore-backed credentials round trip and delete', (
    tester,
  ) async {
    final store = LocalStore();
    final key = 'integration.android.${const Uuid().v4()}';
    try {
      await store.writeSecret(key, 'synthetic-account-cookie');
      expect(await store.readSecret(key), 'synthetic-account-cookie');
      await store.deleteSecret(key);
      expect(await store.readSecret(key), isNull);
    } finally {
      await store.deleteSecret(key);
    }
  });
}
