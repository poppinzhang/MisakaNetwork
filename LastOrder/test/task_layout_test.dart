import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

Finder taskCard(String id) => find.byKey(ValueKey('task-card-$id'));
Finder monitorCard(String machineId, String taskId) =>
    find.byKey(ValueKey('monitor-card-$machineId-$taskId'));
Finder inside(Finder card, String text) =>
    find.descendant(of: card, matching: find.textContaining(text));

TicketTask sampleTask(
  String id, {
  String accountId = 'account-a',
  bool summary = true,
  bool longText = false,
}) => TicketTask.fromJson({
  'id': id,
  'name': longText ? '非常长的任务名称用于检查双列布局中的完整换行与操作可见性' : '同名任务',
  'accountId': accountId,
  'startAt': '2026-12-01T20:00:00',
  'requestIntervalMs': 750,
  'dispatchedTo': ['machine-a', 'machine-b'],
  if (summary)
    'summary': {
      'projectName': longText ? '非常长的演出名称：御坂网络冬季特别音乐会与跨年纪念演出完整版' : '演出 $id',
      'screenName': longText ? '特别场次：十二月晚场及完整入场时间说明' : '晚场 $id',
      'ticketName': longText ? '前排指定区域全价票及特别入场权益长名称' : '票档 $id',
      'selectedDate': '2026-12-20',
      'quantity': 2,
    },
});

class TaskLayoutGateway extends FakeGateway {
  final snapshots = <String, AgentStatus>{};

  @override
  Future<AgentStatus> status(Machine machine) async => snapshots[machine.id]!;

  @override
  Future<TaskStatus> cancel(Machine machine, String id) async {
    final result = await super.cancel(machine, id);
    for (final task in snapshots[machine.id]!.tasks) {
      if (task.id == id) task.state = TaskState.TASK_STATE_CANCELLED;
    }
    return result;
  }
}

Future<
  ({AppController controller, TaskLayoutGateway gateway, MemoryStore store})
