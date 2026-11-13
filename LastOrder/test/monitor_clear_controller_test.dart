import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/payments.dart';

import 'fakes.dart';

TaskStatus execution({
  String id = 'task',
  TaskState state = TaskState.TASK_STATE_CANCELLED,
}) => TaskStatus(id: id, name: '执行记录', state: state);

Future<(AppController, MemoryStore, FakeGateway)> setup() async {
  final store = MemoryStore()
    ..state = SavedState(
      machines: [machine('a'), machine('b')],
      accounts: [Account(id: 'account', name: '账号', uid: '123')],
      tasks: [
        TicketTask(
          id: 'task',
          name: '任务',
          accountId: 'account',
          dispatches: [const TaskDispatch(machineId: 'a', executionId: 'task')],
        ),
      ],
    )
    ..secrets.addAll({
      'account.account': '[{"name":"s","value":"synthetic"}]',
      'task.task': '{"project_id":123}',
    });
  final gateway = FakeGateway();
  final c = controller(store: store, gateway: gateway);
  addTearDown(c.dispose);
  await c.initialize(poll: false);
  c.statuses['a'] = AgentStatus(tasks: [execution()]);
  return (c, store, gateway);
}

void mixedExecutions(AppController c) {
  c.statuses['a'] = AgentStatus(
    tasks: [
      execution(state: TaskState.TASK_STATE_SUCCEEDED),
      execution(id: 'cancelled'),
      execution(id: 'failed', state: TaskState.TASK_STATE_FAILED),
      execution(id: 'running', state: TaskState.TASK_STATE_RUNNING),
      execution(id: 'queued', state: TaskState.TASK_STATE_QUEUED),
      execution(id: 'unknown', state: TaskState.TASK_STATE_UNSPECIFIED),
    ],
  );
  c.statuses['b'] = AgentStatus(tasks: [execution()]);
}

