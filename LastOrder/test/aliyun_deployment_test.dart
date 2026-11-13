import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';

import 'deployment_controller_test.dart' show settleUntil, credentials;
import 'fakes.dart';
import 'aliyun_controller_test.dart' show templateData;

const resourceId = 'cloud-fixture';
const privateKey = '-----BEGIN RSA PRIVATE KEY-----TEST-SECRET';
const fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

class AliyunDeployHarness {
  final store = MemoryStore();
  final helper = FakeHelper();
  final gateway = FakeGateway();
  late AppController controller;
  bool confirmation = false, failDeployment = false, cloudExists = true;
  String cloudState = 'RUNNING', cloudIp = '192.0.2.20';
  Completer<void>? describeGate, deploymentGate;
  int describeCalls = 0;
  String sshUsername = 'root';

  List<Map<String, dynamic>> get deployments => helper.requests
      .where((request) => request['action'] == 'deploy')
      .toList();

  Future<void> init() async {
    store.secrets[CloudController.sshIdentityKey] = jsonEncode({
      'private_key': privateKey,
      'public_key': 'ssh-rsa TEST',
      'fingerprint': 'SHA256:TEST',
    });
    store.secrets[CloudController.workspaceKey] = jsonEncode({
      'version': 1,
      'credentials': [
        {
          'provider': 'aliyun',
          'accessKeyId': 'TestAccessId',
          'accessKeySecret': 'TestSecret',
          'checkedAt': '2026-01-01T00:00:00Z',
        },
      ],
      'jobs': [
        CloudMachine(
          id: resourceId,
          name: '测试云服务器',
          provider: CloudProvider.aliyun,
          template: CloudTemplate.aliyun(
            templateData()..['sshUsername'] = sshUsername,
          ),
          phase: CloudMachinePhase.created,
          isReal: true,
          createSubmitted: true,
          instanceId: 'i-test1234',
          publicIp: cloudIp,
          region: 'cn-hangzhou',
          credentialId: 'TestAccessId',
          clientToken: 'test-client-token-1234',
        ).toJson(),
      ],
      'networks': [],
    });
    helper.handler = (request, progress) async {
      switch (request['action']) {
        case 'aliyun_describe':
          describeCalls++;
          await describeGate?.future;
          return {
            'exists': cloudExists,
            'instance_id': 'i-test1234',
            'state': cloudState,
            'public_ip': cloudIp,
            'request_id': 'test-request',
          };
        case 'init_pki':
          return {};
        case 'deploy':
          expectSync(request['username'], sshUsername);
          expectSync(request['enable_linger_with_sudo'], isNull);
          expectSync(request['port'], 22);
          expectSync(request['grpc_port'], 20001);
          expectSync(request['private_key'], privateKey);
          expectSync(request.containsKey('private_key_path'), isFalse);
          expectSync(request.containsKey('password'), isFalse);
          expectSync(store.state.encode(), isNot(contains(privateKey)));
          if (confirmation && request['host_key_fingerprint'] == '') {
            return {'needs_confirmation': true, 'fingerprint': fingerprint};
          }
          await deploymentGate?.future;
          if (failDeployment) throw const UserError('测试部署失败');
          return credentials;
        case 'aliyun_release':
          return {'request_id': 'release-test'};
        default:
          throw StateError('Unexpected action ${request['action']}');
      }
    };
    await open();
  }

  Future<void> open() async {
    controller = AppController(
      store: store,
      gateway: gateway,
      runtime: FakeRuntime(),
      helper: helper,
      cloudTemplateLoader: () async => [],
      aliyunTemplateLoader: () async => [
        CloudTemplate.aliyun(templateData()..['sshUsername'] = sshUsername),
      ],
    );
    await controller.initialize(poll: false);
    await controller.cloud.initialize();
    expect(controller.cloud.initialized, isTrue);
    expect(controller.cloud.sshReady, isTrue);
  }

  Future<void> restart() async {
    controller.dispose();
    await open();
  }
}

