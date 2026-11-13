import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';
import 'aliyun_controller_test.dart' show templateData;

class NetworkHarness {
  final store = MemoryStore();
  final helper = FakeHelper();
  late CloudController controller;
  bool disposed = false;
  String vpc = '';
  final subnets = <String, String>{};
  String? lostKind,
      rejectedKind,
      invalidKind,
      persistFailureKind,
      unconfirmedKind,
      lookupFailureKind;
  bool lostResourceExists = true;
  bool failIntent = false;
  bool instanceExists = true;
  Completer<void>? createGate;
  int instances = 0;

  Map<String, dynamic> get saved =>
      jsonDecode(store.secrets[CloudController.workspaceKey]!)
          as Map<String, dynamic>;
  List<Map<String, dynamic>> get networks => [
    for (final record in saved['networks'] as List)
      Map<String, dynamic>.from(record as Map),
  ];
  List<Map<String, dynamic>> get mutations => helper.requests
      .where((request) => request['action'] == 'aliyun_network_create')
      .toList();
  int creates(String kind) => mutations
      .where((request) => (request['aliyun'] as Map)['network_kind'] == kind)
      .length;
  String cidr(String zone) =>
      zone.endsWith('-a') ? '10.8.0.0/24' : '10.8.1.0/24';
  String subnetId(String zone) =>
      zone.endsWith('-a') ? 'vsw-test6' : 'vsw-test7';

  List<CloudTemplate> templates() => [
    for (final zone in ['cn-hangzhou-a', 'cn-hangzhou-b'])
      CloudTemplate.aliyun(
        templateData()
          ..['id'] = 'test-$zone'
          ..['runInstances']['ZoneId'] = zone,
      ),
  ];
  CloudController makeController() => CloudController(
    store: store,
    helper: helper,
    templateLoader: () async => [],
    aliyunTemplateLoader: () async => templates(),
    preparationPollAttempts: 1,
  );
  Future<void> init() async {
    helper.handler = (request, _) async {
      final action = request['action'];
      if (action == 'verify_cloud_credential') {
        return {
          'verified': true,
          'provider': (request['cloud_credential'] as Map)['provider'],
        };
      }
      if (action == 'generate_cloud_ssh_key') {
        return {
          'private_key': '-----BEGIN RSA PRIVATE KEY-----TEST',
          'public_key': 'ssh-rsa TEST',
          'fingerprint': 'SHA256:TEST',
        };
      }
      final cloud = request['aliyun'] as Map;
      if (action == 'aliyun_network_lookup' ||
          action == 'aliyun_network_create') {
        final kind = cloud['network_kind'] as String;
        final zone = cloud['template']['runInstances']['ZoneId'] as String;
        if (action == 'aliyun_network_lookup') {
          if (lookupFailureKind == kind) {
            throw const UserError('private-upstream-error');
          }
          if (failIntent) store.failWrite.add(CloudController.workspaceKey);
          if (kind == 'vpc') return {'found': vpc.isNotEmpty, 'vpc_id': vpc};
          expectSync(cloud['vpc_id'], vpc);
          return {
            'found': subnets.containsKey(zone),
            'vpc_id': vpc,
            'subnet_id': subnets[zone] ?? '',
            'subnet_cidr': cidr(zone),
          };
        }
        final record = networks.singleWhere(
          (item) =>
              item['kind'] == kind && (kind == 'vpc' || item['zone'] == zone),
        );
        expectSync(
          record['pending'],
          isTrue,
          reason: 'Every cloud mutation must have a durable independent intent',
        );
        if (kind == 'subnet') {
          expectSync(record['subnetCidr'], cloud['subnet_cidr']);
          expectSync(record['vpcId'], cloud['vpc_id']);
        }
        if (createGate != null) await createGate!.future;
        if (rejectedKind == kind) {
          return {'state': 'rejected', 'error': 'private-upstream-error'};
        }
        if (lostKind != kind || lostResourceExists) {
          if (kind == 'vpc') {
            vpc = 'vpc-test';
          } else {
            subnets[zone] = subnetId(zone);
          }
        }
        if (lostKind == kind) throw const UserError('private-upstream-error');
        if (persistFailureKind == kind) {
          store.failWrite.add(CloudController.workspaceKey);
        }
        return {
          'state': unconfirmedKind == kind ? 'unknown' : 'ready',
          'vpc_id': invalidKind == kind ? 'bad-id' : vpc,
          if (kind == 'subnet') 'subnet_id': subnets[zone],
          if (kind == 'subnet') 'subnet_cidr': cidr(zone),
        };
      }
      if (action == 'aliyun_prepare') {
        return {'security_group_id': 'sg-test', 'key_id': 'MisakaNetwork-key'};
      }
      if (action == 'aliyun_create') {
        final job = (saved['jobs'] as List).singleWhere(
          (item) => item['clientToken'] == cloud['client_token'],
        ) as Map;
        expectSync(job['createSubmitted'], isTrue);
        expectSync(job['vpcId'], cloud['vpc_id']);
        expectSync(job['subnetId'], cloud['subnet_id']);
        expectSync(job['vpcId'], vpc);
        expectSync(
          (cloud['template'] as Map)['runInstances'],
          isNot(contains('VirtualPrivateCloud')),
        );
        instances++;
        return {
          'instance_id': 'i-test$instances',
          'request_id': 'test-request',
        };
      }
      if (action == 'aliyun_release') return {'request_id': 'test-release'};
      if (action == 'aliyun_describe' || action == 'aliyun_recover') {
        return {
          'exists': instanceExists,
          'instance_id': cloud['instance_id'] ?? 'i-test1',
          'state': 'RUNNING',
          'public_ip': '192.0.2.1',
          'request_id': 'test-describe',
        };
      }
      throw StateError('Unexpected test action');
    };
    controller = makeController();
    await controller.initialize();
    await controller.saveCredential(
      CloudProvider.aliyun,
      accessKeyId: 'TestAccessId',
      accessKeySecret: 'TestSecret',
    );
  }

