import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/android_order_monitor.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('misaka/notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<Object> calls;
  late FakeGateway gateway;
  late MemoryStore store;
  late Account account;

  TicketTask task(
    String id, {
    String accountId = 'account',
    List<TaskDispatch> dispatches = const [],
  }) => TicketTask(
    id: id,
    name: '演出',
    accountId: accountId,
    dispatches: dispatches,
  );

  Future<AppController> open(
    SavedState state, {
    Future<bool> Function(bool)? setActive,
    bool visible = true,
  }) async {
    store.state = state;
    final c = AppController(
      store: store,
      gateway: gateway,
      runtime: FakeRuntime(),
      helper: FakeHelper(),
      setAndroidBackgroundMonitoring:
          setActive ?? setNativeAndroidBackgroundMonitoring,
      cloudTemplateLoader: () async => [],
    );
    addTearDown(() {
      if (!c.disposed) c.dispose();
    });
    c.setMonitoringAppVisible(visible);
    await c.initialize(poll: false);
    return c;
  }

  SavedState pending({bool enabled = true}) => SavedState(
    successNotificationsEnabled: enabled,
    machines: [machine('a')],
    accounts: [account],
    tasks: [
      task(
        'ticket',
        dispatches: [const TaskDispatch(machineId: 'a', executionId: 'run')],
      ),
    ],
  );

  setUp(() {
    calls = [];
    gateway = FakeGateway();
    store = MemoryStore();
    account = Account(id: 'account', uid: '123', name: '账号');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setBackgroundMonitoring') {
        calls.add(call.arguments as bool);
        return call.arguments;
      }
      calls.add(call.method);
      return true;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('no service for idle, finished, orphaned or unpollable work', () async {
    final c = await open(
      SavedState(
        successNotificationsEnabled: true,
        accounts: [account],
        machines: [
          machine('a'),
          machine('b').copyWith(deploymentError: '未部署'),
          machine('tencent-gone'),
        ],
        tasks: [
          task('draft'),
          task(
            'old',
            dispatches: [
              const TaskDispatch(
                machineId: 'a',
                executionId: 'old',
                finished: true,
              ),
            ],
          ),
          task(
            'gone',
            dispatches: [
              const TaskDispatch(machineId: 'removed', executionId: 'gone'),
            ],
          ),
          task(
            'invalid',
            dispatches: [
              const TaskDispatch(machineId: 'b', executionId: 'invalid'),
            ],
          ),
          task(
            'cloud',
            dispatches: [
              const TaskDispatch(
                machineId: 'tencent-gone',
                executionId: 'cloud',
              ),
            ],
          ),
          task(
            'account-gone',
            accountId: 'removed',
            dispatches: [
              const TaskDispatch(machineId: 'a', executionId: 'orphan'),
            ],
          ),
        ],
      ),
    );
    gateway.remoteTasks.add(
      TaskStatus(id: 'foreign', state: TaskState.TASK_STATE_RUNNING),
    );
    await c.refresh();
    expect(calls, isEmpty);
  });

  test('a pending result survives disconnection and missing history until the last node finishes', () async {
    final c = await open(
      SavedState(
        successNotificationsEnabled: true,
        accounts: [account],
        machines: [machine('a'), machine('b')],
        tasks: [
          task(
            'ticket',
            dispatches: [
              const TaskDispatch(machineId: 'a', executionId: 'first'),
              const TaskDispatch(machineId: 'b', executionId: 'second'),
            ],
          ),
        ],
      ),
    );
    expect(calls, [true]);
    c.setMonitoringAppVisible(false);
    gateway.fail.add('a');
    await c.refresh();
    gateway.fail.clear();
    gateway.remoteTasks.add(
      TaskStatus(id: 'first', state: TaskState.TASK_STATE_FAILED),
    );
    await c.refresh();
    expect(calls, [true]);
    gateway.remoteTasks.add(
      TaskStatus(id: 'second', state: TaskState.TASK_STATE_SUCCEEDED),
    );
    await c.refresh();
    expect(calls, [true, false]);
    await c.refresh();
    expect(calls, [true, false]);
  });

  test('starts only when opted in and visible; denied service retries once per foreground visit', () async {
    bool permitted = false;
    final c = await open(
      pending(enabled: false),
      visible: false,
      setActive: (target) async {
        calls.add(target);
        return target && permitted;
      },
    );
    await c.setSuccessNotificationsEnabled(true);
    expect(calls, ['requestPermission']);
    c.setMonitoringAppVisible(true);
    await settle();
    expect(c.backgroundMonitoringError, isNotNull);
    c.setMonitoringAppVisible(true);
    await c.refresh();
    expect(calls, ['requestPermission', true]);
    permitted = true;
    c.setMonitoringAppVisible(false);
    c.setMonitoringAppVisible(true);
    await settle();
    expect(c.backgroundMonitoringError, isNull);
    c.setMonitoringAppVisible(false);
    c.setMonitoringAppVisible(true);
    await settle();
    expect(calls, ['requestPermission', true, true, true]);
    await c.setSuccessNotificationsEnabled(false);
    expect(calls.last, false);
  });

  test('disabling while a start is in flight waits for its acknowledgement and stops in the background', () async {
    final started = Completer<bool>();
    final c = await open(
      pending(),
      setActive: (target) async {
        calls.add(target);
        return target ? await started.future : false;
      },
    );
    c.setMonitoringAppVisible(false);
    await c.setSuccessNotificationsEnabled(false);
    expect(calls, [true]);
    started.complete(true);
    await settle();
    expect(calls, [true, false]);
    expect(c.notificationDeliveryError, isNull);
    expect(c.backgroundMonitoringError, isNull);
  });

  test('cancel racing a new order keeps the service through the actual notification handoff', () async {
    final posting = Completer<void>(), posted = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'showSuccess') {
        calls.add('showSuccess');
        posting.complete();
        await posted.future;
        return true;
      }
      calls.add(call.arguments as bool);
      return call.arguments;
    });
    final c = await open(pending());
    c.setMonitoringAppVisible(false);
    gateway.remoteTasks.add(
      TaskStatus(
        id: 'run',
        state: TaskState.TASK_STATE_SUCCEEDED,
        orderCreated: true,
      ),
    );
    final cancelled = c.cancel(c.state.machines.first, 'run');
    await posting.future;
    expect(calls, [true, 'showSuccess']);
    posted.complete();
    await cancelled;
    await c.refresh();
    expect(calls, [true, 'showSuccess', false]);
  });

  test('begins at explicit dispatch and stops after rejection or controller disposal', () async {
    final c = await open(
      SavedState(successNotificationsEnabled: true, machines: [machine('a')]),
    );
    final user = await c.addAccount('账号', [
      {'name': 's', 'value': 'v'},
    ], uid: '123');
    final ticket = await c.addTask('演出', user, {});
    gateway.fail.add('a');
    final failed = c.dispatch(ticket, c.state.machines);
    await failed;
    expect(calls, [true, false]);
    gateway.fail.clear();
    expect(await c.dispatch(ticket, c.state.machines), isEmpty);
    expect(calls, [true, false, true]);
    c.dispose();
    await settle();
    expect(calls, [true, false, true, false]);
  });
}
