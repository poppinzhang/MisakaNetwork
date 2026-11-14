import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';

import 'fakes.dart';

void main() {
  test(
    'state roundtrip stores metadata without credentials or purchase data',
    () {
      final state = SavedState(
        machines: [machine('a')],
        accounts: [Account(id: 'a', name: '用户', uid: '123')],
        tasks: [
          TicketTask(
            id: 't',
            name: '演出',
            accountId: 'a',
            startAt: '2026-11-20T20:00:00',
            dispatchedTo: ['m'],
          ),
        ],
      );
      final text = state.encode();
      final decoded = SavedState.decode(text);
      expect(decoded.machines.single.host, 'node.example');
      expect(decoded.tasks.single.accountId, 'a');
      expect(decoded.tasks.single.startAt, '2026-11-20T20:00:00');
      expect(decoded.tasks.single.dispatchedTo, ['m']);
      final minimal = TicketTask.fromJson({
        'id': 't',
        'name': '演出',
        'accountId': 'a',
      });
      expect(minimal.startAt, isEmpty);
      expect(minimal.dispatchedTo, isEmpty);
      expect(text, isNot(contains('cookie')));
      expect(text, isNot(contains('personal_id')));
      expect(() => SavedState.decode('{"schema":99}'), throwsFormatException);
    },
  );
  test('startup failure preserves error and blocks state mutation', () async {
    final c = controller(store: MemoryStore()..failLoad = true);
    await c.initialize(poll: false);
    expect(c.initialized, false);
    expect(c.startupError, '配置无法读取');
    await expectLater(c.addMachine(machine('a')), throwsA(isA<UserError>()));
    c.dispose();
  });
  test('cookie and task config only live in secret storage', () async {
    final store = MemoryStore();
    final c = controller(store: store);
    await c.initialize(poll: false);
    final account = await c.addAccount('测试', [
      {'name': 'SESSDATA', 'value': 'secret-value'},
    ], uid: '123');
    final task = await c.addTask('演出', account, {
      'buyer_info': [
        {'personal_id': 'private-id'},
      ],
    });
    expect(store.secrets['account.${account.id}'], contains('secret-value'));
    expect(store.secrets['task.${task.id}'], contains('private-id'));
    expect(store.state.encode(), isNot(contains('secret-value')));
    expect(store.state.encode(), isNot(contains('private-id')));
    c.dispose();
  });
  test('failed persistence rolls back new secret', () async {
    final store = MemoryStore();
    final c = controller(store: store);
    await c.initialize(poll: false);
    store.failSave = true;
    await expectLater(
      c.addAccount('测试', [
        {'name': 'a', 'value': 'secret'},
      ], uid: '123'),
      throwsA(isA<UserError>()),
    );
    expect(store.secrets, isEmpty);
    expect(c.state.accounts, isEmpty);
    c.dispose();
  });
  test('empty cookie and invalid config rejected', () async {
    final runtime = FakeRuntime();
    final c = controller(runtime: runtime);
    await c.initialize(poll: false);
    await expectLater(
      c.addAccount('a', [], uid: '123'),
      throwsA(isA<UserError>()),
    );
    final a = await c.addAccount('a', [
      {'name': 'a', 'value': 'b'},
    ], uid: '123');
    runtime.valid = false;
    await expectLater(c.addTask('t', a, {}), throwsA(isA<UserError>()));
    expect(c.state.tasks, isEmpty);
    c.dispose();
  });
  test(
    'account used by a task cannot be deleted, deleting task removes secret',
    () async {
      final store = MemoryStore();
      final c = controller(store: store);
      await c.initialize(poll: false);
      final a = await c.addAccount('a', [
        {'name': 'a', 'value': 'b'},
      ], uid: '123');
      final t = await c.addTask('t', a, {});
      await expectLater(c.removeAccount(a), throwsA(isA<UserError>()));
      await c.removeTask(t);
      expect(store.secrets.containsKey('task.${t.id}'), false);
      await c.removeAccount(a);
      expect(store.secrets, isEmpty);
      c.dispose();
    },
  );
  test(
    'polling records health and retains last successful status on failure',
    () async {
      final store = MemoryStore()..state = SavedState(machines: [machine('a')]);
      final gateway = FakeGateway();
      final c = controller(store: store, gateway: gateway);
      await c.initialize(poll: false);
      await c.refresh();
      expect(c.statuses['a']?.version, '0.3.2');
      expect(c.lastSeen['a'], isNotNull);
      gateway.fail.add('a');
      await c.refresh();
      expect(c.connectionErrors['a'], '连接失败');
      expect(c.statuses['a'], isNotNull);
      gateway.fail.clear();
      await c.refresh();
      expect(c.connectionErrors, isEmpty);
      c.dispose();
    },
  );
  test('dispatch fans out and reports only failed machines', () async {
    final store = MemoryStore()
      ..state = SavedState(machines: [machine('a'), machine('b')]);
    final gateway = FakeGateway()..fail.add('b');
    final c = controller(store: store, gateway: gateway);
    await c.initialize(poll: false);
    final a = await c.addAccount('a', [
      {'name': 'session', 'value': 'secret'},
    ], uid: '123');
    final t = await c.addTask('任务', a, {'x': 1});
    final errors = await c.dispatch(t, c.state.machines);
    expect(errors.keys, ['节点 b']);
    expect(gateway.submitted.keys, ['a']);
    expect(gateway.submitted['a']?.id, t.id);
    expect(jsonDecode(gateway.submitted['a']!.configJson), {'x': 1});
    expect(gateway.submitted['a']!.cookieJson, contains('secret'));
    c.dispose();
  });
  test('dispatch requires selection and existing keychain config', () async {
    final store = MemoryStore();
    final c = controller(store: store);
    await c.initialize(poll: false);
    final a = await c.addAccount('a', [
      {'name': 's', 'value': 'v'},
    ], uid: '123');
    final t = await c.addTask('t', a, {});
    await expectLater(c.dispatch(t, []), throwsA(isA<UserError>()));
    store.secrets.remove('task.${t.id}');
    await expectLater(c.dispatch(t, [machine('a')]), throwsA(isA<UserError>()));
    c.dispose();
  });
  test('imported credential copies are pruned to the saved machines', () async {
    Machine withFiles(String id) => Machine(
      id: id,
      name: id,
      host: 'node.example',
      caCert: '/c/$id.ca',
      clientCert: '/c/$id.pem',
      clientKey: '/c/$id.key',
    );
    final store = MemoryStore()
      ..state = SavedState(machines: [withFiles('a'), withFiles('b')]);
    final c = controller(store: store);
    await c.initialize(poll: false);
    expect(store.pruned.last, {
      '/c/a.ca',
      '/c/a.pem',
      '/c/a.key',
      '/c/b.ca',
      '/c/b.pem',
      '/c/b.key',
    });
    await c.removeMachine(c.state.machines.first);
    expect(store.pruned.last, {'/c/b.ca', '/c/b.pem', '/c/b.key'});
    c.dispose();
    final failing = controller(store: MemoryStore()..failPrune = true);
    await failing.initialize(poll: false);
    expect(failing.initialized, isTrue);
    expect(failing.startupError, isNull);
    failing.dispose();
  });
  test('cancel targets a single machine and task', () async {
    final gateway = FakeGateway();
    final c = controller(gateway: gateway);
    await c.initialize(poll: false);
    await c.cancel(machine('a'), 't');
    expect(gateway.cancelled, ['a:t']);
    c.dispose();
  });
  test('deployment initializes PKI before invoking helper and keeps secrets out of saved state', () async {
    final helper = FakeHelper();
    final c = controller(helper: helper);
    await c.initialize(poll: false);
    await c.deploy({'host': 'node.example', 'password': 'secret'});
    expect(helper.requests.map((e) => e['action']), ['init_pki', 'deploy']);
    expect(helper.requests.last['password'], 'secret');
    expect(c.state.encode(), isNot(contains('secret')));
    c.dispose();
  });
  test('in-flight deploys are counted until they finish or fail', () async {
    final gate = Completer<void>();
    final helper = FakeHelper()
      ..deployGate = gate.future
      ..failDeploy = true;
    final c = controller(helper: helper);
    await c.initialize(poll: false);
    final running = c.deploy({'host': 'node.example'});
    await pumpEventQueue();
    expect(c.deploying, 1);
    gate.complete();
    await expectLater(running, throwsA(isA<UserError>()));
    expect(c.deploying, 0);
    c.dispose();
  });
  test(
    'machine names stay unique except when replacing the same machine',
    () async {
      final c = controller(
        store: MemoryStore()..state = SavedState(machines: [machine('a')]),
      );
      await c.initialize(poll: false);
      expect(
        () => c.requireUniqueMachineName('节点 a'),
        throwsA(isA<UserError>()),
      );
      expect(
        () => c.requireUniqueMachineName('节点 a', id: 'b'),
        throwsA(isA<UserError>()),
      );
      c.requireUniqueMachineName('节点 a', id: 'a');
      c.requireUniqueMachineName('节点 b');
      c.dispose();
    },
  );
  test('machine validation and removal clear monitoring state', () async {
    final c = controller();
    await c.initialize(poll: false);
    await c.addMachine(machine('a'));
    await c.refresh();
    await c.removeMachine(machine('a'));
    expect(c.state.machines, isEmpty);
    expect(c.statuses, isEmpty);
    await expectLater(
      c.addMachine(
        Machine(
          id: 'x',
          name: 'x',
          host: '',
          caCert: '',
          clientCert: '',
          clientKey: '',
        ),
      ),
      throwsA(isA<UserError>()),
    );
    c.dispose();
  });
  test('an immediate terminal response releases the first execution', () async {
    final gateway = FakeGateway()..submitState = TaskState.TASK_STATE_FAILED;
    final c = controller(gateway: gateway);
    await c.initialize(poll: false);
    final a = await c.addAccount('a', [
      {'name': 's', 'value': 'v'},
    ], uid: '123');
    final t = await c.addTask('t', a, {});
    final errors = await c.dispatch(t, [machine('a')]);
    expect(errors, isEmpty);
    expect(gateway.submitted['a']?.id, t.id);
    expect(c.activeDispatchCount(t), 0);
    expect(c.state.tasks.single.latestDispatch('a')!.finished, isTrue);
    c.dispose();
  });
  test('sale start accepts only real Beijing date-times', () {
    expect(normalizeStartAt(''), '');
    expect(normalizeStartAt(' 2026-11-20 20:00 '), '2026-11-20T20:00:00');
    expect(normalizeStartAt('2026-11-20T20:00:05'), '2026-11-20T20:00:05');
    for (final value in [
      '20:00',
      '2026-02-30 20:00',
      '2026-11-20 24:00',
      '2026/11/20 20:00',
      '2026-11-20T20:00:00Z',
      '2026-1-5 20:00',
    ]) {
      expect(
        () => normalizeStartAt(value),
        throwsA(isA<UserError>()),
        reason: value,
      );
    }
  });
  test('sale start is stored with the task and sent on dispatch', () async {
    final store = MemoryStore();
    final gateway = FakeGateway();
    final c = controller(store: store, gateway: gateway);
    await c.initialize(poll: false);
    final a = await c.addAccount('a', [
      {'name': 's', 'value': 'v'},
    ], uid: '123');
    await expectLater(
      c.addTask('t', a, {}, startAt: '20:00'),
      throwsA(isA<UserError>()),
    );
    expect(c.state.tasks, isEmpty);
    final timed = await c.addTask('t', a, {}, startAt: '2026-11-20 20:00');
    expect(store.state.tasks.single.startAt, '2026-11-20T20:00:00');
    await c.dispatch(timed, [machine('a')]);
    expect(gateway.submitted['a']!.timeStart, '2026-11-20T20:00:00');
    final immediate = await c.addTask('立即', a, {});
    await c.dispatch(immediate, [machine('a')]);
    expect(gateway.submitted['a']!.id, immediate.id);
    expect(gateway.submitted['a']!.timeStart, isEmpty);
    c.dispose();
  });
  test(
    'timed tasks are never sent to agents that ignore the start time',
    () async {
      final store = MemoryStore();
      final gateway = FakeGateway()..timeStartSupported = false;
      final c = controller(store: store, gateway: gateway);
      await c.initialize(poll: false);
      final a = await c.addAccount('a', [
        {'name': 's', 'value': 'v'},
      ], uid: '123');
      final timed = await c.addTask('t', a, {}, startAt: '2026-11-20 20:00');
      final errors = await c.dispatch(timed, [machine('a')]);
      expect(gateway.submitted, isEmpty);
      expect(errors['节点 a'], contains('重新部署'));
      expect(store.state.tasks.single.dispatchedTo, isEmpty);
      final immediate = await c.addTask('立即', a, {});
      expect(await c.dispatch(immediate, [machine('a')]), isEmpty);
      expect(gateway.submitted['a']!.id, immediate.id);
      c.dispose();
    },
  );
  test('unconfirmed executions cannot be submitted again', () async {
    final store = MemoryStore()
      ..state = SavedState(machines: [machine('a'), machine('b')]);
    // The fake keeps no task history, like a Sisters that restarted.
    final gateway = FakeGateway()..fail.add('b');
    final runtime = FakeRuntime();
    final c = controller(store: store, gateway: gateway, runtime: runtime);
    await c.initialize(poll: false);
    final a = await c.addAccount('a', [
      {'name': 'session', 'value': 'secret'},
    ], uid: '123');
    final t = await c.addTask('任务', a, {});
    await c.dispatch(t, c.state.machines);
    expect(store.state.tasks.single.dispatchedTo, ['a']);
    gateway
      ..submitted.clear()
      ..fail.clear();
    final errors = await c.dispatch(t, c.state.machines);
    expect(gateway.submitted.keys, ['b']);
    expect(errors.keys, ['节点 a']);
    expect(errors['节点 a'], contains('状态待确认'));
    expect(store.state.tasks.single.dispatchedTo, ['a', 'b']);
    final checks = runtime.calls.length;
    final repeated = await c.dispatch(t, [machine('a')]);
    expect(repeated.keys, ['节点 a']);
    expect(runtime.calls.length, checks);
    c.dispose();
  });
  test('polling records machines that already hold a task', () async {
    final store = MemoryStore()..state = SavedState(machines: [machine('a')]);
    final gateway = FakeGateway();
    final c = controller(store: store, gateway: gateway);
    await c.initialize(poll: false);
    final a = await c.addAccount('a', [
      {'name': 's', 'value': 'v'},
    ], uid: '123');
    final t = await c.addTask('t', a, {});
    gateway.remoteTasks.add(
      TaskStatus(id: t.id, state: TaskState.TASK_STATE_RUNNING),
    );
    await c.refresh();
    expect(store.state.tasks.single.dispatchedTo, ['a']);
    final errors = await c.dispatch(t, [machine('a')]);
    expect(gateway.submitted, isEmpty);
    expect(errors['节点 a'], contains('状态待确认'));
    c.dispose();
  });
  test('a failed intent save prevents submission', () async {
    final store = MemoryStore();
    final gateway = FakeGateway();
    final c = controller(store: store, gateway: gateway);
    await c.initialize(poll: false);
    final a = await c.addAccount('a', [
      {'name': 's', 'value': 'v'},
    ], uid: '123');
    final t = await c.addTask('t', a, {});
    store.beforeSave = (next) async {
      if (next.tasks.any((t) => t.dispatchedTo.isNotEmpty)) {
        throw const UserError('写入失败');
      }
    };
    final errors = await c.dispatch(t, [machine('a')]);
    expect(gateway.submitted, isEmpty);
    expect(errors['节点 a'], contains('写入失败'));
    expect(store.state.tasks.single.dispatchedTo, isEmpty);
    c.dispose();
  });
}
