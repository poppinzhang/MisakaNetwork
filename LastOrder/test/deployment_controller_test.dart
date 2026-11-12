import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';

import 'fakes.dart';

const credentials = <String, dynamic>{
  'ca_cert': 'ca',
  'client_cert': 'cert',
  'client_key': 'key',
};
Map<String, dynamic> request([String host = '192.0.2.1']) => {
  'host': host,
  'username': 'test-user',
  'password': 'test-password',
  'port': 22,
};

Future<void> settleUntil(bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue, reason: 'Background deployment did not settle');
}

Future<void> start(
  AppController c, {
  String host = '192.0.2.1',
  String name = '测试机器',
  Machine? existing,
  List<String> importedFiles = const [],
}) => c.startDeployment(
  name: name,
  host: host,
  port: defaultSistersPort,
  request: request(host),
  existing: existing,
  importedFiles: importedFiles,
);

void main() {
  test(
    'parallel deployments appear immediately with independent progress',
    () async {
      final gates = <String, Completer<Map<String, dynamic>>>{};
      final helper = FakeHelper()
        ..handler = (request, _) async {
          if (request['action'] != 'deploy') return {};
          return (gates[request['host'] as String] = Completer()).future;
        };
      final store = MemoryStore();
      final gateway = FakeGateway();
      final c = controller(store: store, helper: helper, gateway: gateway);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await start(c);
      await start(c, host: '192.0.2.2', name: '第二台');
      await settleUntil(() => gates.length == 2);
      final first = c.state.machines.first;
      final second = c.state.machines.last;
      expect(c.deploying, 2);
      expect(store.state.machines.every((m) => m.deploymentPending), isTrue);
      expect(store.state.encode(), isNot(contains('test-password')));
      expect(store.state.encode(), isNot(contains('test-user')));
      await c.refresh();
      expect(gateway.statusRequests, isEmpty);
      helper.progressCallbacks[first.host]!(
        const DeploymentProgress(percent: 47, stage: '发送安装包'),
      );
      helper.progressCallbacks[second.host]!(
        const DeploymentProgress(percent: 82, stage: '检查运行时'),
      );
      expect(c.deployments[first.id]?.percent, 47);
      expect(c.deployments[second.id]?.percent, 82);
      gates[first.host]!.complete(credentials);
      await settleUntil(() => c.deploying == 1);
      expect(c.state.machines.first.canConnect, isTrue);
      expect(c.state.machines.last.deploymentPending, isTrue);
      gates[second.host]!.complete(credentials);
      await settleUntil(() => c.deploying == 0);
      expect(c.state.machines.every((m) => m.canConnect), isTrue);
      expect(
        helper.requests.where((r) => r['action'] == 'init_pki'),
        hasLength(1),
      );
    },
  );

  test(
    'duplicate address is reserved before the first save completes',
    () async {
      final saveGate = Completer<void>();
      final deploymentGate = Completer<void>();
      final store = MemoryStore()..beforeSave = (_) => saveGate.future;
      final helper = FakeHelper()..deployGate = deploymentGate.future;
      final c = controller(store: store, helper: helper);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      final first = start(c);
      await expectLater(
        start(c, host: '::ffff:192.0.2.1', name: '不同名称'),
        throwsA(isA<UserError>()),
      );
      expect(helper.requests, isEmpty);
      saveGate.complete();
      await first;
      expect(c.state.machines, hasLength(1));
      deploymentGate.complete();
      await settleUntil(() => c.deploying == 0);
    },
  );

  test('address normalization covers IPv6, host spelling, and mapped IPv4', () {
    for (final pair in [
      ['2001:db8::1', '[2001:0DB8:0:0:0:0:0:1]'],
      ['NODE.example.', ' node.EXAMPLE '],
      ['192.0.2.1', '::ffff:c000:201'],
    ]) {
      expect(deploymentHostKey(pair.first), deploymentHostKey(pair.last));
    }
  });

  test('existing host blocks a new deployment irrespective of port', () async {
    final original = Machine(
      id: 'existing',
      name: '原机器',
      host: '192.0.2.1',
      port: 20002,
      caCert: 'ca',
      clientCert: 'cert',
      clientKey: 'key',
    );
    final helper = FakeHelper();
    final c = controller(
      store: MemoryStore()..state = SavedState(machines: [original]),
      helper: helper,
    );
    addTearDown(c.dispose);
    await c.initialize(poll: false);
    await expectLater(start(c), throwsA(isA<UserError>()));
    expect(helper.requests, isEmpty);
    await start(c, existing: original);
    await settleUntil(() => c.deploying == 0);
    expect(c.state.machines.single.id, original.id);
  });

  test(
    'save rejection starts no helper and leaves imports with the dialog',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'deployment-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = await File('${directory.path}/key').writeAsString('fake-key');
      final store = MemoryStore();
      final helper = FakeHelper();
      final c = controller(store: store, helper: helper);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      store.failSave = true;
      await expectLater(
        start(c, importedFiles: [key.path]),
        throwsA(isA<UserError>()),
      );
      expect(c.deploying, 0);
      expect(c.deployments, isEmpty);
      expect(c.state.machines, isEmpty);
      expect(helper.requests, isEmpty);
      expect(await key.exists(), isTrue);
      store.failSave = false;
      await start(c);
      await settleUntil(() => c.deploying == 0);
    },
  );

  test(
    'fingerprint waits for explicit confirmation then persists the pin',
    () async {
      final helper = FakeHelper()
        ..handler = (request, _) async {
          if (request['action'] != 'deploy') return {};
          return request['host_key_fingerprint'] == ''
              ? {'needs_confirmation': true, 'fingerprint': 'SHA256:test-pin'}
              : credentials;
        };
      final store = MemoryStore();
      final c = controller(store: store, helper: helper);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await start(c);
      final id = c.state.machines.single.id;
      await settleUntil(() => c.deployments[id]?.awaitingConfirmation ?? false);
      expect(c.deploying, 1);
      expect(store.state.machines.single.fingerprint, isEmpty);
      expect(
        helper.requests.where((r) => r['action'] == 'deploy'),
        hasLength(1),
      );
      await c.confirmDeployment(id);
      await settleUntil(() => c.deploying == 0);
      expect(store.state.machines.single.fingerprint, 'SHA256:test-pin');
      expect(store.state.machines.single.canConnect, isTrue);
      expect(helper.requests.last['host_key_fingerprint'], 'SHA256:test-pin');
    },
  );

  test(
    'rejecting a fingerprint keeps a failed card and deletes owned key copies',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'deployment-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = await File('${directory.path}/key').writeAsString('fake-key');
      final helper = FakeHelper()
        ..handler = (request, _) async => request['action'] == 'deploy'
            ? {'needs_confirmation': true, 'fingerprint': 'SHA256:test-pin'}
            : {};
      final c = controller(helper: helper);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await start(c, importedFiles: [key.path]);
      final id = c.state.machines.single.id;
      await settleUntil(() => c.deployments[id]?.awaitingConfirmation ?? false);
      expect(await key.exists(), isTrue);
      await c.rejectDeployment(id);
      expect(c.deployments[id]?.phase, DeploymentPhase.failed);
      expect(c.state.machines.single.deploymentError, contains('部署已取消'));
      expect(c.state.machines.single.canConnect, isFalse);
      expect(await key.exists(), isFalse);
      expect(c.deploying, 0);
      expect(
        helper.requests.where((r) => r['action'] == 'deploy'),
        hasLength(1),
      );
      await expectLater(start(c, name: '另一台'), throwsA(isA<UserError>()));
    },
  );

  test(
    'progress cannot regress or finish before the successful state saves',
    () async {
      final response = Completer<Map<String, dynamic>>();
      final save = Completer<void>();
      final helper = FakeHelper()
        ..handler = (request, _) async =>
            request['action'] == 'deploy' ? response.future : {};
      final store = MemoryStore();
      final c = controller(store: store, helper: helper);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await start(c);
      final id = c.state.machines.single.id;
      await settleUntil(() => helper.progressCallbacks.isNotEmpty);
      final progress = helper.progressCallbacks.values.single;
      progress(const DeploymentProgress(percent: 70, stage: '发送安装包'));
      progress(const DeploymentProgress(percent: 40, stage: '发送安装包'));
      expect(c.deployments[id]?.percent, 70);
      progress(const DeploymentProgress(percent: 100, stage: '部署完成'));
      expect(c.deployments[id]?.percent, 99);
      expect(c.deployments[id]?.stage, '保存机器连接');
      store.beforeSave = (state) async {
        if (state.machines.single.canConnect) await save.future;
      };
      response.complete(credentials);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.machines.single.deploymentPending, isTrue);
      expect(c.deployments[id]?.phase, DeploymentPhase.deploying);
      save.complete();
      await settleUntil(() => c.deploying == 0);
      expect(c.deployments[id]?.percent, 100);
      expect(c.deployments[id]?.phase, DeploymentPhase.succeeded);
    },
  );

  test(
    'remote success with a failed local save stays visibly failed',
    () async {
      final gate = Completer<void>();
      final store = MemoryStore();
      final helper = FakeHelper()..deployGate = gate.future;
      final c = controller(store: store, helper: helper);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await start(c);
      final id = c.state.machines.single.id;
      store.failSave = true;
      gate.complete();
      await settleUntil(() => c.deploying == 0);
      expect(c.deployments[id]?.phase, DeploymentPhase.failed);
      expect(c.deployments[id]?.error, contains('本地连接未能保存'));
      expect(c.state.machines.single.canConnect, isFalse);
      expect(store.state.machines.single.deploymentPending, isTrue);
    },
  );

  test(
    'restart marks interrupted deployment without polling or resuming it',
    () async {
      final store = MemoryStore()
        ..state = SavedState(
          machines: [machine('a').copyWith(deploymentPending: true)],
        );
      final helper = FakeHelper();
      final gateway = FakeGateway();
      final c = controller(store: store, helper: helper, gateway: gateway);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await c.refresh();
      expect(c.state.machines.single.deploymentPending, isFalse);
      expect(c.state.machines.single.deploymentError, contains('部署被中断'));
      expect(store.state.machines.single.canConnect, isFalse);
      expect(helper.requests, isEmpty);
      expect(gateway.statusRequests, isEmpty);
    },
  );

  test('an old poll cannot overwrite a redeploying machine', () async {
    final oldStatus = Completer<AgentStatus>();
    final remote = Completer<void>();
    final gateway = FakeGateway()..statusHandler = (_) => oldStatus.future;
    final store = MemoryStore()..state = SavedState(machines: [machine('a')]);
    final helper = FakeHelper()..deployGate = remote.future;
    final c = controller(store: store, helper: helper, gateway: gateway);
    addTearDown(c.dispose);
    await c.initialize(poll: false);
    final polling = c.refresh();
    await settleUntil(() => gateway.statusRequests.isNotEmpty);
    await start(c, existing: c.state.machines.single);
    oldStatus.complete(AgentStatus(runtimeReady: true));
    await polling;
    expect(c.statuses, isEmpty);
    expect(c.connectionErrors, isEmpty);
    remote.complete();
    await settleUntil(() => c.deploying == 0);
  });

  test(
    'deployment blocks task dispatch, removal, and another redeployment',
    () async {
      final remote = Completer<void>();
      final helper = FakeHelper()..deployGate = remote.future;
      final gateway = FakeGateway();
      final c = controller(helper: helper, gateway: gateway);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      final account = await c.addAccount('测试', [
        {'name': 'session', 'value': 'value'},
      ], uid: '123');
      final task = await c.addTask('测试任务', account, {});
      await start(c);
      final machine = c.state.machines.single;
      expect(
        (await c.dispatch(task, [machine])).values.single,
        contains('部署尚未完成'),
      );
      expect(gateway.submitted, isEmpty);
      await expectLater(c.removeMachine(machine), throwsA(isA<UserError>()));
      await expectLater(start(c, existing: machine), throwsA(isA<UserError>()));
      remote.complete();
      await settleUntil(() => c.deploying == 0);
    },
  );

  test(
    'a completed redeploy invalidates a dispatch awaiting account validation',
    () async {
      final validation = Completer<Map<String, dynamic>>();
      final runtime = FakeRuntime();
      final gateway = FakeGateway();
      final c = controller(
        store: MemoryStore()..state = SavedState(machines: [machine('a')]),
        runtime: runtime,
        gateway: gateway,
      );
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      final account = await c.addAccount('测试', [
        {'name': 'session', 'value': 'value'},
      ], uid: '123');
      final task = await c.addTask('测试任务', account, {});
      runtime.handler = (_, _) => validation.future;
      final selected = c.state.machines.single;
      final dispatch = c.dispatch(task, [selected]);
      await settleUntil(() => runtime.calls.contains('login_state'));
      await start(c, host: selected.host, existing: selected);
      await settleUntil(() => c.deploying == 0);
      validation.complete({'status': 'valid', 'uid': '123', 'logged_in': true});
      expect((await dispatch).values.single, contains('部署状态已变化'));
      expect(gateway.submitted, isEmpty);
    },
  );

  test(
    'finishing one deployment retains another deployment private key',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'deployment-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = await File('${directory.path}/first-key')
          .writeAsString('fake-key');
      final second = await File('${directory.path}/second-key')
          .writeAsString('fake-key');
      final gates = <String, Completer<Map<String, dynamic>>>{};
      final helper = FakeHelper()
        ..handler = (request, _) async {
          if (request['action'] != 'deploy') return {};
          return (gates[request['host'] as String] = Completer()).future;
        };
      final c = controller(helper: helper);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await start(c, importedFiles: [first.path]);
      await start(
        c,
        host: '192.0.2.2',
        name: '第二台',
        importedFiles: [second.path],
      );
      await settleUntil(() => gates.length == 2);
      gates['192.0.2.1']!.complete(credentials);
      await settleUntil(() => c.deploying == 1);
      await settleUntil(() => !first.existsSync());
      expect(await second.exists(), isTrue);
      gates['192.0.2.2']!.complete(credentials);
      await settleUntil(() => c.deploying == 0 && !second.existsSync());
    },
  );

  test('unreachable result remains visible until the next poll', () async {
    final helper = FakeHelper()..reachable = false;
    final gateway = FakeGateway();
    final c = controller(helper: helper, gateway: gateway);
    addTearDown(c.dispose);
    await c.initialize(poll: false);
    await start(c);
    await settleUntil(() => c.deploying == 0);
    final id = c.state.machines.single.id;
    expect(c.connectionErrors[id], contains('防火墙或安全组'));
    expect(gateway.statusRequests, isEmpty);
    await c.refresh();
    expect(c.connectionErrors, isEmpty);
  });

  test(
    'disposing an active controller does not save late deployment success',
    () async {
      final remote = Completer<void>();
      final helper = FakeHelper()..deployGate = remote.future;
      final store = MemoryStore();
      final c = controller(store: store, helper: helper);
      await c.initialize(poll: false);
      await start(c);
      await settleUntil(
        () => helper.requests.any((r) => r['action'] == 'deploy'),
      );
      c.dispose();
      remote.complete();
      await settleUntil(() => c.deploying == 0);
      expect(store.state.machines.single.deploymentPending, isTrue);
      expect(c.statuses, isEmpty);
    },
  );

  test(
    'active imports and background deployments suppress credential pruning',
    () async {
      final gate = Completer<void>();
      final store = MemoryStore();
      final c = controller(
        store: store,
        helper: FakeHelper()..deployGate = gate.future,
      );
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      final count = store.pruned.length;
      c.holdCredentialImports();
      await start(c);
      c.releaseCredentialImports();
      await Future<void>.delayed(Duration.zero);
      expect(store.pruned, hasLength(count));
      gate.complete();
      await settleUntil(() => c.deploying == 0 && store.pruned.length > count);
    },
  );
}
