import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

Finder _card(String machineId, String executionId) =>
    find.byKey(ValueKey('monitor-card-$machineId-$executionId'));
Finder _clear(String machineId, String executionId) =>
    find.byKey(ValueKey('clear-execution-$machineId-$executionId'));
Finder get _clearAll => find.byKey(const ValueKey('clear-finished-executions'));
Finder _inside(Finder card, String text) =>
    find.descendant(of: card, matching: find.text(text));

TaskStatus _status(String id, TaskState state, {bool payment = false}) =>
    TaskStatus(
      id: id,
      name: '执行 $id',
      state: state,
      payment: payment
          ? OrderPayment(
              orderId: '12345',
              paymentCodeUrl:
                  'weixin://wxpay/bizpayurl?pr=synthetic_monitor_test',
            )
          : null,
    );

Future<
  ({
    AppController controller,
    MemoryStore store,
    FakeGateway gateway,
    Map<String, List<TaskStatus>> rows,
  })
>
_openMonitor(
  WidgetTester tester, {
  double width = 1100,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = MemoryStore()
    ..state = SavedState(
      machines: [machine('a'), machine('b')],
      accounts: [Account(id: 'account', name: '测试账号', uid: '10001')],
      tasks: [TicketTask(id: 'task', name: '测试任务', accountId: 'account')],
    );
  final rows = <String, List<TaskStatus>>{
    'a': [
      _status('task', TaskState.TASK_STATE_SUCCEEDED, payment: true),
      _status('stopped', TaskState.TASK_STATE_CANCELLED),
      _status('failed', TaskState.TASK_STATE_FAILED),
      _status('running', TaskState.TASK_STATE_RUNNING),
      _status('queued', TaskState.TASK_STATE_QUEUED),
      _status('unknown', TaskState.TASK_STATE_UNSPECIFIED),
    ],
    'b': [_status('task', TaskState.TASK_STATE_SUCCEEDED, payment: true)],
  };
  final gateway = FakeGateway()
    ..statusHandler = (machine) async => AgentStatus(
      runtimeReady: true,
      tasks: [for (final task in rows[machine.id]!) task.deepCopy()],
    );
  final c = controller(store: store, gateway: gateway);
  await c.initialize(poll: false);
  await c.refresh();
  addTearDown(c.dispose);
  await tester.pumpWidget(LastOrderApp(controller: c));
  await tester.pumpAndSettle();
  await tester.tap(
    width >= 600 ? find.byTooltip('任务监控') : find.text('任务监控').first,
  );
  await tester.pumpAndSettle();
  return (controller: c, store: store, gateway: gateway, rows: rows);
}

Future<void> _clearCard(
  WidgetTester tester,
  String machineId,
  String executionId,
) async {
  await tester.ensureVisible(_clear(machineId, executionId));
  await tester.tap(_clear(machineId, executionId));
  await tester.pumpAndSettle();
}

Future<void> _finishMessage(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'bulk clear removes all terminal executions in one save and keeps orders',
    (tester) async {
      final env = await _openMonitor(tester);
      var saves = 0;
      env.store.beforeSave = (_) async => saves++;
      expect(find.text('清除全部已结束任务'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(_clearAll).onPressed, isNotNull);
      await tester.ensureVisible(_clearAll);
      await tester.tap(_clearAll);
      await tester.pumpAndSettle();

      expect(saves, 1);
      expect(find.byType(AlertDialog), findsNothing);
      for (final id in ['task', 'stopped', 'failed']) {
        expect(_card('a', id), findsNothing);
      }
      expect(_card('b', 'task'), findsNothing);
      for (final id in ['running', 'queued', 'unknown']) {
        expect(_card('a', id), findsOneWidget);
      }
      expect(_inside(_card('a', 'running'), '停止'), findsOneWidget);
      expect(_inside(_card('a', 'queued'), '停止'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(_clearAll).onPressed, isNull);
      expect(find.text('已清除 4 条执行记录，订单入口仍保留'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('payment-order-10001:12345')),
        findsOneWidget,
      );
      expect(find.text('查看付款二维码'), findsOneWidget);
      expect(find.text('打开订单详情'), findsOneWidget);
      expect(env.gateway.cancelled, isEmpty);
      expect(env.gateway.submitted, isEmpty);
      expect(env.controller.state.tasks.single.id, 'task');

      await env.controller.refresh();
      await tester.pumpAndSettle();
      expect(_card('a', 'task'), findsNothing);
      expect(_card('b', 'task'), findsNothing);
      expect(tester.widget<OutlinedButton>(_clearAll).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await _finishMessage(tester);
    },
  );

  testWidgets('bulk clear failure keeps every record and can be retried', (
    tester,
  ) async {
    final env = await _openMonitor(tester);
    env.store.failSave = true;
    await tester.ensureVisible(_clearAll);
    await tester.tap(_clearAll);
    await tester.pumpAndSettle();

    for (final id in ['task', 'stopped', 'failed']) {
      expect(_card('a', id), findsOneWidget);
    }
    expect(_card('b', 'task'), findsOneWidget);
    expect(find.textContaining('写入失败'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(_clearAll).onPressed, isNotNull);

    env.store.failSave = false;
    await tester.tap(_clearAll);
    await tester.pumpAndSettle();
    expect(_card('a', 'task'), findsNothing);
    expect(_card('b', 'task'), findsNothing);
    expect(tester.widget<OutlinedButton>(_clearAll).onPressed, isNull);
    expect(tester.takeException(), isNull);
    await _finishMessage(tester);
  });

  testWidgets(
    'bulk clear disables actions while saving and wraps on narrow screens',
    (tester) async {
      final env = await _openMonitor(tester, width: 320, textScale: 1.8);
      final saved = Completer<void>();
      env.store.beforeSave = (_) => saved.future;
      await tester.ensureVisible(_clearAll);
      final button = tester.getRect(_clearAll);
      final label = tester.getRect(find.text('清除全部已结束任务'));
      expect(button.left, greaterThanOrEqualTo(16));
      expect(button.right, lessThanOrEqualTo(304));
      expect(label.left, greaterThanOrEqualTo(button.left));
      expect(label.right, lessThanOrEqualTo(button.right));
      expect(label.height, greaterThan(30));
      await tester.tap(_clearAll);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(_clearAll).onPressed, isNull);
      expect(tester.widget<TextButton>(_clear('a', 'task')).onPressed, isNull);
      expect(_card('a', 'task'), findsOneWidget);

      saved.complete();
      await tester.pumpAndSettle();
      expect(_card('a', 'task'), findsNothing);
      expect(_card('a', 'running'), findsOneWidget);
      expect(find.text('已清除 4 条执行记录，订单入口仍保留'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finishMessage(tester);
    },
  );

  testWidgets('only terminal executions expose the clear action', (
    tester,
  ) async {
    await _openMonitor(tester);
    for (final id in ['task', 'stopped', 'failed']) {
      expect(_clear('a', id), findsOneWidget);
      expect(_inside(_card('a', id), '停止'), findsNothing);
    }
    for (final id in ['running', 'queued', 'unknown']) {
      expect(_clear('a', id), findsNothing);
    }
    expect(_inside(_card('a', 'running'), '停止'), findsOneWidget);
    expect(_inside(_card('a', 'queued'), '停止'), findsOneWidget);
    expect(_inside(_card('a', 'unknown'), '停止'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'clear removes only the selected machine record and keeps orders',
    (tester) async {
      final env = await _openMonitor(tester);
      final dispatches = env.controller.state.tasks.single.dispatches
          .map((d) => d.toJson())
          .toList();
      await _clearCard(tester, 'a', 'task');

      expect(_card('a', 'task'), findsNothing);
      expect(_card('b', 'task'), findsOneWidget);
      expect(_card('a', 'stopped'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('已清除执行记录，订单入口仍保留'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('payment-order-10001:12345')),
        findsOneWidget,
      );
      expect(find.text('查看付款二维码'), findsOneWidget);
      expect(find.text('打开订单详情'), findsOneWidget);
      expect(
        env.controller.state.tasks.single.dispatches.map((d) => d.toJson()),
        dispatches,
      );
      expect(
        env.controller.statuses['a']!.tasks.any((t) => t.id == 'task'),
        isTrue,
      );
      expect(env.gateway.cancelled, isEmpty);
      expect(env.gateway.submitted, isEmpty);

      await _clearCard(tester, 'b', 'task');
      expect(_card('b', 'task'), findsNothing);
      expect(
        find.byKey(const ValueKey('payment-order-10001:12345')),
        findsOneWidget,
      );
      expect(find.text('查看付款二维码'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finishMessage(tester);
    },
  );

  testWidgets(
    'saved clearing survives later polls of the same terminal result',
    (tester) async {
      final env = await _openMonitor(tester);
      await _clearCard(tester, 'a', 'task');
      env.rows['a']!.first.message = '已完成的执行更新了说明';
      await env.controller.refresh();
      await tester.pumpAndSettle();

      expect(_card('a', 'task'), findsNothing);
      expect(_card('b', 'task'), findsOneWidget);
      expect(find.text('查看付款二维码'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finishMessage(tester);
    },
  );

  testWidgets('a failed save leaves the execution visible and retryable', (
    tester,
  ) async {
    final env = await _openMonitor(tester);
    env.store.failSave = true;
    await _clearCard(tester, 'a', 'task');

    expect(_card('a', 'task'), findsOneWidget);
    expect(tester.widget<TextButton>(_clear('a', 'task')).onPressed, isNotNull);
    expect(find.textContaining('写入失败'), findsOneWidget);
    expect(find.text('已清除执行记录，订单入口仍保留'), findsNothing);

    env.store.failSave = false;
    await _clearCard(tester, 'a', 'task');
    expect(_card('a', 'task'), findsNothing);
    expect(tester.takeException(), isNull);
    await _finishMessage(tester);
  });

  testWidgets(
    'late success and a new execution become visible after clearing',
    (tester) async {
      final env = await _openMonitor(tester);
      await _clearCard(tester, 'a', 'stopped');
      expect(_card('a', 'stopped'), findsNothing);
      env.rows['a']![1].state = TaskState.TASK_STATE_SUCCEEDED;
      env.rows['a']!.add(
        _status('new-execution', TaskState.TASK_STATE_RUNNING),
      );
      await env.controller.refresh();
      await tester.pumpAndSettle();

      expect(_card('a', 'stopped'), findsOneWidget);
      expect(_clear('a', 'stopped'), findsOneWidget);
      expect(_card('a', 'new-execution'), findsOneWidget);
      expect(_inside(_card('a', 'new-execution'), '停止'), findsOneWidget);
      expect(_clear('a', 'new-execution'), findsNothing);
      expect(tester.takeException(), isNull);
      await _finishMessage(tester);
    },
  );

  testWidgets('clear remains usable on a narrow screen with enlarged text', (
    tester,
  ) async {
    await _openMonitor(tester, width: 320, textScale: 1.8);
    await tester.ensureVisible(_clear('a', 'stopped'));
    final card = tester.getRect(_card('a', 'stopped'));
    final button = tester.getRect(_clear('a', 'stopped'));
    expect(button.left, greaterThanOrEqualTo(card.left));
    expect(button.right, lessThanOrEqualTo(card.right));
    await tester.tap(_clear('a', 'stopped'));
    await tester.pumpAndSettle();
    expect(_card('a', 'stopped'), findsNothing);
    expect(tester.takeException(), isNull);
    await _finishMessage(tester);
  });
}
