import 'package:fixnum/fixnum.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/task_messages.dart';
import 'package:material_ui/material_ui.dart';

final _start = DateTime(2030, 1, 2, 3, 4, 0).millisecondsSinceEpoch;

TaskEvent event(String message, [int? seconds]) => TaskEvent(
  message: message,
  level: 'technical-log-level',
  timestampUnixMs: Int64(seconds == null ? 0 : _start + seconds * 1000),
);

TaskStatus status({
  String message = '',
  int? seconds,
  List<TaskEvent> events = const [],
}) => TaskStatus(
  id: 'task',
  message: message,
  updatedUnixMs: Int64(seconds == null ? 0 : _start + seconds * 1000),
  events: events,
);

Widget host(
  Widget child, {
  PageStorageBucket? bucket,
  double width = 420,
  double textScale = 1,
  bool disableAnimations = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: disableAnimations,
    ),
    child: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: PageStorage(
            bucket: bucket ?? PageStorageBucket(),
            child: child,
          ),
        ),
      ),
    ),
  ),
);

Widget messages(TaskStatus value, [String id = 'machine-task']) =>
    TaskMessages(key: PageStorageKey('task-messages-$id'), status: value);

Future<void> show(WidgetTester tester, TaskStatus value) async {
  await tester.pumpWidget(host(messages(value)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty messages have a placeholder without expansion', (
    tester,
  ) async {
    await show(tester, status(message: '  ', events: [event(' \n ')]));
    expect(find.text('等待执行信息'), findsOneWidget);
    expect(find.text('Sisters 回报'), findsOneWidget);
    expect(find.text('展开消息'), findsNothing);
    expect(find.text('technical-log-level'), findsNothing);
  });

  testWidgets(
    'a current message without events displays its short local time',
    (tester) async {
      await show(tester, status(message: ' 准备执行 ', seconds: 5));
      expect(find.text('准备执行'), findsOneWidget);
      expect(find.text('03:04:05'), findsOneWidget);
      expect(find.text('展开消息'), findsNothing);
      expect(find.text('等待执行信息'), findsNothing);
    },
  );

  testWidgets(
    'empty or older current text falls back to the newest dated event',
    (tester) async {
      final value = status(
        events: [event('最新回报', 30), event('先前回报', 10), event('无时间的旧记录')],
      );
      await show(tester, value);
      expect(find.text('最新回报'), findsOneWidget);
      expect(find.text('先前回报'), findsNothing);
      value.message = '稍早的状态快照';
      value.updatedUnixMs = Int64(_start + 20000);
      await show(tester, value);
      expect(find.text('最新回报'), findsOneWidget);
      expect(find.text('稍早的状态快照'), findsNothing);
      await tester.tap(find.text('展开消息'));
      await tester.pumpAndSettle();
      expect(find.text('先前回报'), findsOneWidget);
      expect(find.text('稍早的状态快照'), findsOneWidget);
      expect(find.text('无时间的旧记录'), findsNothing);
      expect(
        tester.getTopLeft(find.text('先前回报')).dy,
        lessThan(tester.getTopLeft(find.text('稍早的状态快照')).dy),
      );
    },
  );

  testWidgets(
    'live countdown replaces the matching stage event without duplicates',
    (tester) async {
      final value = status(
        message: '距开售还有 30 秒',
        seconds: 20,
        events: [event('准备完成', 10), event('等待开售', 20)],
      );
      await show(tester, value);
      expect(find.text('距开售还有 30 秒'), findsOneWidget);
      expect(find.text('等待开售'), findsNothing);
      await tester.tap(find.text('展开消息'));
      await tester.pumpAndSettle();
      expect(find.text('准备完成'), findsOneWidget);
      value.message = '距开售还有 25 秒';
      await show(tester, value);
      expect(find.text('距开售还有 25 秒'), findsOneWidget);
      expect(find.text('距开售还有 30 秒'), findsNothing);
      expect(find.text('等待开售'), findsNothing);
      expect(find.text('03:04:20'), findsOneWidget);
      expect(find.text('准备完成'), findsOneWidget);
    },
  );

  testWidgets('zero timestamps do not merge unrelated messages', (
    tester,
  ) async {
    await show(
      tester,
      status(message: '开始执行', events: [event('准备完成'), event('等待开售')]),
    );
    await tester.tap(find.text('展开消息'));
    await tester.pumpAndSettle();
    for (final text in ['准备完成', '等待开售', '开始执行']) {
      expect(find.text(text), findsOneWidget);
    }
    expect(find.textContaining('1970'), findsNothing);
    expect(find.textContaining('00:00:00'), findsNothing);
  });

  testWidgets(
    'adjacent repeated text is combined while distinct stages remain',
    (tester) async {
      await show(
        tester,
        status(
          message: '开始执行',
          seconds: 30,
          events: [event('准备完成', 5), event('准备完成', 10), event('开始执行', 20)],
        ),
      );
      await tester.tap(find.text('展开消息'));
      await tester.pumpAndSettle();
      expect(find.text('准备完成'), findsOneWidget);
      expect(find.text('开始执行'), findsOneWidget);
      expect(find.text('03:04:05'), findsNothing);
      expect(find.text('03:04:10'), findsOneWidget);
      expect(find.text('03:04:30'), findsOneWidget);
    },
  );

  testWidgets(
    'a stage that recurs after another stage remains a separate event',
    (tester) async {
      await show(
        tester,
        status(
          events: [event('准备执行', 10), event('等待重试', 20), event('准备执行', 30)],
        ),
      );
      await tester.tap(find.text('展开消息'));
      await tester.pumpAndSettle();
      expect(find.text('准备执行'), findsNWidgets(2));
      expect(find.text('等待重试'), findsOneWidget);
      expect(find.text('03:04:10'), findsOneWidget);
      expect(find.text('03:04:30'), findsOneWidget);
    },
  );

  testWidgets(
    'untimed current text can repeat an earlier stage as the latest',
    (tester) async {
      await show(
        tester,
        status(message: '准备执行', events: [event('准备执行', 10), event('等待重试', 20)]),
      );
      expect(find.text('准备执行'), findsOneWidget);
      expect(find.text('等待重试'), findsNothing);
      await tester.tap(find.text('展开消息'));
      await tester.pumpAndSettle();
      expect(find.text('准备执行'), findsNWidgets(2));
      expect(find.text('等待重试'), findsOneWidget);
    },
  );

  testWidgets(
    'expanded window keeps only the latest three messages and advances',
    (tester) async {
      final value = status(
        message: '回报 4',
        seconds: 4,
        events: [for (var i = 1; i <= 4; i++) event('回报 $i', i)],
      );
      await show(tester, value);
      expect(find.text('回报 4'), findsOneWidget);
      expect(find.text('回报 3'), findsNothing);
      await tester.tap(find.text('展开消息'));
      await tester.pumpAndSettle();
      expect(find.text('回报 1'), findsNothing);
      for (var i = 2; i <= 4; i++) {
        expect(find.text('回报 $i'), findsOneWidget);
      }
      value.events.add(event('回报 5', 5));
      value.message = '回报 5';
      value.updatedUnixMs = Int64(_start + 5000);
      await show(tester, value);
      expect(find.text('回报 2'), findsNothing);
      for (var i = 3; i <= 5; i++) {
        expect(find.text('回报 $i'), findsOneWidget);
      }
      expect(
        tester.getTopLeft(find.text('回报 3')).dy,
        lessThan(tester.getTopLeft(find.text('回报 4')).dy),
      );
      expect(
        tester.getTopLeft(find.text('回报 4')).dy,
        lessThan(tester.getTopLeft(find.text('回报 5')).dy),
      );
      await tester.tap(find.text('收起消息'));
      await tester.pumpAndSettle();
      expect(find.text('回报 3'), findsNothing);
      expect(find.text('回报 4'), findsNothing);
      expect(find.text('回报 5'), findsOneWidget);
    },
  );

  testWidgets('PageStorage restores expansion per machine and task', (
    tester,
  ) async {
    final bucket = PageStorageBucket();
    final value = status(events: [event('先前回报', 1), event('最新回报', 2)]);
    await tester.pumpWidget(host(messages(value, 'a-task'), bucket: bucket));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开消息'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(messages(value, 'b-task'), bucket: bucket));
    await tester.pumpAndSettle();
    expect(find.text('先前回报'), findsNothing);
    expect(find.text('展开消息'), findsOneWidget);
    await tester.pumpWidget(host(const SizedBox.shrink(), bucket: bucket));
    await tester.pumpWidget(host(messages(value, 'a-task'), bucket: bucket));
    await tester.pumpAndSettle();
    expect(find.text('先前回报'), findsOneWidget);
    expect(find.text('收起消息'), findsOneWidget);
    await tester.tap(find.text('收起消息'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(const SizedBox.shrink(), bucket: bucket));
    await tester.pumpWidget(host(messages(value, 'a-task'), bucket: bucket));
    await tester.pumpAndSettle();
    expect(find.text('先前回报'), findsNothing);
  });

  testWidgets('same text and timestamp-only refresh do not replay animations', (
    tester,
  ) async {
    final value = status(message: '正在执行', seconds: 1);
    await show(tester, value);
    final animation = tester.state(find.byType(Animate));
    await show(tester, value.deepCopy());
    expect(tester.state(find.byType(Animate)), same(animation));
    value.updatedUnixMs = Int64(_start + 2000);
    await tester.pumpWidget(host(messages(value)));
    await tester.pump();
    expect(tester.state(find.byType(Animate)), same(animation));
    expect(find.text('03:04:02'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    value.message = '执行已完成';
    await tester.pumpWidget(host(messages(value)));
    expect(tester.state(find.byType(Animate)), isNot(same(animation)));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion renders updates without animation', (
    tester,
  ) async {
    final value = status(message: '正在执行', seconds: 1);
    await tester.pumpWidget(host(messages(value), disableAnimations: true));
    await tester.pumpAndSettle();
    expect(find.byType(Animate), findsNothing);
    value.message = '执行已完成';
    await tester.pumpWidget(host(messages(value), disableAnimations: true));
    await tester.pumpAndSettle();
    expect(find.text('执行已完成'), findsOneWidget);
    expect(find.byType(Animate), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'large text wraps completely without nested scrolling or log levels',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const text = '这是一段较长的执行回报，用于确认窄卡片和大字体仍然完整显示消息。\n第二行继续说明当前状态，无需手动滚动消息。';
      await tester.pumpWidget(
        host(
          messages(status(message: text, seconds: 5)),
          width: 280,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      final rendered = tester.widget<Text>(find.text(text));
      expect(rendered.maxLines, isNull);
      expect(rendered.overflow, isNull);
      expect(tester.getRect(find.text(text)).height, greaterThan(100));
      expect(tester.getRect(find.text(text)).right, lessThanOrEqualTo(280));
      expect(
        find.byWidgetPredicate(
          (w) => w is ScrollView || w is Scrollable || w is SelectableText,
        ),
        findsNothing,
      );
      expect(find.text('technical-log-level'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
