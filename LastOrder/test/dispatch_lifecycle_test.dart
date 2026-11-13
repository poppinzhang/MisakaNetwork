import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';

import 'fakes.dart';

class _LifecycleGateway extends FakeGateway {
  final history = <String, List<TaskStatus>>{};
  final calls = <(String, String)>[];
  Future<void> Function(Machine, TaskRequest)? beforeSubmit;
  Future<AgentStatus> Function(Machine)? readStatus;
  bool loseResponse = false;
  bool failStatus = false;
  Future<void> Function()? beforeCancelResponse;

  AgentStatus snapshot(String machineId) => AgentStatus(
    supportsTimeStart: true,
    supportsRequestInterval: true,
    tasks: [
      for (final t in history[machineId] ?? <TaskStatus>[])
        TaskStatus.fromBuffer(t.writeToBuffer()),
    ],
  );

  @override
  Future<AgentStatus> status(Machine m) async {
    if (readStatus != null) return readStatus!(m);
    if (failStatus) throw const UserError('连接失败');
    return snapshot(m.id);
  }

  @override
  Future<TaskStatus> submit(Machine m, TaskRequest t) async {
    calls.add((m.id, t.id));
    await beforeSubmit?.call(m, t);
    final result = TaskStatus(
      id: t.id,
      name: t.name,
      state: TaskState.TASK_STATE_RUNNING,
    );
    (history[m.id] ??= []).add(result);
    if (loseResponse) throw const UserError('响应丢失');
    return TaskStatus.fromBuffer(result.writeToBuffer());
  }

  @override
  Future<TaskStatus> cancel(Machine m, String id) async {
    final result = history[m.id]!.singleWhere((t) => t.id == id);
    result.state = TaskState.TASK_STATE_CANCELLED;
    final response = TaskStatus.fromBuffer(result.writeToBuffer());
    await beforeCancelResponse?.call();
    return response;
  }
}

Future<(AppController, MemoryStore, _LifecycleGateway, TicketTask)>
_setup() async {
  final store = MemoryStore()
    ..state = SavedState(machines: [machine('a'), machine('b')]);
  final gateway = _LifecycleGateway();
  final c = controller(store: store, gateway: gateway);
  addTearDown(c.dispose);
  await c.initialize(poll: false);
  final account = await c.addAccount('账号', [
    {'name': 's', 'value': 'v'},
  ], uid: '123');
  final task = await c.addTask('任务', account, {}, requestIntervalMs: 750);
  return (c, store, gateway, task);
}