void main() {
  test('aliyun deployment uses the saved template login account', () async {
    final h = AliyunDeployHarness()..sshUsername = 'custom-user';
    await h.init();
    addTearDown(() => h.controller.dispose());
    await h.controller.startCloudDeployment(resourceId);
    await settleUntil(() => h.controller.deploying == 0);
    expect(h.deployments.single['username'], 'custom-user');
    expect(h.deployments.single['enable_linger_with_sudo'], isNull);
    expect(
      h.controller.cloudMachine(resourceId)!.deploymentUsername,
      'custom-user',
    );
    await h.restart();
    expect(
      h.controller.cloudMachine(resourceId)!.deploymentUsername,
      'custom-user',
    );
  });

  Future<AliyunDeployHarness> harness() async {
    final h = AliyunDeployHarness();
    await h.init();
    addTearDown(() => h.controller.dispose());
    return h;
  }

  test(
    'Aliyun root key deployment pins host and retains provider association',
    () async {
      final h = await harness();
      h.confirmation = true;
      h.deploymentGate = Completer<void>();
      await h.controller.startCloudDeployment(resourceId);
      await settleUntil(() => h.deployments.length == 2);
      final machine = h.controller.cloudMachine(resourceId)!;
      expect(machine.id, 'aliyun-$resourceId');
      expect(machine.deploymentUsername, 'root');
      expect(machine.fingerprint, fingerprint);
      expect(h.controller.cloudIdForMachine(machine), resourceId);
      expect(h.controller.cloud.isDeployingCloud(resourceId), isTrue);
      await expectLater(
        h.controller.cloud.requestCloudRelease(resourceId),
        throwsA(isA<UserError>()),
      );
      h.deploymentGate!.complete();
      await settleUntil(() => h.controller.deploying == 0);
      expect(h.controller.cloudMachine(resourceId)!.canConnect, isTrue);
      expect(h.controller.cloud.isDeployingCloud(resourceId), isFalse);
      expect(h.store.state.encode(), isNot(contains(privateKey)));
      await h.restart();
      expect(h.controller.cloudMachine(resourceId)!.fingerprint, fingerprint);
      expect(
        h.controller.cloudMachineUsable(h.controller.cloudMachine(resourceId)!),
        isTrue,
      );
    },
  );

  test(
    'Aliyun deployment cannot bypass cloud card or use stopped instance',
    () async {
      final h = await harness();
      h.cloudState = 'STOPPED';
      await expectLater(
        h.controller.startCloudDeployment(resourceId),
        throwsA(isA<UserError>()),
      );
      expect(h.deployments, isEmpty);
      expect(h.controller.cloud.isDeployingCloud(resourceId), isFalse);
      await expectLater(
        h.controller.startDeployment(
          name: '绕过测试',
          host: h.cloudIp,
          port: 20001,
          request: {'username': 'root', 'private_key': privateKey},
          cloudId: resourceId,
        ),
        throwsA(isA<UserError>()),
      );
      expect(h.deployments, isEmpty);
    },
  );

  test(
    'Aliyun failed deployment retries original machine with same root identity',
    () async {
      final h = await harness();
      h.failDeployment = true;
      await h.controller.startCloudDeployment(resourceId);
      await settleUntil(() => h.controller.deploying == 0);
      final id = h.controller.cloudMachine(resourceId)!.id;
      h.failDeployment = false;
      await h.controller.startCloudDeployment(resourceId);
      await settleUntil(() => h.controller.deploying == 0);
      expect(h.controller.cloudMachine(resourceId)!.id, id);
      expect(h.controller.state.machines.length, 1);
      expect(h.controller.cloudMachine(resourceId)!.deploymentUsername, 'root');
    },
  );
  test('Aliyun confirmed release hides linked node across restart while retaining history', () async {
    final h = await harness();
    await h.controller.startCloudDeployment(resourceId);
    await settleUntil(() => h.controller.deploying == 0);
    final machine = h.controller.cloudMachine(resourceId)!;
    expect(h.controller.currentMachines, contains(machine));
    await h.controller.cloud.requestCloudRelease(resourceId);
    await settleUntil(
      () => h.helper.requests.any((r) => r['action'] == 'aliyun_release'),
    );
    h.cloudExists = false;
    await Future<void>.delayed(Duration.zero);
    await h.controller.cloud.refreshCloudMachine(resourceId);
    expect(h.controller.cloud.visibleJobs, isEmpty);
    expect(h.controller.currentMachines, isEmpty);
    expect(h.controller.state.machines, contains(machine));
    expect(h.controller.cloudMachineUsable(machine), isFalse);
    await h.restart();
    expect(h.controller.currentMachines, isEmpty);
    expect(h.controller.state.machines.single.id, machine.id);
  });
}
