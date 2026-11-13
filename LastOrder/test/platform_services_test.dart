import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';

void main() {
  test('deploy requests outlast the helper deploy budget', () {
    expect(helperTimeout({'action': 'deploy'}), const Duration(minutes: 30));
    expect(helperTimeout({'action': 'init_pki'}), const Duration(seconds: 300));
    expect(
      helperTimeout({'action': 'verify_cloud_credential'}),
      const Duration(seconds: 35),
    );
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('misaka/test-embedded');
  const services = EmbeddedServices(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('desktop resources use the host filesystem convention', () {
    expect(
      desktopResourcesDirectory(r'C:\Apps\LastOrder\LastOrder.exe', 'windows'),
      r'C:\Apps\LastOrder\resources',
    );
    expect(
      desktopResourcesDirectory(
        '/Applications/LastOrder.app/Contents/MacOS/LastOrder',
        'macos',
      ),
      '/Applications/LastOrder.app/Contents/Resources',
    );
  });
  test('embedded runtime transports credentials only in the request and decodes a result', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'runtime');
      expect(jsonDecode(call.arguments as String), {
        'op': 'login_state',
        'params': {'cookies': 'synthetic'},
      });
      return jsonEncode({
        'type': 'result',
        'ok': true,
        'data': {'status': 'valid'},
      });
    });
    expect(
      await services.call('runtime', {
        'op': 'login_state',
        'params': {'cookies': 'synthetic'},
      }),
      {'status': 'valid'},
    );
  });
  test(
    'helper fingerprint stays a confirmation, not successful deployment',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => jsonEncode({
          'ok': false,
          'fingerprint': 'SHA256:synthetic',
          'error': 'confirm',
        }),
      );
      expect(await services.call('helper', {'action': 'deploy'}), {
        'fingerprint': 'SHA256:synthetic',
        'needs_confirmation': true,
      });
    },
  );
  test('native failures do not expose platform exception detail', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async =>
          throw PlatformException(code: 'failure', message: 'private-cookie'),
    );
    await expectLater(
      services.call('runtime', {}),
      throwsA(
        isA<UserError>().having(
          (error) => error.message,
          'message',
          isNot(contains('private-cookie')),
        ),
      ),
    );
  });
  test(
    'embedded protocol rejects malformed, missing and progress responses',
    () async {
      for (final response in [
        'not-json',
        '[]',
        '{"type":"progress","ok":true}',
        '{"type":"result","ok":true,"data":[]}',
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => response);
        await expectLater(
          services.call('runtime', {}),
          throwsA(isA<UserError>()),
        );
      }
    },
  );
  test('embedded failure and timeout never report success', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => jsonEncode({
        'type': 'result',
        'ok': false,
        'error': {'message': '登录失效'},
      }),
    );
    await expectLater(services.call('runtime', {}), throwsA(isA<UserError>()));
    messenger.setMockMethodCallHandler(channel, (_) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return '{}';
    });
    await expectLater(
      services.call('helper', {}, timeout: const Duration(milliseconds: 1)),
      throwsA(isA<UserError>()),
    );
  });
  test(
    'resources accepts only an absolute native resource directory',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => '/data/user/0/app/files/resources/0.2.3',
      );
      expect(await services.resources(), startsWith('/data/'));
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => 'relative/bundles',
      );
      await expectLater(services.resources(), throwsA(isA<UserError>()));
    },
  );
  test('credential storage errors cannot erase Android encrypted data', () {
    expect(LocalStore().secure.aOptions.toMap()['resetOnError'], 'false');
    expect(
      LocalStore().secure.wOptions.toMap()['useBackwardCompatibility'],
      'false',
    );
  });
}
