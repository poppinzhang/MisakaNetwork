import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';
import 'tencent_controller_test.dart' show templateData;

class CredentialHarness {
  final store = MemoryStore();
  final helper = FakeHelper();
  late CloudController controller;
  bool disposed = false;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? verify;

  Future<void> init({Duration timeout = const Duration(seconds: 35)}) async {
    helper.handler = (request, _) async {
      if (request['action'] == 'generate_cloud_ssh_key') {
        return {
          'private_key': '-----BEGIN RSA PRIVATE KEY-----TEST',
          'public_key': 'ssh-rsa TEST',
          'fingerprint': 'SHA256:TEST',
        };
      }
      expect(request['action'], 'verify_cloud_credential');
      final input = request['cloud_credential'] as Map<String, dynamic>;
      return verify == null
          ? {'verified': true, 'provider': input['provider']}
          : await verify!(input);
    };
    controller = CloudController(
      store: store,
      helper: helper,
      templateLoader: () async => [CloudTemplate.tencent(templateData())],
      credentialVerificationTimeout: timeout,
    );
    addTearDown(() {
      if (!disposed) controller.dispose();
    });
    await controller.initialize();
  }

  Future<void> save(CloudProvider provider, [String suffix = '1']) =>
      controller.saveCredential(
        provider,
        accessKeyId: '  TestAccessId$suffix  ',
        accessKeySecret: '  TestSecret$suffix  ',
      );

  Map<String, dynamic> get saved =>
      jsonDecode(store.secrets[CloudController.workspaceKey]!)
          as Map<String, dynamic>;
}