void main() {
  for (final terminal in [
    TaskState.TASK_STATE_CANCELLED,
    TaskState.TASK_STATE_SUCCEEDED,
    TaskState.TASK_STATE_FAILED,
  ]) {
    test(
      '$terminal releases capacity and an explicit redispatch creates a new execution',
      () async {
        final (c, store, gateway, task) = await _setup();
        gateway.beforeSubmit = (machine, request) async {
          expect(
            store.state.tasks.single.latestDispatch(machine.id)!.executionId,
            request.id,
          );
        };
        expect(await c.dispatch(task, [machine('a')]), isEmpty);
        expect(c.activeDispatchCount(task), 1);
        gateway.history['a']!.single.state = terminal;
        await c.refresh();
        expect(c.activeDispatchCount(task), 0);
        expect(store.state.tasks.single.latestDispatch('a')!.finished, isTrue);
        expect(c.isDispatchBlocked(task, 'a'), isFalse);

        expect(await c.dispatch(task, [machine('a')]), isEmpty);
        final latest = c.state.tasks.single.latestDispatch('a')!;
        expect(latest.executionId, isNot(task.id));
        expect(latest.finished, isFalse);
        expect(c.state.tasks.single.requestIntervalMs, 750);
        expect(c.state.tasks.single.dispatches, hasLength(2));
        expect(c.state.tasks.single.ownsExecution('a', task.id), isTrue);
        expect(
          c.state.tasks.single.ownsExecution('a', latest.executionId),
          isTrue,
        );
        expect(c.activeDispatchCount(task), 1);
        expect(gateway.calls.map((call) => call.$2).toSet(), hasLength(2));
        expect(await c.dispatch(task, [machine('a')]), isNotEmpty);
        expect(gateway.calls, hasLength(2));
      },
    );
  }

  test('finishing one machine releases only that machine', () async {
    final (c, _, gateway, task) = await _setup();
    await c.dispatch(task, c.state.machines);
    expect(c.activeDispatchCount(task), 2);
    gateway.history['a']!.single.state = TaskState.TASK_STATE_SUCCEEDED;
    await c.refresh();
    expect(c.activeDispatchCount(task), 1);
    expect(c.isDispatchBlocked(task, 'a'), isFalse);
    expect(c.isDispatchBlocked(task, 'b'), isTrue);
    final errors = await c.dispatch(task, c.state.machines);
    expect(errors.keys, ['节点 b']);
    expect(gateway.calls.where((call) => call.$1 == 'a'), hasLength(2));
    expect(gateway.calls.where((call) => call.$1 == 'b'), hasLength(1));
  });

  test(
    'a cancellation acknowledgement wins over an older in-flight poll',
    () async {
      final (c, store, gateway, task) = await _setup();
      await c.dispatch(task, [machine('a')]);
      final stale = gateway.snapshot('a');
      final polled = Completer<void>();
      final response = Completer<AgentStatus>();
      gateway.readStatus = (m) async {
        if (m.id != 'a') return gateway.snapshot(m.id);
        polled.complete();
        return response.future;
      };
      final poll = c.refresh();
      await polled.future;
      final cancelled = c.cancel(machine('a'), task.id);
      // Wait for the RPC acknowledgement and its serialized local save.
      while (store.state.tasks.single.latestDispatch('a')!.finished == false) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(c.activeDispatchCount(task), 0);
      response.complete(stale);
      await Future.wait([poll, cancelled]);
      expect(
        c.statuses['a']!.tasks.single.state,
        TaskState.TASK_STATE_CANCELLED,
      );
      expect(c.activeDispatchCount(task), 0);
    },
  );

  test(
    'cancel releases capacity even when its follow-up status query fails',
    () async {
      final (c, store, gateway, task) = await _setup();
      await c.dispatch(task, [machine('a')]);
      gateway.failStatus = true;
      await c.cancel(machine('a'), task.id);
      expect(c.activeDispatchCount(task), 0);
      expect(store.state.tasks.single.latestDispatch('a')!.finished, isTrue);
      expect(c.connectionErrors['a'], isNotNull);
    },
  );

  test(
    'completed acknowledgement survives reload and remote history eviction',
    () async {
      final (c, store, gateway, task) = await _setup();
      await c.dispatch(task, [machine('a')]);
      gateway.history['a']!.single.state = TaskState.TASK_STATE_SUCCEEDED;
      await c.refresh();
      store.state = SavedState.decode(store.state.encode());
      gateway.history.clear();
      final reloaded = controller(store: store, gateway: gateway);
      addTearDown(reloaded.dispose);
      await reloaded.initialize(poll: false);
      expect(reloaded.activeDispatchCount(reloaded.state.tasks.single), 0);
      expect(await reloaded.dispatch(task, [machine('a')]), isEmpty);
      expect(gateway.calls.last.$2, isNot(task.id));
    },
  );

  test(
    'concurrent dispatches and a pending save cannot submit twice',
    () async {
      final (c, store, gateway, task) = await _setup();
      final saving = Completer<void>();
      final allowSave = Completer<void>();
      store.beforeSave = (next) async {
        if (next.tasks.single.dispatches.isNotEmpty) {
          saving.complete();
          await allowSave.future;
        }
      };
      final first = c.dispatch(task, [machine('a')]);
      await saving.future;
      expect(await c.dispatch(task, [machine('a')]), isNotEmpty);
      expect(gateway.calls, isEmpty);
      allowSave.complete();
      expect(await first, isEmpty);
      expect(gateway.calls, hasLength(1));
    },
  );

  test(
    'lost response preserves latest intent instead of trusting an old success',
    () async {
      final (c, store, gateway, task) = await _setup();
      await c.dispatch(task, [machine('a')]);
      gateway.history['a']!.single.state = TaskState.TASK_STATE_SUCCEEDED;
      await c.refresh();
      gateway.loseResponse = true;
      final errors = await c.dispatch(task, [machine('a')]);
      expect(errors['节点 a'], contains('执行结果未确认'));
      final latestId = c.state.tasks.single.latestDispatch('a')!.executionId;
      expect(latestId, isNot(task.id));
      // The service loses its most recent record; an older success remains.
      gateway.history['a']!.removeLast();
      await c.refresh();
      expect(c.activeDispatchCount(task), 1);
      expect(c.isDispatchBlocked(task, 'a'), isTrue);
      store.state = SavedState.decode(store.state.encode());
      final reloaded = controller(store: store, gateway: gateway);
      addTearDown(reloaded.dispose);
      await reloaded.initialize(poll: false);
      expect(await reloaded.dispatch(task, [machine('a')]), isNotEmpty);
      expect(gateway.calls, hasLength(2));
      gateway.history['a']!.add(
        TaskStatus(id: latestId, state: TaskState.TASK_STATE_SUCCEEDED),
      );
      await reloaded.refresh();
      expect(reloaded.activeDispatchCount(reloaded.state.tasks.single), 0);
      expect(gateway.calls, hasLength(2));
    },
  );

  test(
    'an explicit rejection rolls back the intent and permits a later attempt',
    () async {
      final (c, _, gateway, task) = await _setup();
      gateway.beforeSubmit = (_, _) async {
        throw const TaskSubmissionRejected('队列已满');
      };
      final errors = await c.dispatch(task, [machine('a')]);
      expect(errors['节点 a'], '队列已满');
      expect(c.state.tasks.single.dispatches, isEmpty);
      expect(c.activeDispatchCount(task), 0);
      gateway.beforeSubmit = null;
      expect(await c.dispatch(task, [machine('a')]), isEmpty);
      expect(c.activeDispatchCount(task), 1);
    },
  );
  test(
    'a delayed cancellation cannot erase a confirmed order and payment',
    () async {
      final (c, _, gateway, task) = await _setup();
      await c.dispatch(task, [machine('a')]);
      final captured = Completer<void>();
      final deliver = Completer<void>();
      gateway.beforeCancelResponse = () async {
        captured.complete();
        await deliver.future;
      };
      final cancellation = c.cancel(machine('a'), task.id);
      await captured.future;
      gateway.history['a']!.single
        ..state = TaskState.TASK_STATE_SUCCEEDED
        ..payment = OrderPayment(orderId: '123');
      await c.refresh();
      deliver.complete();
      await cancellation;
      expect(
        c.statuses['a']!.tasks.single.state,
        TaskState.TASK_STATE_SUCCEEDED,
      );
      expect(c.statuses['a']!.tasks.single.payment.orderId, '123');
      expect(c.activeDispatchCount(task), 0);
    },
  );

  test(
    'an acknowledged completion survives a queued save and an empty older poll',
    () async {
      final (c, store, gateway, task) = await _setup();
      await c.dispatch(task, [machine('a')]);
      final polled = Completer<void>();
      final oldPoll = Completer<AgentStatus>();
      gateway.readStatus = (m) async {
        if (m.id != 'a') return gateway.snapshot(m.id);
        polled.complete();
        return oldPoll.future;
      };
      final poll = c.refresh();
      await polled.future;
      final saving = Completer<void>();
      final allowSave = Completer<void>();
      store.beforeSave = (_) async {
        if (!saving.isCompleted) {
          saving.complete();
          await allowSave.future;
        }
      };
      final themeSave = c.setThemeMode(AppThemeMode.dark);
      await saving.future;
      final cancelled = c.cancel(machine('a'), task.id);
      while (c.statuses['a']!.tasks.single.state !=
          TaskState.TASK_STATE_CANCELLED) {
        await Future<void>.delayed(Duration.zero);
      }
      oldPoll.complete(AgentStatus());
      await poll;
      expect(c.statuses['a']!.tasks, isEmpty);
      gateway.readStatus = null;
      gateway.failStatus = true;
      allowSave.complete();
      await Future.wait([themeSave, cancelled]);
      expect(store.state.tasks.single.latestDispatch('a')!.finished, isTrue);
      expect(c.activeDispatchCount(task), 0);
    },
  );
}
