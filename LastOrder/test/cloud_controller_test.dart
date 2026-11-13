import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

const testIdentity = {
  'private_key': '-----BEGIN RSA PRIVATE KEY-----\nTEST ONLY\n-----END RSA PRIVATE KEY-----',
  'public_key': 'ssh-rsa TEST-ONLY-PUBLIC-KEY',
  'fingerprint': 'SHA256:TEST-ONLY-FINGERPRINT',
};

FakeHelper keyHelper() => FakeHelper()
  ..handler = (request, _) async {
    expect(request, {'action': 'generate_cloud_ssh_key'});
    return testIdentity;
  };

Future<CloudController> readyController({
  MemoryStore? store,
  FakeHelper? helper,
}) async {
  final controller = CloudController(
    templateLoader: () async => [],
    store: store ?? MemoryStore(),
    helper: helper ?? keyHelper(),
  );
  addTearDown(controller.dispose);
  await controller.initialize();
  return controller;
}

Future<void> saveCredential(
  CloudController controller,
  CloudProvider provider,
) => controller.saveCredential(
  provider,
  alias: '${provider.displayName}演示账号',
  accessKeyId: 'ExampleAccessId12345',
  accessKeySecret: 'ExampleSecret12345',
);

class _CloudWriteGateStore extends MemoryStore {
  final writeStarted = Completer<void>();
  final writeAllowed = Completer<void>();
  @override
  Future<void> writeSecret(String key, String value) async {
    if (key == CloudController.workspaceKey) {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await writeAllowed.future;
    }
    await super.writeSecret(key, value);
  }
}