void main() {
  for (final provider in CloudProvider.values) {
    test('${provider.name} saves only after explicit online success', () async {
      final h = CredentialHarness();
      await h.init();
      final started = Completer<void>();
      final result = Completer<Map<String, dynamic>>();
      h.verify = (input) {
        expect(input, {
          'provider': provider.name,
          'access_key_id': 'TestAccessId1',
          'access_key_secret': 'TestSecret1',
        });
        started.complete();
        return result.future;
      };
      final saving = h.save(provider);
      await started.future;
      expect(h.controller.credentialFor(provider), isNull);
      expect(
        h.store.secrets.containsKey(CloudController.workspaceKey),
        isFalse,
      );
      result.complete({'verified': true, 'provider': provider.name});
      await saving;
      expect(h.controller.credentialFor(provider)!.onlineVerified, isTrue);
      expect((h.saved['credentials'] as List).single['onlineVerified'], isTrue);
      expect(
        (h.saved['credentials'] as List).single.containsKey('alias'),
        isFalse,
      );
      expect(h.store.state.encode(), isNot(contains('TestSecret')));
    });

    test(
      '${provider.name} rejects failed validation without saving submitted values',
      () async {
        final h = CredentialHarness();
        await h.init();
        h.verify = (_) async =>
            throw StateError('TestSecret2 private response');
        await expectLater(h.save(provider), throwsA(isA<UserError>()));
        expect(h.controller.credentials, isEmpty);
        expect(
          h.store.secrets.containsKey(CloudController.workspaceKey),
          isFalse,
        );
        await expectLater(
          h.save(provider, '2'),
          throwsA(
            isA<UserError>().having(
              (error) => error.toString(),
              'redacted error',
              allOf(contains('未保存新凭证'), isNot(contains('TestSecret'))),
            ),
          ),
        );
        expect(h.controller.credentials, isEmpty);
        expect(
          h.store.secrets.containsKey(CloudController.workspaceKey),
          isFalse,
        );
      },
    );

    test(
      '${provider.name} must remove a verified credential before saving another',
      () async {
        final h = CredentialHarness();
        await h.init();
        await h.save(provider);
        final original = h.store.secrets[CloudController.workspaceKey];
        final verified = h.controller.credentialFor(provider)!;
        var requests = 0;
        h.verify = (input) async {
          requests++;
          return {'verified': true, 'provider': input['provider']};
        };
        await expectLater(
          h.save(provider, '2'),
          throwsA(
            isA<UserError>().having(
              (e) => e.toString(),
              'must remove first',
              contains('先移除'),
            ),
          ),
        );
        expect(requests, 0);
        expect(h.store.secrets[CloudController.workspaceKey], original);
        expect(
          h.controller.credentialFor(provider)!.maskedId,
          verified.maskedId,
        );
        await h.controller.removeCredential(provider);
        expect(h.controller.credentialFor(provider), isNull);
        await h.save(provider, '2');
        expect(requests, 1);
        expect(h.controller.credentials, hasLength(1));
        expect(
          (h.saved['credentials'] as List).single['accessKeyId'],
          'TestAccessId2',
        );
        expect(jsonEncode(h.saved), isNot(contains('TestSecret1')));
      },
    );

    test(
      '${provider.name} failed deletion retains the credential and blocks replacement',
      () async {
        final h = CredentialHarness();
        await h.init();
        await h.save(provider);
        final original = h.store.secrets[CloudController.workspaceKey];
        h.store.failWrite.add(CloudController.workspaceKey);
        await expectLater(
          h.controller.removeCredential(provider),
          throwsA(isA<UserError>()),
        );
        expect(h.controller.credentialFor(provider)!.onlineVerified, isTrue);
        expect(h.store.secrets[CloudController.workspaceKey], original);
        await expectLater(
          h.save(provider, '2'),
          throwsA(
            isA<UserError>().having(
              (e) => e.toString(),
              'must remove first',
              contains('先移除'),
            ),
          ),
        );
        expect(h.store.secrets[CloudController.workspaceKey], original);
      },
    );

    test(
      '${provider.name} old unverified credentials survive a failed online check',
      () async {
        final h = CredentialHarness();
        final original = jsonEncode({
          'version': 1,
          'credentials': [
            {
              'provider': provider.name,
              'alias': {'obsolete': 'ignored'},
              'accessKeyId': 'TestAccessId1',
              'accessKeySecret': 'TestSecret1',
              'checkedAt': '2026-11-01T00:00:00Z',
            },
          ],
          'jobs': [],
        });
        h.store.secrets[CloudController.workspaceKey] = original;
        await h.init();
        expect(h.controller.credentialFor(provider)!.onlineVerified, isFalse);
        h.verify = (_) async =>
            throw StateError('TestSecret2 private response');
        await expectLater(
          h.save(provider, '2'),
          throwsA(
            isA<UserError>().having(
              (e) => e.toString(),
              'not saved',
              contains('未保存新凭证'),
            ),
          ),
        );
        expect(h.controller.credentialFor(provider)!.onlineVerified, isFalse);
        expect(h.store.secrets[CloudController.workspaceKey], original);
        h.verify = null;
        await h.save(provider, '2');
        expect(h.controller.credentialFor(provider)!.onlineVerified, isTrue);
        expect(
          (h.saved['credentials'] as List).single['accessKeyId'],
          'TestAccessId2',
        );
        expect(
          (h.saved['credentials'] as List).single.containsKey('alias'),
          isFalse,
        );
      },
    );
  }

  test(
    'missing, negative or mismatched verification never authorizes saving',
    () async {
      final h = CredentialHarness();
      await h.init();
      for (final result in <Map<String, dynamic>>[
        {},
        {'verified': false, 'provider': 'tencent'},
        {'verified': 'true', 'provider': 'tencent'},
        {'verified': true},
        {'verified': true, 'provider': 'aliyun'},
      ]) {
        h.verify = (_) async => result;
        await expectLater(
          h.save(CloudProvider.tencent),
          throwsA(isA<UserError>()),
        );
        expect(h.controller.credentials, isEmpty);
        expect(
          h.store.secrets.containsKey(CloudController.workspaceKey),
          isFalse,
        );
      }
    },
  );

  test('one credential per provider survives reload and deletion', () async {
    final h = CredentialHarness();
    await h.init();
    await Future.wait([
      for (final provider in CloudProvider.values) h.save(provider),
    ]);
    expect(h.controller.credentials.length, 3);
    expect((h.saved['credentials'] as List).length, 3);
    final restored = CloudController(
      store: h.store,
      helper: h.helper,
      templateLoader: () async => [],
    );
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(
      restored.credentialFor(CloudProvider.tencent)!.onlineVerified,
      isTrue,
    );
    await restored.removeCredential(CloudProvider.tencent);
    expect(restored.credentials.keys, [
      CloudProvider.aliyun,
      CloudProvider.volcengine,
    ]);
    final saved = jsonEncode(h.saved['credentials']);
    expect(saved, isNot(contains('tencent')));
  });

  test(
    'concurrent saves verify once and reject the queued second credential',
    () async {
      final h = CredentialHarness();
      await h.init();
      final started = Completer<void>();
      final result = Completer<Map<String, dynamic>>();
      var requests = 0;
      h.verify = (_) {
        requests++;
        started.complete();
        return result.future;
      };
      final saving = h.save(CloudProvider.tencent);
      await started.future;
      final second = expectLater(
        h.save(CloudProvider.tencent, '2'),
        throwsA(
          isA<UserError>().having(
            (e) => e.toString(),
            'must remove first',
            contains('先移除'),
          ),
        ),
      );
      result.complete({'verified': true, 'provider': 'tencent'});
      await Future.wait([saving, second]);
      expect(requests, 1);
      expect(h.controller.credentials, hasLength(1));
      expect(
        (h.saved['credentials'] as List).single['accessKeyId'],
        'TestAccessId1',
      );
    },
  );

  test(
    'failed secure save stays retryable even after successful verification',
    () async {
      final h = CredentialHarness();
      await h.init();
      h.store.failWrite.add(CloudController.workspaceKey);
      await expectLater(
        h.save(CloudProvider.tencent),
        throwsA(isA<UserError>()),
      );
      expect(h.controller.credentials, isEmpty);
      expect(
        h.store.secrets.containsKey(CloudController.workspaceKey),
        isFalse,
      );
      h.store.failWrite.clear();
      await h.save(CloudProvider.tencent);
      expect(
        h.controller.credentialFor(CloudProvider.tencent)!.onlineVerified,
        isTrue,
      );
    },
  );

  test('delete queued during verification runs after save and leaves no credential', () async {
    final h = CredentialHarness();
    await h.init();
    final started = Completer<void>();
    final result = Completer<Map<String, dynamic>>();
    h.verify = (_) {
      started.complete();
      return result.future;
    };
    final saving = h.save(CloudProvider.tencent);
    await started.future;
    final removing = h.controller.removeCredential(CloudProvider.tencent);
    result.complete({'verified': true, 'provider': 'tencent'});
    await Future.wait([saving, removing]);
    expect(h.controller.credentials, isEmpty);
    expect(h.saved['credentials'], isEmpty);
  });

  test(
    'timeout and late verification result never save submitted secrets',
    () async {
      final h = CredentialHarness();
      await h.init(timeout: const Duration(milliseconds: 10));
      final result = Completer<Map<String, dynamic>>();
      h.verify = (_) => result.future;
      await expectLater(
        h.save(CloudProvider.tencent),
        throwsA(isA<UserError>()),
      );
      result.complete({'verified': true, 'provider': 'tencent'});
      await Future<void>.value();
      expect(h.controller.credentials, isEmpty);
      expect(
        h.store.secrets.containsKey(CloudController.workspaceKey),
        isFalse,
      );
    },
  );

  test('disposing during verification prevents a late write', () async {
    final h = CredentialHarness();
    await h.init();
    final started = Completer<void>();
    final result = Completer<Map<String, dynamic>>();
    h.verify = (_) {
      started.complete();
      return result.future;
    };
    final saving = h.save(CloudProvider.tencent);
    await started.future;
    h.controller.dispose();
    h.disposed = true;
    final failed = expectLater(saving, throwsA(isA<UserError>()));
    result.complete({'verified': true, 'provider': 'tencent'});
    await failed;
    expect(h.store.secrets.containsKey(CloudController.workspaceKey), isFalse);
  });

  test(
    'locally checked old credentials stay unverified until resubmitted',
    () async {
      final h = CredentialHarness();
      await h.init();
      await h.save(CloudProvider.tencent);
      await h.save(CloudProvider.aliyun);
      final old = h.saved;
      for (final credential in old['credentials'] as List) {
        (credential as Map).remove('onlineVerified');
      }
      h.store.secrets[CloudController.workspaceKey] = jsonEncode(old);
      final restored = CloudController(
        store: h.store,
        helper: h.helper,
        templateLoader: () async => [CloudTemplate.tencent(templateData())],
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.initialized, isTrue);
      expect(
        restored.credentials.values.every((c) => !c.onlineVerified),
        isTrue,
      );
      await expectLater(
        restored.startTencentCreation(
          restored.templatesFor(CloudProvider.tencent).single,
        ),
        throwsA(isA<UserError>()),
      );
      await expectLater(
        restored.startPreviewCreation(
          CloudProvider.aliyun,
          CloudTemplate.forProvider(CloudProvider.aliyun).first,
        ),
        throwsA(isA<UserError>()),
      );
      await restored.saveCredential(
        CloudProvider.tencent,
        accessKeyId: 'TestAccessId1',
        accessKeySecret: 'TestSecret1',
      );
      expect(
        restored.credentialFor(CloudProvider.tencent)!.onlineVerified,
        isTrue,
      );
      await restored.removeCredential(CloudProvider.aliyun);
      expect(restored.credentialFor(CloudProvider.aliyun), isNull);
    },
  );

  test(
    'duplicate stored providers are rejected without overwriting the source',
    () async {
      final h = CredentialHarness();
      await h.init();
      await h.save(CloudProvider.tencent);
      final corrupt = h.saved;
      final entries = corrupt['credentials'] as List;
      entries.add(Map<String, dynamic>.from(entries.single as Map));
      final raw = jsonEncode(corrupt);
      h.store.secrets[CloudController.workspaceKey] = raw;
      final restored = CloudController(
        store: h.store,
        helper: h.helper,
        templateLoader: () async => [],
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.initialized, isFalse);
      expect(restored.startupError, isNotNull);
      await expectLater(
        restored.removeCredential(CloudProvider.tencent),
        throwsA(isA<UserError>()),
      );
      expect(h.store.secrets[CloudController.workspaceKey], raw);
    },
  );

  for (final pendingNetwork in [false, true]) {
    test(
      'old unverified credentials retain resource ownership protection (network: $pendingNetwork)',
      () async {
        final h = CredentialHarness();
        await h.init();
        await h.save(CloudProvider.tencent);
        final existing = h.saved;
        ((existing['credentials'] as List).single as Map).remove(
          'onlineVerified',
        );
        if (pendingNetwork) {
          existing['networks'] = [
            {
              'credentialId': 'TestAccessId1',
              'region': 'ap-guangzhou',
              'kind': 'vpc',
              'zone': '',
              'vpcId': '',
              'subnetId': '',
              'subnetCidr': '',
              'pending': true,
            },
          ];
        } else {
          existing['jobs'] = [
            CloudMachine(
              id: 'existing-job',
              name: '测试服务器',
              provider: CloudProvider.tencent,
              template: CloudTemplate.tencent(templateData()),
              phase: CloudMachinePhase.created,
              isReal: true,
              region: 'ap-guangzhou',
              credentialId: 'TestAccessId1',
              instanceId: 'ins-fixture',
              clientToken: 'fixture-token',
              selectedZone: 'ap-guangzhou-6',
            ).toJson(),
          ];
        }
        final original = jsonEncode(existing);
        h.store.secrets[CloudController.workspaceKey] = original;
        final restored = CloudController(
          store: h.store,
          helper: h.helper,
          templateLoader: () async => [],
        );
        addTearDown(restored.dispose);
        await restored.initialize();
        expect(
          restored.credentialFor(CloudProvider.tencent)!.onlineVerified,
          isFalse,
        );
        await expectLater(
          restored.removeCredential(CloudProvider.tencent),
          throwsA(
            isA<UserError>().having(
              (e) => e.toString(),
              'retains ownership',
              contains('未释放或待核实'),
            ),
          ),
        );
        await expectLater(
          restored.saveCredential(
            CloudProvider.tencent,
            accessKeyId: 'DifferentAccessId',
            accessKeySecret: 'DifferentSecret',
          ),
          throwsA(
            isA<UserError>().having(
              (e) => e.toString(),
              'preserves original identity',
              contains('再更换 SecretId'),
            ),
          ),
        );
        expect(h.store.secrets[CloudController.workspaceKey], original);
        await restored.saveCredential(
          CloudProvider.tencent,
          accessKeyId: 'TestAccessId1',
          accessKeySecret: 'TestSecret1',
        );
        expect(
          restored.credentialFor(CloudProvider.tencent)!.onlineVerified,
          isTrue,
        );
      },
    );
  }
}
