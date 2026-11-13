import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

Map<String, dynamic> templateData() => {
  'id': 'test-tencent',
  'name': '测试配置',
  'description': '离线测试',
  'cpu': 2,
  'memoryGb': 4,
  'diskGb': 50,
  'architecture': 'x64',
  'os': 'Ubuntu 24.04 LTS',
  'regionLabel': '广州',
  'region': 'ap-guangzhou',
  'runInstances': {
    'Placement': {'Zone': 'ap-guangzhou-6'},
    'InstanceType': 'S5.MEDIUM4',
    'ImageId': 'img-test1234',
    'SystemDisk': {'DiskType': 'CLOUD_SSD', 'DiskSize': 50},
    'InternetAccessible': {
      'InternetChargeType': 'TRAFFIC_POSTPAID_BY_HOUR',
      'InternetMaxBandwidthOut': 5,
      'PublicIpAssigned': true,
    },
  },
};

class Harness {
  final store = MemoryStore();
  final helper = FakeHelper();
  late CloudController c;
  String state = 'RUNNING';
  bool exists = true;
  String? failAction;
  Completer<void>? createGate;
  bool failAfterResponse = false;
  bool failAfterPrepare = false;
  bool disposed = false;
  final created = Completer<void>();

  Future<void> init() async {
    helper.handler = (request, _) async {
      final action = request['action'];
      if (action == failAction) {
        throw const UserError('secret-sensitive-upstream');
      }
      switch (action) {
        case 'verify_cloud_credential':
          return {
            'verified': true,
            'provider': (request['cloud_credential'] as Map)['provider'],
          };
        case 'generate_cloud_ssh_key':
          return {
            'private_key': '-----BEGIN RSA PRIVATE KEY-----TEST',
            'public_key': 'ssh-rsa TEST',
            'fingerprint': 'SHA256:TEST',
          };
        case 'tencent_network_lookup':
          return {
            'found': true,
            'vpc_id': 'vpc-test1234',
            'subnet_id': 'subnet-test1234',
            'subnet_cidr': '10.8.0.0/24',
          };
        case 'tencent_prepare':
          if (failAfterPrepare) {
            store.failWrite.add(CloudController.workspaceKey);
          }
          return {
            'security_group_id': 'sg-test1234',
            'key_id': 'skey-test1234',
          };
        case 'tencent_create':
          final saved =
              jsonDecode(store.secrets[CloudController.workspaceKey]!) as Map;
          final job = (saved['jobs'] as List).last as Map;
          expectSync(job['createSubmitted'], isTrue);
          expectSync(
            job['clientToken'],
            (request['cloud'] as Map)['client_token'],
          );
          expectSync(job['securityGroupId'], 'sg-test1234');
          expectSync(job['vpcId'], 'vpc-test1234');
          expectSync(job['subnetId'], 'subnet-test1234');
          expectSync((request['cloud'] as Map)['vpc_id'], job['vpcId']);
          expectSync((request['cloud'] as Map)['subnet_id'], job['subnetId']);
          if (!created.isCompleted) created.complete();
          if (createGate != null) await createGate!.future;
          if (failAfterResponse) {
            store.failWrite.add(CloudController.workspaceKey);
          }
          return {'instance_id': 'ins-test1234', 'request_id': 'request-test'};
        case 'tencent_describe':
        case 'tencent_recover':
          return {
            'exists': exists,
            'instance_id': 'ins-test1234',
            'state': state,
            'public_ip': '192.0.2.20',
            'request_id': 'request-test',
          };
        case 'tencent_release':
          return {'request_id': 'release-test'};
      }
      throw StateError('Unexpected action');
    };
    c = controllerFor(store);
    await c.initialize();
    await c.saveCredential(
      CloudProvider.tencent,
      accessKeyId: 'TestAccessId',
      accessKeySecret: 'TestSecret',
    );
  }

  CloudController controllerFor(MemoryStore storage) => CloudController(
    store: storage,
    helper: helper,
    templateLoader: () async => [CloudTemplate.tencent(templateData())],
  );
  Future<CloudMachine> create() =>
      c.startTencentCreation(c.templatesFor(CloudProvider.tencent).single);
}

