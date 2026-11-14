import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
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
    expect(status['version'], '0.3.2');
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

  testWidgets(
    'Android embedded QR encoder survives repeated calls and errors',
    (tester) async {
      final runtime = LocalRuntime();
      for (var attempt = 0; attempt < 3; attempt++) {
        final encoded = await runtime.call('payment_qr', {
          'payment_code_url': 'weixin://wxpay/bizpayurl?pr=synthetic_$attempt',
        });
        final png = base64Decode(encoded['qr_png_base64'] as String);
        expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(png.length, greaterThan(100));
        // Decode on the Android Flutter engine as well as checking Python's output.
        final image = await decodeImageFromList(png);
        expect(image.width, greaterThan(0));
        expect(image.width, image.height);
        image.dispose();

        final rejected = jsonDecode(
          (await channel.invokeMethod<String>(
            'runtime',
            jsonEncode({
              'op': 'payment_qr',
              'params': {'payment_code_url': 'https://invalid.example/qr'},
            }),
          ))!,
        ) as Map<String, dynamic>;
        expect(rejected['ok'], isFalse);
        expect((await runtime.call('ping', {}))['ready'], isTrue);
      }
      expect(activeChildProcessCount, 0);
    },
  );

  testWidgets('Android embedded builds and validates a synthetic ticket task', (
    tester,
  ) async {
    final runtime = LocalRuntime();
    // Synthetic context supplies every field locally; neither this operation
    // nor validate requests a real catalog, account, address or order.
    final config = await runtime.call('build_config', {
      'purchase_context': {
        'project_id': 123,
        'project_name': 'Synthetic project',
        'username': 'Synthetic account',
        'cookies': [
          {'name': 'SESSDATA', 'value': 'synthetic-cookie'},
        ],
        'ticket_options': [
          {
            'id': 456,
            'screen_id': 789,
            'price': 100,
            'display': 'Synthetic ticket',
          },
        ],
        'buyers': [
          {'name': 'Synthetic buyer', 'personal_id': 'synthetic-id'},
        ],
        'addresses': [
          {
            'id': 1,
            'name': 'Synthetic contact',
            'phone': 'synthetic-phone',
            'addr': 'Synthetic address',
          },
        ],
      },
      'selection': {
        'ticket_index': 0,
        'buyer_indices': [0],
        'address_index': 0,
        'buyer': 'Synthetic contact',
        'tel': 'synthetic-phone',
      },
    });
    expect(config['project_id'], 123);
    expect(config['sku_id'], 456);
    expect(config['count'], 1);
    final validation = await runtime.call('validate', {'config': config});
    expect(validation['ok'], isTrue);
    expect(validation['error_count'], 0);
    expect((await runtime.call('ping', {}))['ready'], isTrue);
    expect(activeChildProcessCount, 0);
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
