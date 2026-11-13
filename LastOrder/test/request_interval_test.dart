import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

void main() {
  test(
    'request interval accepts decimal integer milliseconds within bounds',
    () {
      for (final value in [100, 750, 1000, 60000]) {
        expect(parseRequestIntervalMs(' $value '), value);
      }
      for (final value in [
        '',
        ' ',
        '0',
        '-100',
        '99',
        '60001',
        '1000.5',
        '1e3',
        '0x100',
        'NaN',
        'Infinity',
        '100 ms',
        '999999999999999999999999',
      ]) {
        expect(
          () => parseRequestIntervalMs(value),
          throwsA(isA<UserError>()),
          reason: value,
        );
      }
    },
  );

  test('interval survives storage and dispatch bookkeeping with a default', () {
    final minimal = {'id': 't', 'name': '任务', 'accountId': 'a'};
    expect(TicketTask.fromJson(minimal).requestIntervalMs, 1000);
    final task = TicketTask.fromJson({...minimal, 'requestIntervalMs': 750});
    final saved = SavedState.decode(SavedState(tasks: [task]).encode());
    expect(saved.tasks.single.requestIntervalMs, 750);
    expect(task.withDispatched(['machine-a']).requestIntervalMs, 750);
    for (final value in [0, 99, 60001, -1, 100.5, '1000', true]) {
      expect(
        () => TicketTask.fromJson({...minimal, 'requestIntervalMs': value}),
        throwsFormatException,
        reason: '$value',
      );
    }
  });

  test(
    'creation rejects invalid intervals before validation or persistence',
    () async {
      final store = MemoryStore();
      final runtime = FakeRuntime();
      final c = controller(store: store, runtime: runtime);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      final account = await c.addAccount('测试', [
        {'name': 's', 'value': 'v'},
      ], uid: '123');
      runtime.calls.clear();
      for (final value in [0, -100, 99, 60001]) {
        await expectLater(
          c.addTask('任务', account, {}, requestIntervalMs: value),
          throwsA(isA<UserError>()),
        );
      }
      expect(runtime.calls, isEmpty);
      expect(store.state.tasks, isEmpty);
      expect(
        store.secrets.keys.where((key) => key.startsWith('task.')),
        isEmpty,
      );
    },
  );

  test(
    'each task retains its interval through reload and multiple dispatches',
    () async {
      final store = MemoryStore();
      final gateway = FakeGateway();
      final c = controller(store: store, gateway: gateway);
      await c.initialize(poll: false);
      final account = await c.addAccount('测试', [
        {'name': 's', 'value': 'v'},
      ], uid: '123');
      await c.addTask('默认', account, {});
      await c.addTask('自定义', account, {}, requestIntervalMs: 750);
      store.state = SavedState.decode(store.state.encode());
      c.dispose();
      final reloaded = controller(store: store, gateway: gateway);
      addTearDown(reloaded.dispose);
      await reloaded.initialize(poll: false);
      final tasks = reloaded.state.tasks;
      expect(await reloaded.dispatch(tasks.first, [machine('a')]), isEmpty);
      expect(gateway.submitted['a']!.requestIntervalMs, 1000);
      expect(
        await reloaded.dispatch(tasks.last, [machine('a'), machine('b')]),
        isEmpty,
      );
      expect(gateway.submitted['a']!.requestIntervalMs, 750);
      expect(gateway.submitted['b']!.requestIntervalMs, 750);
      expect(reloaded.state.tasks.last.requestIntervalMs, 750);
      expect(reloaded.state.tasks.last.dispatchedTo, ['a', 'b']);
      expect(jsonDecode(store.secrets['task.${tasks.last.id}']!), isEmpty);
    },
  );

  test('dispatch rejects agents that cannot honor interval settings', () async {
    final store = MemoryStore();
    final gateway = FakeGateway()..requestIntervalSupported = false;
    final c = controller(store: store, gateway: gateway);
    addTearDown(c.dispose);
    await c.initialize(poll: false);
    final account = await c.addAccount('测试', [
      {'name': 's', 'value': 'v'},
    ], uid: '123');
    for (final value in [1000, 750]) {
      final task = await c.addTask('任务', account, {}, requestIntervalMs: value);
      final errors = await c.dispatch(task, [machine('a')]);
      expect(errors['节点 a'], contains('重新部署'));
      expect(c.state.tasks.last.dispatchedTo, isEmpty);
    }
    expect(gateway.submitted, isEmpty);
    gateway.requestIntervalSupported = true;
    expect(await c.dispatch(c.state.tasks.last, [machine('a')]), isEmpty);
    expect(gateway.submitted['a']!.requestIntervalMs, 750);
  });
}
