import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

Finder input(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  testWidgets(
    'phone task form saves interval with large text and keyboard visible',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      // Sisters accepts at most 200 Unicode code points and no control characters.
      final projectName = '  特别演出\n\t${'🎫' * 201}  ';
      final taskName = '特别演出 ${'🎫' * 195}';
      final runtime = FakeRuntime()
        ..responses['purchase_context'] = {
          'project_name': projectName,
          'ticket_options': [
            {
              'display': '测试场次 / 票档',
              'screen': '晚场',
              'desc': '普通票',
              'sale_start': '2026-11-20 19:15:46',
            },
          ],
          'buyers': [
            {'name': '测试购票人', 'id_type': 0},
          ],
          'addresses': [
            {'name': '测试地址', 'city': '测试城市'},
          ],
        }
        ..responses['build_config'] = {
          'ticket': {'id': 1},
        };
      final store = MemoryStore();
      final c = controller(runtime: runtime, store: store);
      await c.initialize(poll: false);
      await c.addAccount('测试账号', [
        {'name': 'session', 'value': 'synthetic'},
      ], uid: '123');
      addTearDown(c.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => TaskDialog(controller: c),
                ),
                child: const Text('新任务'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('新任务'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.ensureVisible(input('演出 ID 或会员购链接'));
      await tester.enterText(input('演出 ID 或会员购链接'), '1234');
      await tester.tap(find.text('读取演出与购票人'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        runtime.parameters[runtime.calls.indexOf('purchase_context')]
            .containsKey('selected_date'),
        isFalse,
      );
      expect(find.text('场次日期'), findsNothing);
      expect(find.text(taskName), findsOneWidget);
      expect(find.text('2026-11-20 19:15:46'), findsOneWidget);
      final chooseStart = find.byTooltip('选择开售时间');
      await tester.ensureVisible(chooseStart);
      await tester.tap(chooseStart);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final otherDay = find.descendant(
        of: find.byType(CalendarDatePicker),
        matching: find.text('21'),
      );
      await tester.ensureVisible(otherDay);
      await tester.tap(otherDay);
      await tester.pumpAndSettle();
      expect(find.text('确定').hitTestable(), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('2026-11-20 19:15:46'), findsOneWidget);
      final clearStart = find.byTooltip('清除开售时间');
      await tester.ensureVisible(clearStart);
      await tester.tap(clearStart);
      await tester.pumpAndSettle();
      expect(find.text('分发后立即开始'), findsOneWidget);

      await tester.ensureVisible(find.text('测试购票人（身份证）'));
      await tester.tap(find.text('测试购票人（身份证）'));
      await tester.ensureVisible(input('联系人（必填）'));
      await tester.enterText(input('联系人（必填）'), '测试联系人');
      await tester.ensureVisible(input('联系电话（必填）'));
      await tester.enterText(input('联系电话（必填）'), '13800000000');

      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      final interval = input('抢票请求间隔（毫秒）');
      await tester.ensureVisible(interval);
      await tester.pumpAndSettle();
      expect(interval.hitTestable(), findsOneWidget);
      await tester.tap(interval);
      await tester.enterText(interval, '60000');
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.widget<TextField>(interval).controller!.text, '60000');
      expect(tester.takeException(), isNull);

      final attemptsHint = find.textContaining('每轮下单最多尝试 40 次');
      await tester.ensureVisible(attemptsHint);
      await tester.pumpAndSettle();
      expect(attemptsHint.hitTestable(), findsOneWidget);
      expect(tester.widget(attemptsHint), isA<Text>());
      expect(
        find.ancestor(of: attemptsHint, matching: find.byType(EditableText)),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              (widget.decoration?.labelText?.contains('尝试') ?? false),
        ),
        findsNothing,
      );
      expect(find.text('保存任务').hitTestable(), findsOneWidget);
      await tester.tap(find.text('保存任务'));
      await tester.pumpAndSettle();

      expect(find.byType(TaskDialog), findsNothing);
      expect(c.state.tasks.single.requestIntervalMs, 60000);
      expect(store.state.tasks.single.requestIntervalMs, 60000);
      expect(store.state.tasks.single.name, taskName);
      expect(store.state.tasks.single.startAt, isEmpty);
      expect(
        runtime.calls,
        containsAllInOrder(['purchase_context', 'build_config', 'validate']),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}
