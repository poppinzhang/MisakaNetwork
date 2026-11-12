import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/dispatch_dialog.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

class _WorkloadGateway extends FakeGateway {
  final tasksByMachine = <String, List<TaskStatus>>{};
  final statusCalls = <String, int>{};
  Future<void>? statusGate;

  @override
  Future<AgentStatus> status(Machine machine) async {
    statusCalls.update(machine.id, (count) => count + 1, ifAbsent: () => 1);
    await statusGate;
    if (this.fail.contains(machine.id)) throw const UserError('连接失败');
    return AgentStatus(
      tasks: tasksByMachine[machine.id] ?? [],
      runtimeReady: true,
      maxConcurrency: 2,
      supportsTimeStart: true,
    );
  }
}

class _DialogResult {
  _DialogResult(this.controller);

  final AppController controller;
  final navigation = _NavigationObserver();
  bool returned = false;
  List<String>? machines;
}

class _NavigationObserver extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount++;
    super.didPop(route, previousRoute);
  }
}

TicketTask _task(String id, {List<String> dispatchedTo = const []}) =>
    TicketTask(
      id: id,
      name: '任务 $id',
      accountId: 'account',
      dispatchedTo: dispatchedTo,
    );

Future<_DialogResult> _openDialog(
  WidgetTester tester, {
  required _WorkloadGateway gateway,
  List<String> machineIds = const ['a'],
  TicketTask? target,
  List<TicketTask> existingTasks = const [],
  Map<String, AgentStatus> cached = const {},
  double width = 1100,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final task = target ?? _task('new');
  final store = MemoryStore()
    ..state = SavedState(
      machines: machineIds.map(machine).toList(),
      tasks: [task, ...existingTasks],
    );
  final AppController c = controller(store: store, gateway: gateway);
  await c.initialize(poll: false);
  c.statuses.addAll(cached);
  addTearDown(c.dispose);
  final result = _DialogResult(c);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      navigatorObservers: [result.navigation],
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result.machines = await showDialog<List<String>>(
                context: context,
                builder: (_) => DispatchDialog(
                  controller: c,
                  task: task,
                  startDescription: '分发后立即开始',
                ),
              );
              result.returned = true;
            },
            child: const Text('打开分发'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开分发'));
  await tester.pumpAndSettle();
  return result;
}

Finder _machineTile(String id) => find.byKey(ValueKey('dispatch-machine-$id'));

Finder _tileText(String id, String text) =>
    find.descendant(of: _machineTile(id), matching: find.text(text));

Finder _riskText(String text) => find.descendant(
  of: find.ancestor(of: find.text('多任务风险'), matching: find.byType(AlertDialog)),
  matching: find.text(text),
);

Future<void> _selectMachine(WidgetTester tester, String id) async {
  final name = _tileText(id, '节点 $id');
  await tester.ensureVisible(name);
  await tester.tap(name);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'each machine displays its active workload and omits terminal tasks',
    (tester) async {
      final gateway = _WorkloadGateway()
        ..tasksByMachine['a'] = [
          TaskStatus(
            id: 'running',
            name: '演出甲',
            state: TaskState.TASK_STATE_RUNNING,
          ),
          TaskStatus(
            id: 'queued',
            name: '演出乙',
            state: TaskState.TASK_STATE_QUEUED,
          ),
          TaskStatus(
            id: 'done',
            name: '已完成演出',
            state: TaskState.TASK_STATE_SUCCEEDED,
          ),
          TaskStatus(
            id: 'failed',
            name: '已失败演出',
            state: TaskState.TASK_STATE_FAILED,
          ),
          TaskStatus(
            id: 'stopped',
            name: '已停止演出',
            state: TaskState.TASK_STATE_CANCELLED,
          ),
        ]
        ..tasksByMachine['b'] = [
          TaskStatus(id: 'remote-only', name: '未保存在本地的任务'),
        ];
      await _openDialog(tester, gateway: gateway, machineIds: ['a', 'b', 'c']);

      expect(_tileText('a', '当前负载：2 个任务'), findsOneWidget);
      expect(_tileText('a', '演出甲 · 执行中（含等待开售）'), findsOneWidget);
      expect(_tileText('a', '演出乙 · 排队中'), findsOneWidget);
      expect(_tileText('b', '当前负载：1 个任务'), findsOneWidget);
      expect(_tileText('b', '未保存在本地的任务 · 状态待确认'), findsOneWidget);
      expect(_tileText('c', '当前负载：0 个任务'), findsOneWidget);
      for (final name in ['已完成演出', '已失败演出', '已停止演出']) {
        expect(find.textContaining(name), findsNothing);
      }
      expect(gateway.statusCalls, {'a': 1, 'b': 1, 'c': 1});
      expect(gateway.submitted, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'busy selection warns inline and requires explicit confirmation',
    (tester) async {
      final gateway = _WorkloadGateway()
        ..tasksByMachine['a'] = [
          TaskStatus(
            id: 'existing',
            name: '已有任务',
            state: TaskState.TASK_STATE_QUEUED,
          ),
        ];
      final result = await _openDialog(tester, gateway: gateway);
      expect(find.textContaining('多任务风险'), findsNothing);
      await _selectMachine(tester, 'a');
      expect(find.text('多任务风险：追加任务容易触发购票网站的风控。'), findsOneWidget);
      await tester.tap(find.text('提交到 1 台机器'));
      await tester.pumpAndSettle();

      expect(find.text('多任务风险'), findsOneWidget);
      expect(_riskText('已有任务 · 排队中'), findsOneWidget);
      expect(result.returned, isFalse);
      expect(gateway.submitted, isEmpty);
      await tester.tap(find.text('返回选择'));
      await tester.pumpAndSettle();
      expect(find.text('多任务风险'), findsNothing);
      expect(tester.widget<CheckboxListTile>(_machineTile('a')).value, isTrue);
      expect(result.returned, isFalse);
      expect(gateway.submitted, isEmpty);

      await tester.tap(find.text('提交到 1 台机器'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍然分发'));
      await tester.pumpAndSettle();
      expect(result.returned, isTrue);
      expect(result.machines, ['a']);
      expect(gateway.statusCalls['a'], 3);
      expect(gateway.submitted, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('idle machines submit without a multi-task confirmation', (
    tester,
  ) async {
    final gateway = _WorkloadGateway()
      ..tasksByMachine['a'] = [
        TaskStatus(id: 'finished', state: TaskState.TASK_STATE_SUCCEEDED),
      ];
    final result = await _openDialog(
      tester,
      gateway: gateway,
      machineIds: ['a', 'b'],
      existingTasks: [
        _task('historical', dispatchedTo: ['a']),
      ],
    );
    await _selectMachine(tester, 'a');
    await _selectMachine(tester, 'b');
    expect(find.textContaining('多任务风险'), findsNothing);
    await tester.tap(find.text('提交到 2 台机器'));
    await tester.pumpAndSettle();

    expect(result.returned, isTrue);
    expect(result.machines, ['a', 'b']);
    expect(find.text('多任务风险'), findsNothing);
    expect(gateway.statusCalls, {'a': 2, 'b': 2});
  });

  testWidgets(
    'submission refresh catches a machine that became busy after selection',
    (tester) async {
      final gateway = _WorkloadGateway();
      final result = await _openDialog(tester, gateway: gateway);
      await _selectMachine(tester, 'a');
      expect(find.textContaining('多任务风险'), findsNothing);
      gateway.tasksByMachine['a'] = [
        TaskStatus(
          id: 'late',
          name: '刚分配的任务',
          state: TaskState.TASK_STATE_RUNNING,
        ),
      ];
      await tester.tap(find.text('提交到 1 台机器'));
      await tester.pumpAndSettle();

      expect(find.text('多任务风险'), findsOneWidget);
      expect(_riskText('刚分配的任务 · 执行中（含等待开售）'), findsOneWidget);
      expect(result.returned, isFalse);
      expect(gateway.statusCalls['a'], 2);
    },
  );

  testWidgets(
    'failed status queries retain known work and never imply an unknown machine is idle',
    (tester) async {
      final gateway = _WorkloadGateway()..fail.addAll(['a', 'b', 'c']);
      final result = await _openDialog(
        tester,
        gateway: gateway,
        machineIds: ['a', 'b', 'c'],
        existingTasks: [
          _task('local', dispatchedTo: ['b']),
        ],
        cached: {
          'a': AgentStatus(
            tasks: [
              TaskStatus(
                id: 'cached',
                name: '最近一次任务',
                state: TaskState.TASK_STATE_RUNNING,
              ),
            ],
          ),
        },
      );

      expect(_tileText('a', '最近已知负载：1 个任务'), findsOneWidget);
      expect(_tileText('a', '最近一次任务 · 执行中（含等待开售）'), findsOneWidget);
      expect(_tileText('b', '任务 local · 状态待确认'), findsOneWidget);
      expect(_tileText('c', '暂无可确认的任务记录，不能确定服务器空闲。'), findsOneWidget);
      expect(find.text('连接失败，负载未更新；请刷新后核对。'), findsNWidgets(3));
      expect(find.text('当前负载：0 个任务'), findsNothing);
      await _selectMachine(tester, 'b');
      await tester.tap(find.text('提交到 1 台机器'));
      await tester.pumpAndSettle();
      expect(find.text('多任务风险'), findsOneWidget);
      expect(_riskText('任务 local · 状态待确认'), findsOneWidget);
      expect(result.returned, isFalse);
      expect(gateway.submitted, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('persisted and newly discovered submissions are both disabled', (
    tester,
  ) async {
    final gateway = _WorkloadGateway()
      ..tasksByMachine['b'] = [
        TaskStatus(id: 'new', state: TaskState.TASK_STATE_RUNNING),
      ];
    await _openDialog(
      tester,
      gateway: gateway,
      machineIds: ['a', 'b', 'c'],
      target: _task('new', dispatchedTo: ['a']),
    );

    expect(
      tester.widget<CheckboxListTile>(_machineTile('a')).onChanged,
      isNull,
    );
    expect(
      tester.widget<CheckboxListTile>(_machineTile('b')).onChanged,
      isNull,
    );
    expect(
      tester.widget<CheckboxListTile>(_machineTile('c')).onChanged,
      isNotNull,
    );
    expect(find.text('node.example:20001 · 已提交，不会重复执行'), findsNWidgets(2));
    expect(find.textContaining('多任务风险'), findsNothing);
  });

  for (final becomesBusy in [false, true]) {
    testWidgets(
      'closing during submission refresh prevents a later ${becomesBusy ? 'risk dialog' : 'route pop'}',
      (tester) async {
        final gateway = _WorkloadGateway();
        final result = await _openDialog(tester, gateway: gateway);
        await _selectMachine(tester, 'a');
        if (becomesBusy) {
          gateway.tasksByMachine['a'] = [
            TaskStatus(
              id: 'late',
              name: '新任务',
              state: TaskState.TASK_STATE_RUNNING,
            ),
          ];
        }
        final gate = Completer<void>();
        gateway.statusGate = gate.future;
        await tester.tap(find.text('提交到 1 台机器'));
        await tester.pump();
        expect(find.text('正在刷新服务器负载…'), findsOneWidget);
        await tester.tap(find.text('返回'));
        // Finish while the dialog's reverse animation still keeps it mounted.
        await tester.pump(const Duration(milliseconds: 10));
        gate.complete();
        await tester.pumpAndSettle();

        expect(result.returned, isTrue);
        expect(result.machines, isNull);
        expect(result.navigation.popCount, 1);
        expect(find.text('打开分发').hitTestable(), findsOneWidget);
        expect(find.text('多任务风险'), findsNothing);
        expect(find.byType(DispatchDialog), findsNothing);
        expect(gateway.submitted, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'unknown workload requires risk confirmation even without known tasks',
    (tester) async {
      final gateway = _WorkloadGateway();
      final result = await _openDialog(tester, gateway: gateway);
      await _selectMachine(tester, 'a');
      gateway.fail.add('a');
      await tester.tap(find.text('提交到 1 台机器'));
      await tester.pumpAndSettle();

      expect(find.text('多任务风险'), findsOneWidget);
      expect(_riskText('部分服务器的负载状态未确认，无法排除多任务风险。'), findsOneWidget);
      expect(_riskText('暂无可确认的任务记录，不能确定服务器空闲。'), findsOneWidget);
      expect(result.returned, isFalse);
      expect(gateway.submitted, isEmpty);
      await tester.tap(find.text('返回选择'));
      await tester.pumpAndSettle();
      expect(result.returned, isFalse);
      expect(tester.widget<CheckboxListTile>(_machineTile('a')).value, isTrue);
    },
  );

  testWidgets(
    'a new workload discovered during confirmation needs another acknowledgement',
    (tester) async {
      final gateway = _WorkloadGateway()
        ..tasksByMachine['a'] = [
          TaskStatus(
            id: 'first',
            name: '原有任务',
            state: TaskState.TASK_STATE_RUNNING,
          ),
        ];
      final result = await _openDialog(
        tester,
        gateway: gateway,
        machineIds: ['a', 'b'],
      );
      await _selectMachine(tester, 'a');
      await _selectMachine(tester, 'b');
      await tester.tap(find.text('提交到 2 台机器'));
      await tester.pumpAndSettle();
      expect(find.text('多任务风险'), findsOneWidget);
      expect(_riskText('节点 a'), findsOneWidget);
      expect(_riskText('节点 b'), findsNothing);

      gateway.tasksByMachine['b'] = [
        TaskStatus(
          id: 'second',
          name: '确认期间新增任务',
          state: TaskState.TASK_STATE_QUEUED,
        ),
      ];
      await result.controller.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍然分发'));
      await tester.pumpAndSettle();

      expect(result.returned, isFalse);
      expect(find.text('多任务风险'), findsOneWidget);
      expect(_riskText('节点 b'), findsOneWidget);
      expect(_riskText('确认期间新增任务 · 排队中'), findsOneWidget);
      expect(gateway.submitted, isEmpty);
      await tester.tap(find.text('仍然分发'));
      await tester.pumpAndSettle();
      expect(result.returned, isTrue);
      expect(result.machines, ['a', 'b']);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      '320px ${brightness.name} dialogs keep long workloads and actions usable at large text scale',
      (tester) async {
        final gateway = _WorkloadGateway()
          ..tasksByMachine['a'] = [
            for (var index = 0; index < 18; index++)
              TaskStatus(
                id: 'existing-$index',
                name: '演出任务 $index',
                state: TaskState.TASK_STATE_QUEUED,
              ),
          ];
        final result = await _openDialog(
          tester,
          gateway: gateway,
          width: 320,
          textScale: 2,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        await _selectMachine(tester, 'a');
        await tester.ensureVisible(_tileText('a', '演出任务 17 · 排队中'));
        await tester.pumpAndSettle();
        expect(_tileText('a', '演出任务 17 · 排队中').hitTestable(), findsOneWidget);
        expect(find.text('提交到 1 台机器').hitTestable(), findsOneWidget);
        await tester.tap(find.text('提交到 1 台机器'));
        await tester.pumpAndSettle();
        expect(find.text('多任务风险'), findsOneWidget);
        await tester.ensureVisible(_riskText('演出任务 17 · 排队中'));
        await tester.pumpAndSettle();
        expect(_riskText('演出任务 17 · 排队中').hitTestable(), findsOneWidget);
        expect(find.text('返回选择').hitTestable(), findsOneWidget);
        expect(find.text('仍然分发').hitTestable(), findsOneWidget);
        await tester.tap(find.text('仍然分发'));
        await tester.pumpAndSettle();
        expect(result.returned, isTrue);
        expect(result.machines, ['a']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
