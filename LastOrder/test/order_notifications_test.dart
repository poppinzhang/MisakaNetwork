import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

class _CancelGateway extends FakeGateway {
  final reply = Completer<TaskStatus>();
  @override
  Future<TaskStatus> cancel(Machine m, String id) => reply.future;
}

TaskStatus created(String id, {String? orderId = '987654321'}) => TaskStatus(
  id: id,
  state: TaskState.TASK_STATE_SUCCEEDED,
  orderCreated: true,
  payment: orderId == null ? null : OrderPayment(orderId: orderId),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('misaka/notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MemoryStore store;
  late FakeGateway gateway;
  late List<MethodCall> calls;
  late bool granted, delivered;

  setUp(() {
    store = MemoryStore()
      ..state = SavedState(
        accounts: [Account(id: 'local', name: '测试账号', uid: '12345')],
        machines: [machine('a'), machine('b')],
        tasks: [
          TicketTask(
            id: 'task',
            name: '演出',
            accountId: 'local',
            dispatchedTo: ['a', 'b'],
          ),
          TicketTask(
            id: 'other',
            name: '另一任务',
            accountId: 'local',
            dispatchedTo: ['a'],
          ),
        ],
      );
    gateway = FakeGateway();
    calls = [];
    granted = true;
    delivered = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'requestPermission':
          return granted;
        case 'showSuccess':
          return delivered;
        default:
          throw MissingPluginException();
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<AppController> start() async {
    final c = controller(store: store, gateway: gateway);
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    return c;
  }

  test(
    'old settings and denied permission stay off without a startup prompt',
    () async {
      final json = jsonDecode(store.state.encode()) as Map<String, dynamic>;
      json.remove('success_notifications_enabled');
      json.remove('observed_order_notifications');
      store.state = SavedState.decode(jsonEncode(json));
      final c = await start();
      expect(c.state.successNotificationsEnabled, isFalse);
      expect(calls, isEmpty);
      granted = false;
      await expectLater(
        c.setSuccessNotificationsEnabled(true),
        throwsA(isA<UserError>()),
      );
      expect(store.state.successNotificationsEnabled, isFalse);
      expect(calls.map((c) => c.method), ['requestPermission']);
    },
  );

  test('progress, failed, cancelled, duplicate, legacy and unknown results are silent', () async {
    final c = await start();
    await c.setSuccessNotificationsEnabled(true);
    for (final state in TaskState.values) {
      gateway.remoteTasks
        ..clear()
        ..add(
          TaskStatus(
            id: 'task',
            state: state,
            // A successful-looking event, message or payment can never trigger an alert.
            message: '已下单',
            events: [TaskEvent(message: '抢票成功')],
            payment: OrderPayment(orderId: '987654321'),
            orderCreated: state != TaskState.TASK_STATE_SUCCEEDED,
          ),
        );
      await c.refresh();
    }
    gateway.remoteTasks.add(created('unknown'));
    gateway.fail.add('b');
    await c.refresh();
    expect(calls.map((c) => c.method), ['requestPermission']);
    expect(store.state.observedOrderNotifications, isEmpty);
    expect(c.notificationDeliveryError, isNull);
  });

  test('one order across machines, polls and restart is delivered once, without private fields', () async {
    final c = await start();
    await c.setSuccessNotificationsEnabled(true);
    final result = created('task')
      ..message = 'PRIVATE EVENT'
      ..payment.paymentCodeUrl = 'https://qr.alipay.com/PRIVATE_TOKEN';
    gateway.remoteTasks.add(result);
    await Future.wait([c.refresh(), c.refresh()]);
    await c.refresh();
    final restarted = await start();
    await restarted.refresh();
    expect(restarted.state.successNotificationsEnabled, isTrue);
    expect(calls.map((c) => c.method), ['requestPermission', 'showSuccess']);
    final args = calls.last.arguments as Map;
    expect(args.keys, unorderedEquals(['id', 'title', 'body']));
    expect(args['title'], '抢票成功');
    expect(args['id'], store.state.observedOrderNotifications.single);
    for (final private in ['PRIVATE', '987654321', '测试账号', '演出', '12345']) {
      expect(args.toString(), isNot(contains(private)));
    }
    expect(store.state.encode(), isNot(contains('987654321')));
    expect(store.state.encode(), isNot(contains('PRIVATE')));
    gateway.remoteTasks.add(created('other', orderId: '876543210'));
    await restarted.refresh();
    expect(calls.where((c) => c.method == 'showSuccess'), hasLength(2));
  });

  test(
    'off-period results stay silent after opt-in, including across restart',
    () async {
      final c = await start();
      gateway.remoteTasks.add(created('task'));
      await c.refresh();
      expect(calls, isEmpty);
      await c.setSuccessNotificationsEnabled(true);
      await c.refresh();
      await c.setSuccessNotificationsEnabled(false);
      gateway.remoteTasks.add(created('other', orderId: '22'));
      await c.refresh();
      final restarted = await start();
      await restarted.setSuccessNotificationsEnabled(true);
      await restarted.refresh();
      expect(calls.map((c) => c.method), [
        'requestPermission',
        'requestPermission',
      ]);
    },
  );

  test(
    'missing payment details still notify once for the confirmed execution',
    () async {
      final c = await start();
      await c.setSuccessNotificationsEnabled(true);
      gateway.fail.add('b');
      gateway.remoteTasks.add(created('task', orderId: null));
      store.failSave = true;
      await c.refresh();
      expect(calls, hasLength(1));
      store.failSave = false;
      await c.refresh();
      await c.refresh();
      expect(calls.map((c) => c.method), ['requestPermission', 'showSuccess']);
    },
  );

  test('a late confirmed order in concurrent cancel and poll replies is claimed once', () async {
    final g = _CancelGateway();
    gateway = g;
    final c = await start();
    await c.setSuccessNotificationsEnabled(true);
    final startedSave = Completer<void>(), releaseSave = Completer<void>();
    store.beforeSave = (_) async {
      if (!startedSave.isCompleted) startedSave.complete();
      await releaseSave.future;
    };
    final cancel = c.cancel(c.state.machines.first, 'task');
    final result = created('task');
    g.remoteTasks.add(result);
    final poll = c.refresh();
    await startedSave.future;
    g.reply.complete(result);
    await Future<void>.delayed(Duration.zero);
    releaseSave.complete();
    await Future.wait([cancel, poll]);
    expect(calls.map((c) => c.method), ['requestPermission', 'showSuccess']);
  });

  test(
    'blocked delivery keeps the order and does not prompt or retry each poll',
    () async {
      final c = await start();
      await c.setSuccessNotificationsEnabled(true);
      delivered = false;
      gateway.remoteTasks.add(created('task'));
      await c.refresh();
      await c.refresh();
      expect(c.notificationDeliveryError, isNotNull);
      expect(c.statuses['a']!.tasks.single.orderCreated, isTrue);
      expect(c.connectionErrors, isEmpty);
      expect(calls.map((c) => c.method), ['requestPermission', 'showSuccess']);
    },
  );
}