  Future<CloudMachine> start({int template = 0}) =>
      controller.startCloudCreation(
        CloudProvider.aliyun,
        controller.templatesFor(CloudProvider.aliyun)[template],
      );
  Future<void> restart() async {
    controller.dispose();
    controller = makeController();
    await controller.initialize();
  }

  void dispose() {
    if (!disposed) controller.dispose();
    disposed = true;
  }
}

void main() {
  final active = <NetworkHarness>[];
  void networkTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final value in active) {
          value.dispose();
        }
        active.clear();
      }
    });
  }

  Future<NetworkHarness> harness() async {
    final value = NetworkHarness();
    await value.init();
    active.add(value);
    return value;
  }

  networkTest('concurrent jobs serialize shared network creation', (
    tester,
  ) async {
    final h = await harness();
    h.createGate = Completer<void>();
    await Future.wait([h.start(), h.start()]);
    await tester.pump();
    expect(h.creates('vpc'), 1);
    expect(h.creates('subnet'), 0);
    expect(h.instances, 0);
    h.createGate!.complete();
    await tester.pump();
    expect(h.creates('vpc'), 1);
    expect(h.creates('subnet'), 1);
    expect(h.instances, 2);
  });

  networkTest(
    'same region reuses VPC and same zone reuses subnet across jobs',
    (tester) async {
      final h = await harness();
      await h.start();
      await tester.pump();
      await h.start();
      await tester.pump();
      await h.start(template: 1);
      await tester.pump();
      expect(h.creates('vpc'), 1);
      expect(h.creates('subnet'), 2);
      expect(h.instances, 3);
      expect(h.controller.jobs.map((item) => item.vpcId).toSet(), {'vpc-test'});
      expect(h.controller.jobs.map((item) => item.subnetId).toList(), [
        'vsw-test6',
        'vsw-test6',
        'vsw-test7',
      ]);
      expect(h.networks.length, 3);
    },
  );

  networkTest('release and record removal preserve shared network ledger', (
    tester,
  ) async {
    final h = await harness();
    final job = await h.start();
    await tester.pump();
    await h.controller.refreshCloudMachine(job.id);
    final before = h.networks;
    await h.controller.requestCloudRelease(job.id);
    await tester.pump();
    h.instanceExists = false;
    await h.controller.refreshCloudMachine(job.id);
    await h.controller.removeMachine(job.id);
    expect(h.networks, before);
    expect(
      h.helper.requests.any(
        (item) => '${item['action']}'.contains('delete_network'),
      ),
      isFalse,
    );
    await h.controller.removeCredential(CloudProvider.aliyun);
    expect(h.networks, before);
  });

  for (final kind in ['vpc', 'subnet']) {
    networkTest(
      '$kind lookup error protects a previously confirmed shared network',
      (tester) async {
        final h = await harness();
        final first = await h.start();
        await tester.pump();
        await h.controller.requestCloudRelease(first.id);
        await tester.pump();
        h.instanceExists = false;
        await h.controller.refreshCloudMachine(first.id);
        await h.controller.removeMachine(first.id);
        h.lookupFailureKind = kind;
        final other = await h.start();
        await tester.pump();
        expect(h.controller.jobs.single.error, contains('网络创建结果待核实'));
        expect(
          h.networks.singleWhere((item) => item['kind'] == kind)['pending'],
          isTrue,
        );
        expect(h.instances, 1);
        expect(h.creates(kind), 1);
        await h.controller.removeMachine(other.id);
        await expectLater(
          h.controller.removeCredential(CloudProvider.aliyun),
          throwsA(isA<UserError>()),
        );
      },
    );

    networkTest(
      '$kind lost response recovers by lookup on retry without duplicate mutation',
      (tester) async {
        final h = await harness();
        h.lostKind = kind;
        final job = await h.start();
        await tester.pump();
        expect(h.controller.jobs.single.error, contains('网络创建结果待核实'));
        expect(
          h.controller.jobs.single.error,
          isNot(contains('private-upstream')),
        );
        expect(h.instances, 0);
        expect(
          h.networks.singleWhere((item) => item['kind'] == kind)['pending'],
          isTrue,
        );
        h.lostKind = null;
        await h.controller.retryCloudPreparation(job.id);
        await tester.pump();
        expect(h.instances, 1);
        expect(h.creates(kind), 1);
        expect(h.networks.every((item) => item['pending'] == false), isTrue);
        if (kind == 'subnet') {
          final lookups = h.helper.requests
              .where(
                (item) =>
                    item['action'] == 'aliyun_network_lookup' &&
                    (item['aliyun'] as Map)['network_kind'] == 'subnet',
              )
              .toList();
          expect((lookups.last['aliyun'] as Map)['subnet_cidr'], '10.8.0.0/24');
        }
      },
    );

    networkTest(
      '$kind unknown outcome survives job removal and restart and protects credentials',
      (tester) async {
        final h = await harness();
        h.lostKind = kind;
        h.lostResourceExists = false;
        final job = await h.start();
        await tester.pump();
        await h.controller.removeMachine(job.id);
        await expectLater(
          h.controller.removeCredential(CloudProvider.aliyun),
          throwsA(isA<UserError>()),
        );
        await expectLater(
          h.controller.saveCredential(
            CloudProvider.aliyun,
            accessKeyId: 'OtherId',
            accessKeySecret: 'OtherSecret',
          ),
          throwsA(isA<UserError>()),
        );
        await h.restart();
        h.lostKind = null;
        final other = await h.start();
        await tester.pump();
        await h.controller.retryCloudPreparation(other.id);
        await tester.pump();
        expect(h.creates(kind), 1);
        expect(h.instances, 0);
        expect(h.controller.jobs.single.phase, CloudMachinePhase.createFailed);
        expect(h.controller.jobs.single.error, contains('网络创建结果待核实'));
        expect(
          h.networks.singleWhere((item) => item['kind'] == kind)['pending'],
          isTrue,
        );
      },
    );

    networkTest(
      '$kind confirmation write failure leaves durable intent for recovery',
      (tester) async {
        final h = await harness();
        h.persistFailureKind = kind;
        final job = await h.start();
        await tester.pump();
        expect(h.instances, 0);
        expect(
          h.networks.singleWhere((item) => item['kind'] == kind)['pending'],
          isTrue,
        );
        h.persistFailureKind = null;
        h.store.failWrite.clear();
        await h.restart();
        await h.controller.retryCloudPreparation(job.id);
        await tester.pump();
        expect(h.instances, 1);
        expect(h.creates(kind), 1);
      },
    );

    networkTest(
      '$kind unknown result pins the returned ID and refuses another same-name resource',
      (tester) async {
        final h = await harness();
        h.unconfirmedKind = kind;
        final job = await h.start();
        await tester.pump();
        final idField = kind == 'vpc' ? 'vpcId' : 'subnetId';
        final expectedId = kind == 'vpc' ? 'vpc-test' : 'vsw-test6';
        final record = h.networks.singleWhere((item) => item['kind'] == kind);
        expect(record[idField], expectedId);
        expect(record['pending'], isTrue);
        h.unconfirmedKind = null;
        if (kind == 'vpc') {
          h.vpc = 'vpc-other';
        } else {
          h.subnets['cn-hangzhou-a'] = 'subnet-other';
        }
        await h.controller.retryCloudPreparation(job.id);
        await tester.pump();
        expect(h.instances, 0);
        expect(h.creates(kind), 1);
        expect(
          h.networks.singleWhere((item) => item['kind'] == kind)[idField],
          expectedId,
        );
        final lookup = h.helper.requests.lastWhere(
          (request) =>
              request['action'] == 'aliyun_network_lookup' &&
              (request['aliyun'] as Map)['network_kind'] == kind,
        );
        expect(
          (lookup['aliyun'] as Map)[kind == 'vpc' ? 'vpc_id' : 'subnet_id'],
          expectedId,
        );
      },
    );

    for (final unconfirmed in [false, true]) {
      networkTest(
        '$kind ${unconfirmed ? 'unknown' : 'ready'} write failure retains known ID in memory',
        (tester) async {
          final h = await harness();
          h.persistFailureKind = kind;
          if (unconfirmed) h.unconfirmedKind = kind;
          final job = await h.start();
          await tester.pump();
          h.persistFailureKind = null;
          h.unconfirmedKind = null;
          h.store.failWrite.clear();
          if (kind == 'vpc') {
            h.vpc = 'vpc-other';
          } else {
            h.subnets['cn-hangzhou-a'] = 'subnet-other';
          }
          await h.controller.retryCloudPreparation(job.id);
          await tester.pump();
          expect(h.instances, 0);
          expect(h.creates(kind), 1);
          final record = h.networks.singleWhere((item) => item['kind'] == kind);
          expect(
            record[kind == 'vpc' ? 'vpcId' : 'subnetId'],
            kind == 'vpc' ? 'vpc-test' : 'vsw-test6',
          );
          expect(record['pending'], isTrue);
        },
      );
    }

    networkTest(
      '$kind definite rejection can be retried but does not purchase early',
      (tester) async {
        final h = await harness();
        h.rejectedKind = kind;
        final job = await h.start();
        await tester.pump();
        expect(h.instances, 0);
        expect(h.controller.jobs.single.error, contains('拒绝了网络创建'));
        expect(
          h.controller.jobs.single.error,
          isNot(contains('private-upstream')),
        );
        expect(
          h.networks.singleWhere((item) => item['kind'] == kind)['pending'],
          isFalse,
        );
        h.rejectedKind = null;
        await h.controller.retryCloudPreparation(job.id);
        await tester.pump();
        expect(h.instances, 1);
        expect(h.creates(kind), 2);
      },
    );
  }

  networkTest(
    'network intent persistence failure prevents all network mutations and purchase',
    (tester) async {
      final h = await harness();
      h.failIntent = true;
      final job = await h.start();
      await tester.pump();
      expect(h.mutations, isEmpty);
      expect(h.instances, 0);
      h.failIntent = false;
      h.store.failWrite.clear();
      await h.controller.retryCloudPreparation(job.id);
      await tester.pump();
      expect(h.instances, 1);
    },
  );

  networkTest(
    'interrupted network mutation remains lookup-only after restart',
    (tester) async {
      final h = await harness();
      h.createGate = Completer<void>();
      final job = await h.start();
      await tester.pump();
      expect(h.networks.single['pending'], isTrue);
      h.controller.dispose();
      h.disposed = true;
      h.createGate!.complete();
      await tester.pump();
      h.createGate = null;
      h.controller = h.makeController();
      h.disposed = false;
      await h.controller.initialize();
      expect(h.controller.jobs.single.phase, CloudMachinePhase.createFailed);
      await h.controller.retryCloudPreparation(job.id);
      await tester.pump();
      expect(h.creates('vpc'), 1);
      expect(h.instances, 1);
    },
  );

  networkTest(
    'malformed network confirmation cannot purchase or clear pending intent',
    (tester) async {
      final h = await harness();
      h.invalidKind = 'subnet';
      await h.start();
      await tester.pump();
      expect(h.instances, 0);
      expect(
        h.networks.singleWhere((item) => item['kind'] == 'subnet')['pending'],
        isTrue,
      );
      expect(h.controller.jobs.single.error, contains('网络创建结果待核实'));
    },
  );

  networkTest('preparation retry is unavailable once purchase was submitted', (
    tester,
  ) async {
    final h = await harness();
    final job = await h.start();
    await tester.pump();
    await expectLater(
      h.controller.retryCloudPreparation(job.id),
      throwsA(isA<UserError>()),
    );
    expect(h.instances, 1);
  });

  networkTest('duplicate network ledger identity fails closed at startup', (
    tester,
  ) async {
    final h = await harness();
    await h.start();
    await tester.pump();
    final value = h.saved;
    (value['networks'] as List).add(h.networks.first);
    h.store.secrets[CloudController.workspaceKey] = jsonEncode(value);
    await h.restart();
    expect(h.controller.initialized, isFalse);
    expect(h.controller.startupError, isNotNull);
  });

  networkTest(
    'stored legacy network template fails closed without overwriting evidence',
    (tester) async {
      final h = await harness();
      await h.start();
      await tester.pump();
      final value = h.saved;
      (value['jobs'] as List)
          .single['template']['aliyun']['runInstances']['VirtualPrivateCloud'] = {
        'VpcId': 'vpc-legacy',
        'SubnetId': 'subnet-legacy',
      };
      final legacy = jsonEncode(value);
      h.store.secrets[CloudController.workspaceKey] = legacy;
      await h.restart();
      expect(h.controller.initialized, isFalse);
      expect(h.controller.startupError, isNotNull);
      expect(h.store.secrets[CloudController.workspaceKey], legacy);
    },
  );

  for (final entry in {
    'sshUsername': 'user;command',
    'sshCidr': '203.0.113.8/32',
    'grpcCidr': '203.0.113.0/24',
  }.entries) {
    networkTest(
      'stored configurable ${entry.key} fails closed without overwriting evidence',
      (tester) async {
        final h = await harness();
        await h.start();
        await tester.pump();
        final value = h.saved;
        (value['jobs'] as List).single['template']['aliyun'][entry.key] =
            entry.value;
        final legacy = jsonEncode(value);
        h.store.secrets[CloudController.workspaceKey] = legacy;
        final requestCount = h.helper.requests.length;
        await h.restart();
        expect(h.controller.initialized, isFalse);
        expect(h.controller.startupError, isNotNull);
        expect(h.store.secrets[CloudController.workspaceKey], legacy);
        expect(h.helper.requests.length, requestCount);
      },
    );
  }
}