void main() {
  Future<Harness> harness() async {
    final h = Harness();
    await h.init();
    addTearDown(() {
      if (!h.disposed) h.c.dispose();
    });
    return h;
  }

  testWidgets(
    'persists intent before purchase, polls running and confirms release',
    (tester) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      expect(h.c.jobs.single.instanceId, 'ins-test1234');
      expect(h.c.jobs.single.phase, CloudMachinePhase.creating);
      expect(h.store.state.machines, isEmpty);
      await tester.pump(const Duration(seconds: 5));
      expect(h.c.jobs.single.phase, CloudMachinePhase.created);
      expect(h.c.jobs.single.publicIp, '192.0.2.20');
      await h.c.requestTencentRelease(job.id);
      await tester.pump();
      expect(h.c.jobs.single.phase, CloudMachinePhase.releasing);
      h.exists = false;
      await tester.pump(const Duration(seconds: 5));
      expect(h.c.jobs.single.phase, CloudMachinePhase.released);
      await h.c.removeMachine(job.id);
      expect(h.c.jobs, isEmpty);
      expect(jsonEncode(h.helper.requests), isNot(contains('PRIVATE KEY')));
    },
  );

  testWidgets(
    'lost create response recovers by token without another purchase',
    (tester) async {
      final h = await harness();
      h.failAction = 'tencent_create';
      final job = await h.create();
      await tester.pump();
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
      expect(h.c.jobs.single.error, isNot(contains('secret-sensitive')));
      h.failAction = null;
      await h.c.refreshTencentMachine(job.id);
      expect(h.c.jobs.single.instanceId, 'ins-test1234');
      expect(h.c.jobs.single.phase, CloudMachinePhase.created);
      expect(
        h.helper.requests.where((r) => r['action'] == 'tencent_create').length,
        1,
      );
      expect(h.helper.requests.last['action'], 'tencent_recover');
    },
  );

  testWidgets(
    'empty recovery and eventual absence never mean a purchase was cancelled',
    (tester) async {
      final h = await harness();
      h.failAction = 'tencent_create';
      final job = await h.create();
      await tester.pump();
      h.failAction = null;
      h.exists = false;
      await h.c.refreshTencentMachine(job.id);
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
      await expectLater(h.c.removeMachine(job.id), throwsA(isA<UserError>()));
      await expectLater(
        h.c.removeCredential(CloudProvider.tencent),
        throwsA(isA<UserError>()),
      );
      await expectLater(
        h.c.saveCredential(
          CloudProvider.tencent,
          accessKeyId: 'OtherId',
          accessKeySecret: 'OtherSecret',
        ),
        throwsA(isA<UserError>()),
      );
      h.exists = true;
      await h.c.refreshTencentMachine(job.id);
      h.exists = false;
      await h.c.refreshTencentMachine(job.id);
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
    },
  );

  testWidgets('prepare failure allows local removal and never purchases', (
    tester,
  ) async {
    final h = await harness();
    h.failAction = 'tencent_prepare';
    final job = await h.create();
    await tester.pump();
    expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
    expect(h.c.jobs.single.createSubmitted, isFalse);
    expect(
      h.helper.requests.where((r) => r['action'] == 'tencent_create'),
      isEmpty,
    );
    await h.c.removeMachine(job.id);
    await h.c.removeCredential(CloudProvider.tencent);
  });

  testWidgets('initial persistence failure does not call cloud', (
    tester,
  ) async {
    final h = await harness();
    h.store.failWrite.add(CloudController.workspaceKey);
    await expectLater(h.create(), throwsA(isA<UserError>()));
    expect(
      h.helper.requests.where((r) => '${r['action']}'.startsWith('tencent_')),
      isEmpty,
    );
    expect(h.c.jobs, isEmpty);
  });

  testWidgets(
    'failed response persistence retains instance and recovers after restart',
    (tester) async {
      final h = await harness();
      h.failAfterResponse = true;
      final job = await h.create();
      await tester.pump();
      expect(h.c.jobs.single.instanceId, 'ins-test1234');
      expect(h.c.jobs.single.error, contains('保存'));
      h.c.dispose();
      h.disposed = true;
      h.store.failWrite.clear();
      final restored = h.controllerFor(h.store);
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.jobs.single.phase, CloudMachinePhase.unknown);
      await restored.refreshTencentMachine(job.id);
      expect(restored.jobs.single.instanceId, 'ins-test1234');
      expect(
        h.helper.requests.where((r) => r['action'] == 'tencent_create').length,
        1,
      );
    },
  );

  testWidgets(
    'release failure keeps resource, then queries asynchronous result',
    (tester) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      await h.c.refreshTencentMachine(job.id);
      h.failAction = 'tencent_release';
      await h.c.requestTencentRelease(job.id);
      await tester.pump();
      expect(h.c.jobs.single.phase, CloudMachinePhase.releaseFailed);
      await expectLater(h.c.removeMachine(job.id), throwsA(isA<UserError>()));
      h.failAction = null;
      h.exists = false;
      await h.c.refreshTencentMachine(job.id);
      expect(h.c.jobs.single.phase, CloudMachinePhase.released);
    },
  );

  testWidgets(
    'untrusted template replacement and preview entry cannot purchase',
    (tester) async {
      final h = await harness();
      final altered = templateData()..['region'] = 'ap-shanghai';
      await expectLater(
        h.c.startTencentCreation(CloudTemplate.tencent(altered)),
        throwsA(isA<UserError>()),
      );
      await expectLater(
        h.c.startPreviewCreation(
          CloudProvider.tencent,
          CloudTemplate.forProvider(CloudProvider.tencent).first,
        ),
        throwsA(isA<UserError>()),
      );
      expect(h.c.jobs, isEmpty);
    },
  );

  testWidgets(
    'restart while releasing queries only and never repeats destruction',
    (tester) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      await h.c.refreshTencentMachine(job.id);
      await h.c.requestTencentRelease(job.id);
      await tester.pump();
      h.c.dispose();
      h.disposed = true;
      final restored = h.controllerFor(h.store);
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.jobs.single.phase, CloudMachinePhase.releaseFailed);
      h.exists = false;
      await tester.pump(const Duration(seconds: 5));
      expect(restored.jobs.single.phase, CloudMachinePhase.released);
      expect(
        h.helper.requests.where((r) => r['action'] == 'tencent_release').length,
        1,
      );
    },
  );
  testWidgets(
    'purchase marker persistence failure never buys or strands a phantom purchase',
    (tester) async {
      final h = await harness();
      h.failAfterPrepare = true;
      final job = await h.create();
      await tester.pump();
      expect(h.c.jobs.single.createSubmitted, isFalse);
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(
        h.helper.requests.where((r) => r['action'] == 'tencent_create'),
        isEmpty,
      );
      h.store.failWrite.clear();
      await h.c.removeMachine(job.id);
    },
  );

  testWidgets(
    'release intent write failure keeps retryable resource without API call',
    (tester) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      await h.c.refreshTencentMachine(job.id);
      h.store.failWrite.add(CloudController.workspaceKey);
      await expectLater(
        h.c.requestTencentRelease(job.id),
        throwsA(isA<UserError>()),
      );
      expect(h.c.jobs.single.phase, CloudMachinePhase.created);
      expect(
        h.helper.requests.where((r) => r['action'] == 'tencent_release'),
        isEmpty,
      );
      h.store.failWrite.clear();
      await h.c.requestTencentRelease(job.id);
      await tester.pump();
      expect(
        h.helper.requests.where((r) => r['action'] == 'tencent_release').length,
        1,
      );
      h.exists = false;
      await h.c.refreshTencentMachine(job.id);
    },
  );

  testWidgets(
    'query after rejected release keeps retry available immediately',
    (tester) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      await h.c.refreshTencentMachine(job.id);
      h.failAction = 'tencent_release';
      await h.c.requestTencentRelease(job.id);
      await tester.pump();
      h.failAction = null;
      await h.c.refreshTencentMachine(job.id);
      expect(h.c.jobs.single.phase, CloudMachinePhase.releaseFailed);
      await h.c.requestTencentRelease(job.id);
      await tester.pump();
      expect(
        h.helper.requests.where((r) => r['action'] == 'tencent_release').length,
        2,
      );
      h.exists = false;
      await h.c.refreshTencentMachine(job.id);
    },
  );
  testWidgets(
    'poll failure stops creating spinner and preserves instance for recovery',
    (tester) async {
      final h = await harness();
      final job = await h.create();
      await tester.pump();
      h.failAction = 'tencent_describe';
      await tester.pump(const Duration(seconds: 5));
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
      expect(h.c.jobs.single.instanceId, 'ins-test1234');
      expect(h.c.jobs.single.error, contains('无法确认'));
      h.failAction = null;
      await h.c.refreshTencentMachine(job.id);
      expect(h.c.jobs.single.phase, CloudMachinePhase.created);
    },
  );
}
