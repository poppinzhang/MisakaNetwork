import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:material_ui/material_ui.dart';

import 'task_edit_ui_test.dart'
    show editButton, inEditor, input, openTasks, tapVisible;

Finder onCard(String id, Finder child) =>
    find.descendant(of: find.byKey(ValueKey('task-card-$id')), matching: child);

Finder copyButton(String id) => onCard(id, find.byTooltip('复制任务'));

void main() {
  testWidgets(
    'a dispatched task can be copied and its copy edited independently',
    (tester) async {
      final f = await openTasks(tester);
      final source = f.c.state.tasks.firstWhere(
        (task) => task.id == 'sent-false',
      );
      f.store.secrets[source.configKey] = f.store.secrets['task.draft']!;
      final originalIds = f.c.state.tasks.map((task) => task.id).toSet();
      expect(editButton(source.id), findsNothing);
      await tapVisible(tester, copyButton(source.id));

      final copy = f.c.state.tasks.singleWhere(
        (task) => !originalIds.contains(task.id),
      );
      final savedOrder = f.c.state.tasks.map((task) => task.id).toList();
      expect(savedOrder.indexOf(copy.id), savedOrder.indexOf(source.id) + 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(onCard(copy.id, find.text(source.name)), findsOneWidget);
      expect(onCard(copy.id, find.text('未分发')), findsOneWidget);
      expect(onCard(source.id, find.text('进行中 1 台')), findsOneWidget);
      expect(editButton(source.id), findsNothing);
      expect(f.gateway.submitted, isEmpty);
      expect(f.runtime.lookups, isEmpty);

      await tapVisible(tester, editButton(copy.id));
      expect(inEditor(find.text('晚场普通票')), findsOneWidget);
      await tester.enterText(input('抢票请求间隔（毫秒）'), '825');
      await tapVisible(tester, inEditor(find.text('保存修改')));
      expect(find.byType(TaskDialog), findsNothing);
      final savedCopy = f.store.state.tasks.firstWhere(
        (task) => task.id == copy.id,
      );
      final savedSource = f.store.state.tasks.firstWhere(
        (task) => task.id == source.id,
      );
      expect(savedCopy.requestIntervalMs, 825);
      expect(savedCopy.dispatches, isEmpty);
      expect(savedSource.toJson(), source.toJson());
      expect(f.gateway.submitted, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an undispatched task can be copied from a narrow task card', (
    tester,
  ) async {
    final f = await openTasks(tester);
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    final source = f.c.state.tasks.firstWhere((task) => task.id == 'draft');
    await tapVisible(tester, copyButton(source.id));
    final copy = f.store.state.tasks.singleWhere(
      (task) => task.name == source.name && task.id != source.id,
    );
    expect(onCard(copy.id, find.text('未分发')), findsOneWidget);
    expect(editButton(source.id), findsOneWidget);
    expect(editButton(copy.id), findsOneWidget);
    expect(copy.startAt, source.startAt);
    expect(copy.summary?.toJson(), source.summary?.toJson());
    expect(f.gateway.submitted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a copy save failure leaves the task list intact and can be retried',
    (tester) async {
      final f = await openTasks(tester);
      final originalIds = f.c.state.tasks.map((task) => task.id).toList();
      f.store.failSave = true;
      await tapVisible(tester, copyButton('draft'));
      expect(find.textContaining('写入失败'), findsOneWidget);
      expect(f.c.state.tasks.map((task) => task.id), originalIds);
      expect(f.store.state.tasks.map((task) => task.id), originalIds);
      expect(f.gateway.submitted, isEmpty);

      f.store.failSave = false;
      await tapVisible(tester, copyButton('draft'));
      final copy = f.store.state.tasks.singleWhere(
        (task) => !originalIds.contains(task.id),
      );
      expect(editButton(copy.id), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