>
openTaskPage(
  WidgetTester tester, {
  required String page,
  double width = 1360,
  bool longText = false,
  bool orphan = false,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = MemoryStore()
    ..state = SavedState(
      machines: [machine('machine-a'), machine('machine-b')],
      accounts: [
        Account(id: 'account-a', name: '账号甲', uid: '10001'),
        Account(id: 'account-b', name: '账号乙', uid: '10002'),
      ],
      tasks: [
        sampleTask('task-a'),
        sampleTask('task-b', accountId: 'account-b', longText: longText),
        sampleTask('task-c', summary: false, accountId: 'missing-account'),
      ],
    )
    ..secrets['task.task-a'] = '{}'
    ..secrets['task.task-b'] = '{}';
  TaskStatus remoteTask(String id, {bool events = false}) => TaskStatus(
    id: id,
    name: '同名任务',
    state: TaskState.TASK_STATE_RUNNING,
    message: events
        ? '节点执行事件 11：准备完成并等待开票'
        : longText && id == 'task-b'
        ? '正在等待平台返回执行进度，此处较长的任务进度说明应完整显示，并保持同一行卡片高度一致。'
        : '等待开票',
    events: events
        ? [
            for (var i = 0; i < 12; i++)
              TaskEvent(level: 'info', message: '节点执行事件 $i：准备完成并等待开票'),
          ]
        : [],
  );
  final gateway = TaskLayoutGateway()
    ..snapshots.addAll({
      'machine-a': AgentStatus(
        runtimeReady: true,
        tasks: [remoteTask('task-a', events: true), remoteTask('task-b')],
      ),
      'machine-b': AgentStatus(
        runtimeReady: true,
        tasks: [
          remoteTask('task-a'),
          if (orphan) ...[remoteTask('task-c'), remoteTask('orphan-task')],
        ],
      ),
    });
  final c = controller(store: store, gateway: gateway);
  await c.initialize(poll: false);
  addTearDown(c.dispose);
  c.statuses.addAll(gateway.snapshots);
  await tester.pumpWidget(LastOrderApp(controller: c));
  await tester.pumpAndSettle();
  await tester.tap(width >= 600 ? find.byTooltip(page) : find.text(page).first);
  await tester.pumpAndSettle();
  return (controller: c, gateway: gateway, store: store);
}

List<Finder> pageCards(String page) => page == '账号与任务'
    ? [taskCard('task-a'), taskCard('task-b'), taskCard('task-c')]
    : [
        monitorCard('machine-a', 'task-a'),
        monitorCard('machine-a', 'task-b'),
        monitorCard('machine-b', 'task-a'),
      ];

void main() {
  for (final page in ['账号与任务', '任务监控']) {
    testWidgets('$page uses two desktop columns and one narrow column', (
      tester,
    ) async {
      await openTaskPage(tester, page: page);
      final cards = pageCards(page);
      for (final width in [1360.0, 1024.0, 800.0, 390.0]) {
        tester.view.physicalSize = Size(width, 1400);
        await tester.pumpAndSettle();
        final a = tester.getRect(cards[0]);
        final b = tester.getRect(cards[1]);
        final c = tester.getRect(cards[2]);
        expect(a.width, closeTo(b.width, 0.01));
        expect(c.width, closeTo(a.width, 0.01));
        expect(c.left, a.left);
        if (width >= 1024) {
          expect(a.top, b.top);
          expect(a.bottom, b.bottom);
          expect(b.left - a.right, closeTo(16, 0.01));
          expect(c.top - a.bottom, closeTo(16, 0.01));
          expect(b.right, closeTo(width - 32, 0.01));
        } else {
          expect(a.left, b.left);
          expect(b.top - a.bottom, closeTo(16, 0.01));
          expect(c.top - b.bottom, closeTo(16, 0.01));
          expect(a.right, closeTo(width - 16, 0.01));
        }
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('$page switches to a single column when text is enlarged', (
      tester,
    ) async {
      await openTaskPage(tester, page: page, width: 900);
      final cards = pageCards(page);
      expect(tester.getRect(cards[0]).top, tester.getRect(cards[1]).top);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pumpAndSettle();
      final a = tester.getRect(cards[0]);
      final b = tester.getRect(cards[1]);
      expect(a.left, b.left);
      expect(a.width, b.width);
      expect(b.top, greaterThan(a.bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$page keeps long details and actions inside equal-height cards',
      (tester) async {
        await openTaskPage(tester, page: page, width: 1024, longText: true);
        final cards = pageCards(page);
        final a = tester.getRect(cards[0]);
        final b = tester.getRect(cards[1]);
        expect(a.top, b.top);
        expect(a.bottom, b.bottom);
        for (final value in [
          '账号乙',
          if (page == '账号与任务') ...['10002', '非常长的演出名称'],
          '特别场次',
          '前排指定区域',
          page == '账号与任务' ? '分发' : '停止',
        ]) {
          final text = inside(cards[1], value);
          expect(text, findsWidgets);
          for (final element in text.evaluate()) {
            final rect = tester.getRect(
              find.byElementPredicate((e) => e == element),
            );
            expect(rect.left, greaterThanOrEqualTo(b.left));
            expect(rect.right, lessThanOrEqualTo(b.right));
            expect(rect.top, greaterThanOrEqualTo(b.top));
            expect(rect.bottom, lessThanOrEqualTo(b.bottom));
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'task cards show account identity and ticket details independently of names',
    (tester) async {
      await openTaskPage(tester, page: '账号与任务');
      for (final entry in [
        ('task-a', '账号甲', '10001'),
        ('task-b', '账号乙', '10002'),
      ]) {
        final card = taskCard(entry.$1);
        for (final value in [
          entry.$2,
          entry.$3,
          '演出 ${entry.$1}',
          '晚场 ${entry.$1}',
          '票档 ${entry.$1}',
          '2026-12-20',
          '2 张',
          '2026-12-01 20:00:00',
          '750 毫秒',
          '未结束',
        ]) {
          expect(inside(card, value), findsWidgets);
        }
      }
      expect(inside(taskCard('task-c'), '未记录场次与票档信息'), findsOneWidget);
      expect(inside(taskCard('task-c'), '账号已移除'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task counts release only machines whose executions have finished',
    (tester) async {
      final fixture = await openTaskPage(tester, page: '账号与任务');
      final card = taskCard('task-a');
      expect(inside(card, '未结束 2 台'), findsOneWidget);

      fixture.gateway.snapshots['machine-a']!.tasks.first.state =
          TaskState.TASK_STATE_SUCCEEDED;
      await fixture.controller.refresh();
      await tester.pumpAndSettle();
      expect(inside(card, '未结束 1 台'), findsOneWidget);

      await fixture.controller.cancel(machine('machine-b'), 'task-a');
      await tester.pumpAndSettle();
      expect(inside(card, '未结束 0 台'), findsOneWidget);
      expect(inside(card, '分发'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'monitor joins repeated execution IDs and stops the selected execution',
    (tester) async {
      final fixture = await openTaskPage(tester, page: '任务监控');
      final state = fixture.controller.state;
      fixture.controller.state = SavedState(
        machines: state.machines,
        accounts: state.accounts,
        tasks: [
          for (final task in state.tasks)
            task.id == 'task-a'
                ? task.withDispatches([
                    const TaskDispatch(
                      machineId: 'machine-a',
                      executionId: 'task-a',
                      finished: true,
                    ),
                    const TaskDispatch(
                      machineId: 'machine-a',
                      executionId: 'repeat-execution',
                    ),
                  ])
                : task,
        ],
      );
      fixture.gateway.snapshots['machine-a']!.tasks.first.state =
          TaskState.TASK_STATE_SUCCEEDED;
      fixture.gateway.snapshots['machine-a']!.tasks.add(
        TaskStatus(
          id: 'repeat-execution',
          name: '同名任务',
          state: TaskState.TASK_STATE_RUNNING,
        ),
      );
      await fixture.controller.refresh();
      await tester.pumpAndSettle();

      final repeated = monitorCard('machine-a', 'repeat-execution');
      expect(inside(repeated, '账号甲'), findsOneWidget);
      expect(inside(repeated, '晚场 task-a'), findsOneWidget);
      expect(inside(repeated, '本地任务已移除'), findsNothing);
      final stop = inside(repeated, '停止');
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(fixture.gateway.cancelled, ['machine-a:repeat-execution']);
      expect(inside(repeated, '已停止'), findsOneWidget);
      expect(inside(monitorCard('machine-b', 'task-a'), '执行中'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'monitor joins local metadata by task ID and preserves separate machine records',
    (tester) async {
      await openTaskPage(tester, page: '任务监控', orphan: true);
      for (final machineId in ['machine-a', 'machine-b']) {
        final card = monitorCard(machineId, 'task-a');
        expect(inside(card, '账号甲'), findsOneWidget);
        expect(inside(card, '晚场 task-a'), findsOneWidget);
        expect(inside(card, '票档 task-a'), findsOneWidget);
        expect(inside(card, '2026-12-20'), findsOneWidget);
        expect(
          inside(card, '晚场 task-a').evaluate().single,
          same(inside(card, '票档 task-a').evaluate().single),
        );
        for (final hidden in [
          'UID',
          '10001',
          '演出 task-a',
          '演出 task-b',
          '2 张',
          '2026-12-01 20:00:00',
        ]) {
          expect(inside(card, hidden), findsNothing);
        }
      }
      final b = monitorCard('machine-a', 'task-b');
      expect(inside(b, '账号乙'), findsOneWidget);
      expect(inside(b, '晚场 task-b'), findsOneWidget);
      expect(inside(b, '票档 task-b'), findsOneWidget);
      expect(inside(b, '晚场 task-a'), findsNothing);
      expect(inside(b, '账号甲'), findsNothing);
      expect(inside(b, '10002'), findsNothing);
      final legacy = monitorCard('machine-b', 'task-c');
      expect(inside(legacy, '未记录场次与票档信息'), findsOneWidget);
      expect(inside(legacy, '账号已移除'), findsOneWidget);
      final missing = monitorCard('machine-b', 'orphan-task');
      expect(inside(missing, '本地任务已移除，无法显示账号与场次'), findsOneWidget);
      expect(inside(missing, '账号甲'), findsNothing);
      expect(inside(missing, '停止'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('deleting the right task removes only its local configuration', (
    tester,
  ) async {
    final fixture = await openTaskPage(tester, page: '账号与任务');
    final remove = find.descendant(
      of: taskCard('task-b'),
      matching: find.byTooltip('删除任务'),
    );
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.text('删除本地任务'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(taskCard('task-b'), findsOneWidget);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(fixture.controller.state.tasks.map((t) => t.id), [
      'task-a',
      'task-c',
    ]);
    expect(fixture.store.secrets.containsKey('task.task-a'), isTrue);
    expect(fixture.store.secrets.containsKey('task.task-b'), isFalse);
    expect(fixture.gateway.cancelled, isEmpty);
    expect(taskCard('task-b'), findsNothing);
    expect(
      tester.getRect(taskCard('task-a')).top,
      tester.getRect(taskCard('task-c')).top,
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'stopping a monitor card targets only the selected machine and task',
    (tester) async {
      final fixture = await openTaskPage(tester, page: '任务监控');
      final stop = inside(monitorCard('machine-b', 'task-a'), '停止');
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pumpAndSettle();
      expect(find.textContaining('停止 节点 machine-b 上的'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(fixture.gateway.cancelled, ['machine-b:task-a']);
      expect(inside(monitorCard('machine-a', 'task-a'), '执行中'), findsOneWidget);
      expect(inside(monitorCard('machine-b', 'task-a'), '已停止'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'recent messages expand within aligned cards and retain state across layout changes',
    (tester) async {
      await openTaskPage(tester, page: '任务监控');
      final a = monitorCard('machine-a', 'task-a');
      final b = monitorCard('machine-a', 'task-b');
      final originalHeight = tester.getRect(a).height;
      expect(inside(a, '节点执行事件 11：'), findsOneWidget);
      expect(inside(a, '节点执行事件 10：'), findsNothing);
      await tester.tap(inside(a, '展开消息'));
      await tester.pumpAndSettle();
      for (final i in [9, 10, 11]) {
        expect(inside(a, '节点执行事件 $i：'), findsOneWidget);
      }
      expect(inside(a, '节点执行事件 8：'), findsNothing);
      expect(tester.getRect(a).height, greaterThan(originalHeight));
      expect(tester.getRect(a).bottom, tester.getRect(b).bottom);
      expect(
        find.descendant(
          of: a,
          matching: find.byWidgetPredicate(
            (w) => w is ScrollView || w is SingleChildScrollView,
          ),
        ),
        findsNothing,
      );
      await tester.tap(inside(a, '收起消息'));
      await tester.pumpAndSettle();
      expect(tester.getRect(a).height, closeTo(originalHeight, 0.01));
      expect(inside(a, '节点执行事件 10：'), findsNothing);
      await tester.tap(inside(a, '展开消息'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(800, 1400);
      await tester.pumpAndSettle();
      expect(inside(a, '收起消息'), findsOneWidget);
      expect(inside(a, '节点执行事件 9：'), findsOneWidget);
      expect(tester.getRect(b).top, greaterThan(tester.getRect(a).bottom));
      tester.view.physicalSize = const Size(1360, 1400);
      await tester.pumpAndSettle();
      expect(tester.getRect(a).bottom, tester.getRect(b).bottom);
      await tester.tap(find.byTooltip('账号与任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('任务监控'));
      await tester.pumpAndSettle();
      expect(inside(a, '收起消息'), findsOneWidget);
      expect(inside(a, '节点执行事件 9：'), findsOneWidget);
      expect(tester.getRect(a).bottom, tester.getRect(b).bottom);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new messages replace the oldest visible message without scrolling the page',
    (tester) async {
      final fixture = await openTaskPage(tester, page: '任务监控');
      final card = monitorCard('machine-a', 'task-a');
      await tester.tap(inside(card, '展开消息'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1360, 640);
      await tester.pumpAndSettle();
      final pageScroll = find.ancestor(
        of: card,
        matching: find.byType(SingleChildScrollView),
      );
      expect(pageScroll, findsOneWidget);
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(of: pageScroll, matching: find.byType(Scrollable))
                .first,
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      position.jumpTo(position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      final offset = position.pixels;
      final remote = fixture.gateway.snapshots['machine-a']!.tasks.first;
      remote.events.add(TaskEvent(level: 'info', message: '节点执行事件 12：正在下单'));
      remote.message = '节点执行事件 12：正在下单';
      await fixture.controller.refresh();
      await tester.pumpAndSettle();
      expect(inside(card, '节点执行事件 9：'), findsNothing);
      for (final i in [10, 11, 12]) {
        expect(inside(card, '节点执行事件 $i：'), findsOneWidget);
      }
      expect(
        tester.getRect(inside(card, '节点执行事件 12：')).top,
        greaterThan(tester.getRect(inside(card, '节点执行事件 11：')).top),
      );
      expect(position.pixels, closeTo(offset, 0.01));
      expect(
        find.descendant(
          of: card,
          matching: find.byWidgetPredicate(
            (w) => w is ScrollView || w is SingleChildScrollView,
          ),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
