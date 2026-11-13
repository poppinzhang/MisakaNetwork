import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';

import 'deployment_controller_test.dart' show settleUntil, credentials;
import 'fakes.dart';
import 'tencent_controller_test.dart' show templateData;

const resourceId = 'cloud-fixture';
const privateKey = '-----BEGIN RSA PRIVATE KEY-----TEST-SECRET';
const fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

class DeployHarness {
  final store = MemoryStore();
  final helper = FakeHelper();
  final gateway = FakeGateway();
  late AppController controller;
  bool confirmation = false, failDeployment = false;
  String cloudState = 'RUNNING', cloudIp = '192.0.2.20';
  Completer<void>? describeGate, deploymentGate;
  int describeCalls = 0;

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
          'provider': 'tencent',
          'accessKeyId': 'TestAccessId',
          'accessKeySecret': 'TestSecret',
          'checkedAt': '2026-01-01T00:00:00Z',
        },
      ],
      'jobs': [
        CloudMachine(
          id: resourceId,
          name: '测试云服务器',
          provider: CloudProvider.tencent,
          template: CloudTemplate.tencent(templateData()),
          phase: CloudMachinePhase.created,
          isReal: true,
          createSubmitted: true,
          instanceId: 'ins-test1234',
          publicIp: cloudIp,
          region: 'ap-guangzhou',
          credentialId: 'TestAccessId',
          clientToken: 'test-client-token-1234',
        ).toJson(),
      ],
      'networks': [],
    });
    helper.handler = (request, progress) async {
      switch (request['action']) {
        case 'tencent_describe':
          describeCalls++;
          await describeGate?.future;
          return {
            'exists': true,
            'instance_id': 'ins-test1234',
            'state': cloudState,
            'public_ip': cloudIp,
            'request_id': 'test-request',
          };
        case 'init_pki':
          return {};
        case 'deploy':
          expectSync(request['username'], 'ubuntu');
          expectSync(request['enable_linger_with_sudo'], isTrue);
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
        case 'tencent_release':
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
      cloudTemplateLoader: () async => [CloudTemplate.tencent(templateData())],
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
  Future<DeployHarness> harness() async {
    final h = DeployHarness();
    await h.init();
    addTearDown(() => h.controller.dispose());
    return h;
  }

  test('cloud key deploy pins first host automatically and never saves key in state', () async {
    final h = await harness();
    h.confirmation = true;
    h.deploymentGate = Completer<void>();
    await h.controller.startTencentDeployment(resourceId);
    await settleUntil(() => h.deployments.length == 2);
    final machine = h.controller.tencentMachine(resourceId)!;
    expect(machine.id, 'tencent-$resourceId');
    expect(machine.canConnect, isFalse);
    expect(machine.fingerprint, fingerprint);
    expect(h.describeCalls, 1);
    expect(h.controller.cloud.isDeployingTencent(resourceId), isTrue);
    await expectLater(
      h.controller.cloud.requestTencentRelease(resourceId),
      throwsA(isA<UserError>()),
    );
    h.deploymentGate!.complete();
    await settleUntil(() => h.controller.deploying == 0);
    expect(h.deployments.length, 2);
    expect(h.deployments.last['host_key_fingerprint'], fingerprint);
    expect(h.controller.tencentMachine(resourceId)!.fingerprint, fingerprint);
    expect(h.controller.tencentMachine(resourceId)!.canConnect, isTrue);
    expect(
      h.controller.tencentMachine(resourceId)!.deploymentUsername,
      'ubuntu',
    );
    expect(h.controller.cloud.isDeployingTencent(resourceId), isFalse);
    expect(h.store.state.encode(), isNot(contains(privateKey)));
    expect(
      h.store.secrets[CloudController.workspaceKey],
      isNot(contains(privateKey)),
    );
  });

  test(
    'retry and restart reuse linked machine, stored key, and host pin',
    () async {
      final h = await harness();
      h.confirmation = true;
      h.failDeployment = true;
      await h.controller.startTencentDeployment(resourceId);
      await settleUntil(() => h.controller.deploying == 0);
      expect(h.controller.state.machines.single.deploymentError, isNotEmpty);
      await h.restart();
      h.failDeployment = false;
      await h.controller.startTencentDeployment(resourceId);
      await settleUntil(() => h.controller.deploying == 0);
      expect(h.controller.state.machines.length, 1);
      expect(h.controller.state.machines.single.canConnect, isTrue);
      expect(h.controller.state.machines.single.deploymentUsername, 'ubuntu');
      expect(h.deployments.last['host_key_fingerprint'], fingerprint);
    },
  );

  test(
    'old authentication failure retries Ubuntu on the same pinned node',
    () async {
      final h = await harness();
      h.controller.state.machines.add(
        Machine(
          id: 'tencent-$resourceId',
          name: '测试云服务器',
          host: h.cloudIp,
          caCert: '',
          clientCert: '',
          clientKey: '',
          fingerprint: fingerprint,
          deploymentError: 'SSH 认证失败，请检查凭据和主机指纹',
        ),
      );
      await h.store.save(h.controller.state);
      await h.restart();
      await h.controller.startTencentDeployment(resourceId);
      await settleUntil(() => h.controller.deploying == 0);
      expect(h.controller.state.machines.length, 1);
      expect(h.deployments.single['username'], 'ubuntu');
      expect(h.deployments.single['host_key_fingerprint'], fingerprint);
      expect(h.controller.state.machines.single.deploymentUsername, 'ubuntu');
      expect(h.controller.state.machines.single.canConnect, isTrue);
    },
  );

  for (final old in ['root', 'unrecorded-success', 'unrecorded-interrupted']) {
    test('does not silently install another user service for $old', () async {
      final h = await harness();
      final success = old != 'unrecorded-interrupted';
      h.controller.state.machines.add(
        Machine(
          id: 'tencent-$resourceId',
          name: '测试云服务器',
          host: h.cloudIp,
          caCert: success ? 'ca' : '',
          clientCert: success ? 'cert' : '',
          clientKey: success ? 'key' : '',
          fingerprint: fingerprint,
          deploymentUsername: old == 'root' ? 'root' : '',
          deploymentError: success ? '' : '上次部署已中断，请检查远程服务。',
        ),
      );
      await expectLater(
        h.controller.startTencentDeployment(resourceId),
        throwsA(
          isA<UserError>().having(
            (e) => e.message,
            'message',
            contains('不能直接切换账号'),
          ),
        ),
      );
      expect(h.deployments, isEmpty);
      expect(
        h.controller.state.machines.single.deploymentUsername,
        old == 'root' ? 'root' : '',
      );
      expect(h.controller.cloud.isDeployingTencent(resourceId), isFalse);
    });
  }

  test('ordinary deployment cannot opt into cloud sudo preparation', () async {
    final h = await harness();
    final delegate = h.helper.handler!;
    h.helper.handler = (request, progress) async {
      if (request['action'] == 'deploy') {
        expectSync(request.containsKey('enable_linger_with_sudo'), isFalse);
        return credentials;
      }
      return delegate(request, progress);
    };
    await h.controller.startDeployment(
      name: '普通节点',
      host: '192.0.2.30',
      port: 20001,
      request: {
        'username': 'ubuntu',
        'private_key': privateKey,
        'enable_linger_with_sudo': true,
      },
    );
    await settleUntil(() => h.controller.deploying == 0);
    expect(h.controller.state.machines.single.deploymentUsername, isEmpty);
  });

  test(
    'duplicate click during cloud query cannot start two deployments',
    () async {
      final h = await harness();
      h.describeGate = Completer<void>();
      final first = h.controller.startTencentDeployment(resourceId);
      await settleUntil(() => h.describeCalls == 1);
      await expectLater(
        h.controller.startTencentDeployment(resourceId),
        throwsA(isA<UserError>()),
      );
      h.describeGate!.complete();
      await first;
      await settleUntil(() => h.controller.deploying == 0);
      expect(h.deployments.length, 1);
      expect(h.controller.state.machines.length, 1);
    },
  );

  test(
    'invalid host identity releases cloud lease and retains retryable machine',
    () async {
      final h = await harness();
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'deploy') {
          return {'needs_confirmation': true, 'fingerprint': 'invalid'};
        }
        return delegate(request, progress);
      };
      await h.controller.startTencentDeployment(resourceId);
      await settleUntil(() => h.controller.deploying == 0);
      expect(h.controller.cloud.isDeployingTencent(resourceId), isFalse);
      expect(h.deployments.length, 1);
      expect(h.controller.state.machines.single.canConnect, isFalse);
      expect(
        h.controller.state.machines.single.deploymentError,
        contains('无法验证服务器身份'),
      );
    },
  );

  for (final state in ['STOPPED', 'TERMINATED', 'PENDING']) {
    test('fresh $state cloud state prevents deployment', () async {
      final h = await harness();
      h.cloudState = state;
      await expectLater(
        h.controller.startTencentDeployment(resourceId),
        throwsA(isA<UserError>()),
      );
      expect(h.deployments, isEmpty);
      expect(h.controller.state.machines, isEmpty);
      expect(h.controller.cloud.isDeployingTencent(resourceId), isFalse);
    });
  }

  test(
    'missing secure key stops without regenerating or creating machine',
    () async {
      final h = await harness();
      h.store.secrets.remove(CloudController.sshIdentityKey);
      await expectLater(
        h.controller.startTencentDeployment(resourceId),
        throwsA(isA<UserError>()),
      );
      expect(h.deployments, isEmpty);
      expect(h.controller.state.machines, isEmpty);
      expect(h.controller.cloud.isDeployingTencent(resourceId), isFalse);
      expect(
        h.helper.requests.where((r) => r['action'] == 'generate_cloud_ssh_key'),
        isEmpty,
      );
    },
  );

  test(
    'placeholder save failure stops before SSH and releases cloud lease',
    () async {
      final h = await harness();
      h.store.failSave = true;
      await expectLater(
        h.controller.startTencentDeployment(resourceId),
        throwsA(isA<UserError>()),
      );
      expect(h.deployments, isEmpty);
      expect(h.controller.cloud.isDeployingTencent(resourceId), isFalse);
      expect(h.controller.state.machines, isEmpty);
    },
  );

  test('existing unrelated host is never silently adopted', () async {
    final h = await harness();
    final existing = Machine(
      id: 'ordinary-node',
      name: '原有机器',
      host: h.cloudIp,
      caCert: 'ca',
      clientCert: 'cert',
      clientKey: 'key',
    );
    await h.controller.addMachine(existing);
    await expectLater(
      h.controller.startTencentDeployment(resourceId),
      throwsA(isA<UserError>()),
    );
    expect(h.deployments, isEmpty);
    expect(h.controller.state.machines.single.id, existing.id);
    expect(h.controller.cloud.isDeployingTencent(resourceId), isFalse);
  });

  test(
    'changed cloud address retains old pinned machine without SSH',
    () async {
      final h = await harness();
      await h.controller.startTencentDeployment(resourceId);
      await settleUntil(() => h.controller.deploying == 0);
      final saved = h.controller.state.machines.single;
      h.cloudIp = '192.0.2.21';
      await expectLater(
        h.controller.startTencentDeployment(resourceId),
        throwsA(isA<UserError>()),
      );
      expect(h.deployments.length, 1);
      expect(h.controller.state.machines.single.host, saved.host);
      expect(h.controller.cloudMachineUsable(saved), isFalse);
    },
  );

  test(
    'linked machine cannot bypass cloud deployment with manual credentials',
    () async {
      final h = await harness();
      await h.controller.startTencentDeployment(resourceId);
      await settleUntil(() => h.controller.deploying == 0);
      final machine = h.controller.state.machines.single;
      await expectLater(
        h.controller.startDeployment(
          name: machine.name,
          host: machine.host,
          port: 20001,
          existing: machine,
          request: {'username': 'root', 'password': 'test'},
        ),
        throwsA(isA<UserError>()),
      );
      expect(h.deployments.length, 1);
    },
  );

  test(
    'cloud release disables linked polling dispatch and cancellation',
    () async {
      final h = await harness();
      await h.controller.startTencentDeployment(resourceId);
      await settleUntil(() => h.controller.deploying == 0);
      final machine = h.controller.state.machines.single;
      final task = TicketTask(id: 'task', name: '测试任务', accountId: 'account');
      h.controller.state.tasks.add(task);
      await h.controller.cloud.requestTencentRelease(resourceId);
      expect(h.controller.cloudMachineUsable(machine), isFalse);
      final before = h.gateway.statusRequests.length;
      await h.controller.refresh();
      expect(h.gateway.statusRequests.length, before);
      expect(
        await h.controller.dispatch(task, [machine]),
        contains(machine.name),
      );
      expect(h.gateway.submitted, isEmpty);
      await expectLater(
        h.controller.cancel(machine, 'task'),
        throwsA(isA<UserError>()),
      );
      expect(h.gateway.cancelled, isEmpty);
    },
  );
}