void main() {
  test('bulk clear saves all visible terminal records once and preserves other work', () async {
    final (c, store, gateway) = await setup();
    mixedExecutions(c);
    final already = execution(id: 'already');
    c.statuses['a']!.tasks.add(already);
    await c.clearExecution(machine('a'), already);
    final secrets = Map<String, String>.of(store.secrets);
    var saves = 0;
    store.beforeSave = (_) async {
      saves++;
    };

    expect(await c.clearFinishedExecutions(), 4);
    expect(saves, 1);
    expect(store.state.clearedExecutions, hasLength(5));
    for (final entry in c.statuses.entries) {
      for (final task in entry.value.tasks) {
        expect(
          c.isExecutionCleared(entry.key, task),
          c.canClearExecution(task),
        );
      }
    }
    expect(c.state.tasks.single.dispatches, hasLength(2));
    expect(c.state.tasks.single.dispatches.every((d) => d.finished), isTrue);
    expect(store.secrets, secrets);
    expect(gateway.statusRequests, isEmpty);
    expect(gateway.submitted, isEmpty);
    expect(gateway.cancelled, isEmpty);

    store.state = SavedState.decode(store.state.encode());
    final reloaded = controller(store: store, gateway: gateway);
    addTearDown(reloaded.dispose);
    await reloaded.initialize(poll: false);
    reloaded.statuses.addAll(c.statuses);
    expect(await reloaded.clearFinishedExecutions(), 0);
    expect(saves, 1);
    expect(reloaded.isExecutionCleared('a', already), isTrue);
  });

  test(
    'failed bulk save never partially clears records and can be retried',
    () async {
      final (c, store, _) = await setup();
      mixedExecutions(c);
      store.failSave = true;
      await expectLater(c.clearFinishedExecutions(), throwsA(isA<UserError>()));
      expect(c.state.clearedExecutions, isEmpty);
      expect(store.state.clearedExecutions, isEmpty);
      expect(c.state.tasks.single.latestDispatch('a')!.finished, isFalse);
      for (final entry in c.statuses.entries) {
        for (final task in entry.value.tasks) {
          expect(c.isExecutionCleared(entry.key, task), isFalse);
        }
      }
      store.failSave = false;
      expect(await c.clearFinishedExecutions(), 4);
    },
  );

  test(
    'queued bulk clear skips changed, missing and newly completed results',
    () async {
      final (c, store, _) = await setup();
      mixedExecutions(c);
      final saving = Completer<void>();
      final release = Completer<void>();
      store.beforeSave = (_) async {
        if (!saving.isCompleted) {
          saving.complete();
          await release.future;
        }
      };
      final themeSave = c.setThemeMode(AppThemeMode.dark);
      await saving.future;
      final clear = c.clearFinishedExecutions();
      c.statuses['a'] = AgentStatus(
        tasks: [
          execution(id: 'cancelled', state: TaskState.TASK_STATE_SUCCEEDED),
          execution(id: 'failed', state: TaskState.TASK_STATE_FAILED),
          execution(id: 'running', state: TaskState.TASK_STATE_SUCCEEDED),
          execution(id: 'new', state: TaskState.TASK_STATE_SUCCEEDED),
        ],
      );
      c.statuses.remove('b');
      release.complete();
      await themeSave;
      expect(await clear, 1);
      expect(c.state.clearedExecutions.single.executionId, 'failed');
      for (final task in c.statuses['a']!.tasks) {
        expect(c.isExecutionCleared('a', task), task.id == 'failed');
      }
    },
  );

  test(
    'bulk clear with only running, queued and unknown records does not save',
    () async {
      final (c, store, _) = await setup();
      c.statuses['a'] = AgentStatus(
        tasks: [
          execution(state: TaskState.TASK_STATE_RUNNING),
          execution(id: 'queued', state: TaskState.TASK_STATE_QUEUED),
          execution(id: 'unknown', state: TaskState.TASK_STATE_UNSPECIFIED),
        ],
      );
      store.failSave = true;
      expect(await c.clearFinishedExecutions(), 0);
      expect(c.state.clearedExecutions, isEmpty);
      expect(c.state.tasks.single.latestDispatch('a')!.finished, isFalse);
    },
  );

  test(
    'concurrent bulk clears do not count or duplicate the same records twice',
    () async {
      final (c, store, _) = await setup();
      mixedExecutions(c);
      final saving = Completer<void>();
      final release = Completer<void>();
      store.beforeSave = (_) async {
        if (!saving.isCompleted) {
          saving.complete();
          await release.future;
        }
      };
      final first = c.clearFinishedExecutions();
      await saving.future;
      final second = c.clearFinishedExecutions();
      release.complete();
      expect(await Future.wait([first, second]), [4, 0]);
      expect(store.state.clearedExecutions, hasLength(4));
    },
  );

  test(
    'clearing a terminal execution persists through reload and refresh',
    () async {
      final (c, store, gateway) = await setup();
      final snapshot = c.statuses['a']!.tasks.single;
      await c.clearExecution(machine('a'), snapshot);
      expect(c.isExecutionCleared('a', snapshot), isTrue);
      expect(store.state.clearedExecutions, hasLength(1));
      expect(store.state.clearedExecutions.single.state, snapshot.state.name);
      expect(store.state.tasks.single.latestDispatch('a')!.finished, isTrue);

      store.state = SavedState.decode(store.state.encode());
      final reloaded = controller(store: store, gateway: gateway);
      addTearDown(reloaded.dispose);
      await reloaded.initialize(poll: false);
      gateway.remoteTasks.add(execution());
      await reloaded.refresh();
      expect(
        reloaded.isExecutionCleared('a', reloaded.statuses['a']!.tasks.single),
        isTrue,
      );
      expect(reloaded.activeDispatchCount(reloaded.state.tasks.single), 0);
      // Other settings saved after a clear must retain the hidden-record list.
      await reloaded.setThemeMode(AppThemeMode.dark);
      expect(store.state.clearedExecutions, hasLength(1));
    },
  );

  test(
    'an older in-flight poll does not make a cleared execution visible again',
    () async {
      final (c, _, gateway) = await setup();
      final started = Completer<void>();
      final response = Completer<AgentStatus>();
      gateway.statusHandler = (m) async {
        if (m.id != 'a') return AgentStatus();
        started.complete();
        return response.future;
      };
      final poll = c.refresh();
      await started.future;
      await c.clearExecution(machine('a'), c.statuses['a']!.tasks.single);
      response.complete(
        AgentStatus(tasks: [execution(state: TaskState.TASK_STATE_RUNNING)]),
      );
      await poll;
      final current = c.statuses['a']!.tasks.single;
      expect(current.state, TaskState.TASK_STATE_CANCELLED);
      expect(c.isExecutionCleared('a', current), isTrue);
    },
  );

  test('clearing is isolated by machine and execution ID', () async {
    final (c, _, _) = await setup();
    final snapshot = c.statuses['a']!.tasks.single;
    c.statuses['b'] = AgentStatus(tasks: [execution()]);
    await c.clearExecution(machine('a'), snapshot);
    expect(c.isExecutionCleared('a', snapshot), isTrue);
    expect(c.isExecutionCleared('b', snapshot), isFalse);
    expect(c.isExecutionCleared('a', execution(id: 'execution-2')), isFalse);
    expect(
      c.isExecutionCleared('a', execution(state: TaskState.TASK_STATE_RUNNING)),
      isFalse,
    );
  });

  test('only acknowledged terminal states can be cleared', () async {
    final (c, store, gateway) = await setup();
    for (final state in [
      TaskState.TASK_STATE_UNSPECIFIED,
      TaskState.TASK_STATE_QUEUED,
      TaskState.TASK_STATE_RUNNING,
    ]) {
      final current = execution(state: state);
      c.statuses['a'] = AgentStatus(tasks: [current]);
      expect(c.canClearExecution(current), isFalse);
      await expectLater(
        c.clearExecution(machine('a'), current),
        throwsA(isA<UserError>()),
      );
    }
    expect(store.state.clearedExecutions, isEmpty);
    expect(store.state.tasks.single.latestDispatch('a')!.finished, isFalse);
    expect(gateway.cancelled, isEmpty);
    for (final state in [
      TaskState.TASK_STATE_CANCELLED,
      TaskState.TASK_STATE_SUCCEEDED,
      TaskState.TASK_STATE_FAILED,
    ]) {
      expect(c.canClearExecution(execution(state: state)), isTrue);
    }
  });

  test(
    'a missing or changed execution cannot be cleared using an old snapshot',
    () async {
      final (c, store, _) = await setup();
      final snapshot = c.statuses['a']!.tasks.single;
      for (final replacement in [
        AgentStatus(),
        AgentStatus(tasks: [execution(state: TaskState.TASK_STATE_SUCCEEDED)]),
        AgentStatus(tasks: [execution(state: TaskState.TASK_STATE_RUNNING)]),
      ]) {
        c.statuses['a'] = replacement;
        await expectLater(
          c.clearExecution(machine('a'), snapshot),
          throwsA(isA<UserError>()),
        );
      }
      expect(store.state.clearedExecutions, isEmpty);
    },
  );

  test(
    'queued clear rechecks the result after another save completes',
    () async {
      final (c, store, _) = await setup();
      final snapshot = c.statuses['a']!.tasks.single;
      final saving = Completer<void>();
      final release = Completer<void>();
      store.beforeSave = (_) async {
        if (!saving.isCompleted) {
          saving.complete();
          await release.future;
        }
      };
      final themeSave = c.setThemeMode(AppThemeMode.dark);
      await saving.future;
      final clear = expectLater(
        c.clearExecution(machine('a'), snapshot),
        throwsA(isA<UserError>()),
      );
      c.statuses['a'] = AgentStatus(
        tasks: [execution(state: TaskState.TASK_STATE_SUCCEEDED)],
      );
      release.complete();
      await Future.wait([themeSave, clear]);
      expect(store.state.clearedExecutions, isEmpty);
      expect(c.isExecutionCleared('a', c.statuses['a']!.tasks.single), isFalse);
    },
  );

  test('a failed save leaves the record visible and can be retried', () async {
    final (c, store, _) = await setup();
    final snapshot = c.statuses['a']!.tasks.single;
    store.failSave = true;
    await expectLater(
      c.clearExecution(machine('a'), snapshot),
      throwsA(isA<UserError>()),
    );
    expect(c.isExecutionCleared('a', snapshot), isFalse);
    expect(c.state.clearedExecutions, isEmpty);
    expect(c.state.tasks.single.latestDispatch('a')!.finished, isFalse);
    store.failSave = false;
    await c.clearExecution(machine('a'), snapshot);
    expect(c.isExecutionCleared('a', snapshot), isTrue);
    expect(store.state.tasks.single.latestDispatch('a')!.finished, isTrue);
  });

  test('clear retains configuration, secrets, execution history and remote results', () async {
    final (c, store, gateway) = await setup();
    final snapshot = c.statuses['a']!.tasks.single;
    final secrets = Map<String, String>.of(store.secrets);
    final task = c.state.tasks.single;
    await c.clearExecution(machine('a'), snapshot);
    await c.clearExecution(machine('a'), snapshot);
    expect(c.state.clearedExecutions, hasLength(1));
    expect(c.state.tasks, hasLength(1));
    final saved = c.state.tasks.single;
    expect(saved.id, task.id);
    expect(saved.name, task.name);
    expect(saved.accountId, task.accountId);
    expect(saved.dispatches, hasLength(1));
    expect(saved.latestDispatch('a')!.executionId, 'task');
    expect(saved.latestDispatch('a')!.finished, isTrue);
    expect(store.secrets, secrets);
    expect(c.statuses['a']!.tasks.single, snapshot);
    expect(gateway.statusRequests, isEmpty);
    expect(gateway.submitted, isEmpty);
    expect(gateway.cancelled, isEmpty);
  });

  test(
    'orphan remote results can be cleared without recreating local tasks',
    () async {
      final (c, store, gateway) = await setup();
      final beforeTasks = c.state.tasks.map((task) => task.toJson()).toList();
      final orphan = execution(id: 'orphan');
      c.statuses['a']!.tasks.add(orphan);
      await c.clearExecution(machine('a'), orphan);
      expect(c.isExecutionCleared('a', orphan), isTrue);
      expect(c.state.tasks.map((task) => task.toJson()).toList(), beforeTasks);
      expect(store.state.clearedExecutions.single.executionId, 'orphan');
      expect(gateway.cancelled, isEmpty);
    },
  );

  test('late success is visible after clearing cancellation and payment remains available', () async {
    final (c, store, gateway) = await setup();
    await c.clearExecution(machine('a'), c.statuses['a']!.tasks.single);
    final success = execution(state: TaskState.TASK_STATE_SUCCEEDED)
      ..payment = OrderPayment(orderId: '12345');
    gateway.remoteTasks.add(success);
    await c.refresh();
    final current = c.statuses['a']!.tasks.single;
    expect(c.isExecutionCleared('a', current), isFalse);
    expect(collectOrderPayments(c.state, c.statuses), hasLength(1));
    await c.clearExecution(machine('a'), current);
    expect(c.isExecutionCleared('a', current), isTrue);
    expect(store.state.clearedExecutions, hasLength(1));
    expect(
      store.state.clearedExecutions.single.state,
      TaskState.TASK_STATE_SUCCEEDED.name,
    );
    expect(collectOrderPayments(c.state, c.statuses), hasLength(1));
  });

  test(
    'removing a machine prunes only its cleared execution markers',
    () async {
      final (c, store, _) = await setup();
      c.statuses['b'] = AgentStatus(tasks: [execution()]);
      await c.clearExecution(machine('a'), c.statuses['a']!.tasks.single);
      await c.clearExecution(machine('b'), c.statuses['b']!.tasks.single);
      await c.removeMachine(machine('a'));
      expect(store.state.clearedExecutions, hasLength(1));
      expect(store.state.clearedExecutions.single.machineId, 'b');
      expect(
        store.state.tasks.single.dispatches.where(
          (dispatch) => dispatch.machineId == 'a',
        ),
        hasLength(1),
      );
    },
  );
}