void main() {
  test('provider-specific fields and generic local validation', () {
    expect(CloudProvider.tencent.credentialIdLabel, 'SecretId');
    expect(CloudProvider.aliyun.credentialSecretLabel, 'AccessKey Secret');
    expect(CloudProvider.volcengine.credentialSecretLabel, 'Secret Access Key');
    for (final invalid in [
      '',
      'a b',
      'a\nb',
      'a\x00b',
      'https://example.test',
      '-----BEGIN',
      'ssh-rsa',
    ]) {
      expect(
        CloudController.validateCredentialValue(invalid, 'ID'),
        isNotNull,
        reason: invalid,
      );
    }
    // Upstream key lengths are not stable validation contracts.
    expect(
      CloudController.validateCredentialValue('  arbitrary-value  ', 'ID'),
      isNull,
    );
  });

  test(
    'credentials use system secrets and UI metadata exposes masked ID only',
    () async {
      final store = MemoryStore();
      final c = await readyController(store: store);
      await saveCredential(c, CloudProvider.tencent);
      expect(c.credentials.keys, [CloudProvider.tencent]);
      final credential = c.credentialFor(CloudProvider.tencent)!;
      expect(credential.maskedId, 'Exam••••2345');
      expect(credential.locallyChecked, isTrue);
      expect(store.state.encode(), isNot(contains('ExampleAccessId')));
      expect(store.state.encode(), isNot(contains('ExampleSecret')));
      expect(store.state.encode(), isNot(contains('PRIVATE KEY')));
      final restored = await readyController(store: store);
      expect(
        restored.credentialFor(CloudProvider.tencent)!.alias,
        credential.alias,
      );
      await restored.removeCredential(CloudProvider.tencent);
      expect(restored.credentialFor(CloudProvider.tencent), isNull);
      expect(
        store.secrets[CloudController.workspaceKey],
        isNot(contains('ExampleSecret')),
      );
    },
  );

  test(
    'credential writes are serialized and failed replacement retains old value',
    () async {
      final store = MemoryStore();
      final c = await readyController(store: store);
      await Future.wait([
        for (final provider in CloudProvider.values)
          saveCredential(c, provider),
      ]);
      expect(c.credentials.length, 3);
      store.failWrite.add(CloudController.workspaceKey);
      await expectLater(
        c.saveCredential(
          CloudProvider.tencent,
          alias: '替换',
          accessKeyId: 'NewAccessId',
          accessKeySecret: 'NewSecret',
        ),
        throwsA(isA<UserError>()),
      );
      expect(c.credentialFor(CloudProvider.tencent)!.alias, '腾讯云演示账号');
      await expectLater(
        c.removeCredential(CloudProvider.tencent),
        throwsA(isA<UserError>()),
      );
      expect(c.credentials.length, 3);
    },
  );

  test(
    'key generated once, stored securely and reused across initialization',
    () async {
      final store = MemoryStore();
      final helper = keyHelper();
      final c = await readyController(store: store, helper: helper);
      expect(c.sshReady, isTrue);
      expect(c.sshPublicKey, testIdentity['public_key']);
      expect(c.sshFingerprint, testIdentity['fingerprint']);
      expect(helper.requests.length, 1);
      await Future.wait([c.ensureSshIdentity(), c.ensureSshIdentity()]);
      await readyController(store: store, helper: helper);
      expect(helper.requests.length, 1);
      expect(
        store.secrets[CloudController.sshIdentityKey],
        contains('PRIVATE KEY'),
      );
      expect(store.state.encode(), isNot(contains('PRIVATE KEY')));
    },
  );

  test('concurrent key retry shares one generation and write failure stays retryable', () async {
    final store = MemoryStore()..failWrite.add(CloudController.sshIdentityKey);
    final helper = keyHelper();
    final c = await readyController(store: store, helper: helper);
    expect(c.initialized, isTrue);
    expect(c.keyError, isNotNull);
    expect(c.sshReady, isFalse);
    store.failWrite.clear();
    final gate = Completer<Map<String, dynamic>>();
    helper.handler = (_, _) => gate.future;
    final first = c.ensureSshIdentity();
    final second = c.ensureSshIdentity();
    gate.complete(testIdentity);
    await Future.wait([first, second]);
    expect(c.sshReady, isTrue);
    expect(c.keyError, isNull);
    expect(helper.requests.length, 2);
  });

  test('existing corrupt identity is preserved without replacement', () async {
    final store = MemoryStore()
      ..secrets[CloudController.sshIdentityKey] = 'corrupt identity';
    final helper = keyHelper();
    final c = await readyController(store: store, helper: helper);
    expect(c.keyError, isNotNull);
    expect(helper.requests, isEmpty);
    expect(store.secrets[CloudController.sshIdentityKey], 'corrupt identity');
    await c.ensureSshIdentity();
    expect(helper.requests, isEmpty);
  });

  test('unreadable workspace is not replaced by new credentials', () async {
    final store = MemoryStore()
      ..secrets[CloudController.workspaceKey] = 'corrupt workspace';
    final c = await readyController(store: store);
    expect(c.initialized, isFalse);
    expect(c.startupError, isNotNull);
    await expectLater(
      saveCredential(c, CloudProvider.tencent),
      throwsA(isA<UserError>()),
    );
    expect(store.secrets[CloudController.workspaceKey], 'corrupt workspace');
  });

  test('initialization storage failure can be retried without losing saved credentials', () async {
    final store = MemoryStore()..failRead.add(CloudController.workspaceKey);
    final c = await readyController(store: store);
    expect(c.startupError, isNotNull);
    expect(c.initialized, isFalse);
    store.failRead.clear();
    await c.initialize();
    expect(c.startupError, isNull);
    expect(c.initialized, isTrue);
    await saveCredential(c, CloudProvider.tencent);
    expect(c.credentials.length, 1);
  });

  test('input limits reject oversized pasted values and aliases', () async {
    expect(
      CloudController.validateCredentialValue('a' * 2049, 'ID'),
      contains('2048'),
    );
    final c = await readyController();
    await expectLater(
      c.saveCredential(
        CloudProvider.tencent,
        alias: 'a' * 41,
        accessKeyId: 'ExampleId',
        accessKeySecret: 'ExampleSecret',
      ),
      throwsA(isA<UserError>()),
    );
  });

  test(
    'disposing while initialization reads does not generate or persist keys',
    () async {
      final gate = Completer<void>();
      final store = MemoryStore()..beforeRead = (_) => gate.future;
      final helper = keyHelper();
      final c = CloudController(store: store, helper: helper);
      final initialization = c.initialize();
      c.dispose();
      gate.complete();
      await initialization;
      expect(helper.requests, isEmpty);
      expect(store.secrets, isEmpty);
    },
  );

  test(
    'disposing while key generation runs does not save returned key material',
    () async {
      final gate = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      final store = MemoryStore();
      final helper = FakeHelper()
        ..handler = (_, _) {
          started.complete();
          return gate.future;
        };
      final c = CloudController(store: store, helper: helper);
      final initialization = c.initialize();
      await started.future;
      c.dispose();
      gate.complete(testIdentity);
      await initialization;
      expect(store.secrets, isEmpty);
      expect(c.sshReady, isFalse);
    },
  );

  testWidgets(
    'creation runs independently, returns immediately and never enters real machines',
    (tester) async {
      final store = MemoryStore();
      final helper = keyHelper();
      final c = await readyController(store: store, helper: helper);
      await saveCredential(c, CloudProvider.volcengine);
      final template = CloudTemplate.forProvider(CloudProvider.volcengine)
          .first;
      final created = await Future.wait([
        c.startPreviewCreation(CloudProvider.volcengine, template),
        c.startPreviewCreation(CloudProvider.volcengine, template),
      ]);
      expect(created.map((job) => job.id).toSet().length, 2);
      expect(created.map((job) => job.name).toSet().length, 2);
      expect(
        c.jobs.every((job) => job.phase == CloudMachinePhase.creating),
        isTrue,
      );
      expect(store.state.machines, isEmpty);
      await tester.pump(const Duration(seconds: 3));
      expect(
        c.jobs.every((job) => job.phase == CloudMachinePhase.deploying),
        isTrue,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(
        c.jobs.every((job) => job.phase == CloudMachinePhase.ready),
        isTrue,
      );
      expect(helper.requests, [
        {'action': 'generate_cloud_ssh_key'},
      ]);
      expect(store.state.machines, isEmpty);
    },
  );

  testWidgets('failure outcomes, deletion and release remain local previews', (
    tester,
  ) async {
    final c = await readyController();
    await saveCredential(c, CloudProvider.aliyun);
    final template = CloudTemplate.forProvider(CloudProvider.aliyun).first;
    final creationFailure = await c.startPreviewCreation(
      CloudProvider.aliyun,
      template,
      outcome: CloudPreviewOutcome.createFailure,
    );
    final deploymentFailure = await c.startPreviewCreation(
      CloudProvider.aliyun,
      template,
      outcome: CloudPreviewOutcome.deployFailure,
    );
    await tester.pump(const Duration(seconds: 3));
    expect(c.jobs.first.phase, CloudMachinePhase.createFailed);
    expect(c.jobs.first.error, contains('演示'));
    await c.removeMachine(creationFailure.id);
    await tester.pump(const Duration(seconds: 3));
    expect(c.jobs.single.phase, CloudMachinePhase.deployFailed);
    await c.requestPreviewRelease(deploymentFailure.id);
    expect(c.jobs.single.phase, CloudMachinePhase.releasing);
    await tester.pump(const Duration(seconds: 2));
    expect(c.jobs.single.phase, CloudMachinePhase.released);
    await c.removeMachine(deploymentFailure.id);
    expect(c.jobs, isEmpty);
  });

  testWidgets(
    'failed creation save creates no job and later progress save failure is visible',
    (tester) async {
      final store = MemoryStore();
      final c = await readyController(store: store);
      await saveCredential(c, CloudProvider.volcengine);
      final template = CloudTemplate.forProvider(CloudProvider.volcengine)
          .first;
      store.failWrite.add(CloudController.workspaceKey);
      await expectLater(
        c.startPreviewCreation(CloudProvider.volcengine, template),
        throwsA(isA<UserError>()),
      );
      expect(c.jobs, isEmpty);
      store.failWrite.clear();
      await c.startPreviewCreation(CloudProvider.volcengine, template);
      store.failWrite.add(CloudController.workspaceKey);
      await tester.pump(const Duration(seconds: 3));
      expect(c.jobs.single.phase, CloudMachinePhase.interrupted);
      expect(c.jobs.single.error, contains('无法保存'));
    },
  );

  testWidgets('restart interrupts active previews and does not resume timers', (
    tester,
  ) async {
    final store = MemoryStore();
    final first = await readyController(store: store);
    await saveCredential(first, CloudProvider.volcengine);
    await first.startPreviewCreation(
      CloudProvider.volcengine,
      CloudTemplate.forProvider(CloudProvider.volcengine).first,
    );
    final nextStore = MemoryStore()..secrets.addAll(store.secrets);
    final restored = await readyController(store: nextStore);
    expect(restored.jobs.single.phase, CloudMachinePhase.interrupted);
    await tester.pump(const Duration(seconds: 10));
    expect(restored.jobs.single.phase, CloudMachinePhase.interrupted);
    final saved =
        jsonDecode(nextStore.secrets[CloudController.workspaceKey]!) as Map;
    expect((saved['jobs'] as List).single['phase'], 'interrupted');
  });

  test('creation requires local credentials, a ready key and matching provider template', () async {
    final c = await readyController();
    final template = CloudTemplate.forProvider(CloudProvider.volcengine).first;
    await expectLater(
      c.startPreviewCreation(CloudProvider.volcengine, template),
      throwsA(isA<UserError>()),
    );
    await saveCredential(c, CloudProvider.volcengine);
    await expectLater(
      c.startPreviewCreation(
        CloudProvider.volcengine,
        CloudTemplate.forProvider(CloudProvider.aliyun).first,
      ),
      throwsA(isA<UserError>()),
    );
    final failedKey = await readyController(
      helper: FakeHelper()..handler = (_, _) async => {},
    );
    await saveCredential(failedKey, CloudProvider.volcengine);
    await expectLater(
      failedKey.startPreviewCreation(CloudProvider.volcengine, template),
      throwsA(isA<UserError>()),
    );
  });
  test('cloud storage failure does not block existing controller or machine refresh', () async {
    final store = MemoryStore()
      ..state = SavedState(machines: [machine('existing')])
      ..failRead.add(CloudController.workspaceKey);
    final gateway = FakeGateway();
    final c = controller(store: store, gateway: gateway);
    addTearDown(c.dispose);
    await c.initialize(poll: false);
    await c.cloud.initialize();
    expect(c.initialized, isTrue);
    expect(c.startupError, isNull);
    expect(c.cloud.startupError, isNotNull);
    await c.refresh();
    expect(gateway.statusRequests.map((m) => m.id), ['existing']);
  });

  testWidgets(
    'preview jobs are excluded from real gateway refresh and persisted machines',
    (tester) async {
      final store = MemoryStore()
        ..state = SavedState(machines: [machine('existing')]);
      final gateway = FakeGateway();
      final c = controller(store: store, gateway: gateway, helper: keyHelper());
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await c.cloud.initialize();
      await saveCredential(c.cloud, CloudProvider.volcengine);
      await c.cloud.startPreviewCreation(
        CloudProvider.volcengine,
        CloudTemplate.forProvider(CloudProvider.volcengine).first,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      expect(c.cloud.jobs.single.phase, CloudMachinePhase.ready);
      await c.refresh();
      expect(gateway.statusRequests.map((m) => m.id), ['existing']);
      expect(store.state.machines.map((m) => m.id), ['existing']);
    },
  );
  testWidgets(
    'startup recovery finishes persistence before accepting credential writes',
    (tester) async {
      final originalStore = MemoryStore();
      final original = await readyController(store: originalStore);
      await saveCredential(original, CloudProvider.volcengine);
      await original.startPreviewCreation(
        CloudProvider.volcengine,
        CloudTemplate.forProvider(CloudProvider.volcengine).first,
      );
      final store = _CloudWriteGateStore()
        ..secrets.addAll(originalStore.secrets);
      final restored = CloudController(
        store: store,
        helper: keyHelper(),
        templateLoader: () async => [],
      );
      addTearDown(restored.dispose);
      final initialization = restored.initialize();
      await store.writeStarted.future;
      expect(restored.initialized, isFalse);
      await expectLater(
        saveCredential(restored, CloudProvider.aliyun),
        throwsA(isA<UserError>()),
      );
      store.writeAllowed.complete();
      await initialization;
      expect(restored.initialized, isTrue);
      expect(restored.jobs.single.phase, CloudMachinePhase.interrupted);
      await saveCredential(restored, CloudProvider.aliyun);
      expect(restored.credentials.length, 2);
      await original.removeMachine(original.jobs.single.id);
    },
  );
}
