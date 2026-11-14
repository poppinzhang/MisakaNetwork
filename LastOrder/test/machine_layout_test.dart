import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

Finder machineCard(String id) => find.byKey(ValueKey('machine-card-$id'));

Future<AppController> openMachines(
  WidgetTester tester, {
  required double width,
  double textScale = 1,
  List<Machine>? machines,
  void Function(AppController)? prepare,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final c = controller(
    store: MemoryStore()
      ..state = SavedState(
        machines:
            machines ??
            [
              for (final id in ['a', 'b', 'c']) machine(id),
            ],
      ),
  );
  await c.initialize(poll: false);
  addTearDown(c.dispose);
  prepare?.call(c);
  await tester.pumpWidget(LastOrderApp(controller: c));
  await tester.pumpAndSettle();
  await tester.tap(
    width >= 600 ? find.byTooltip('机器管理') : find.text('机器管理').first,
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  for (final width in [1024.0, 1360.0]) {
    testWidgets('machines fill two columns at desktop width $width', (
      tester,
    ) async {
      await openMachines(tester, width: width);
      final a = tester.getRect(machineCard('a'));
      final b = tester.getRect(machineCard('b'));
      final c = tester.getRect(machineCard('c'));

      expect(a.top, b.top);
      expect(a.bottom, b.bottom);
      expect(b.left - a.right, closeTo(16, 0.01));
      expect(a.width, closeTo(b.width, 0.01));
      expect(c.left, a.left);
      expect(c.width, closeTo(a.width, 0.01));
      expect(c.top - a.bottom, closeTo(16, 0.01));
      expect(b.right, closeTo(width - 32, 0.01));
      expect(tester.getRect(find.text('SISTERS')).top, closeTo(110, 0.01));
      final addButton = find.ancestor(
        of: find.text('添加机器'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      );
      expect(tester.getRect(addButton).right, closeTo(b.right, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [390.0, 800.0]) {
    testWidgets('machines use full-width single cards at width $width', (
      tester,
    ) async {
      await openMachines(tester, width: width);
      final a = tester.getRect(machineCard('a'));
      final b = tester.getRect(machineCard('b'));
      final c = tester.getRect(machineCard('c'));

      expect(a.left, b.left);
      expect(b.left, c.left);
      expect(a.width, b.width);
      expect(b.width, c.width);
      expect(b.top - a.bottom, closeTo(16, 0.01));
      expect(c.top - b.bottom, closeTo(16, 0.01));
      expect(a.right, closeTo(width - 16, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text returns the desktop machine list to one column', (
    tester,
  ) async {
    await openMachines(tester, width: 900);
    expect(
      tester.getRect(machineCard('a')).top,
      tester.getRect(machineCard('b')).top,
    );
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    await tester.pumpAndSettle();
    final a = tester.getRect(machineCard('a'));
    final b = tester.getRect(machineCard('b'));
    expect(a.left, b.left);
    expect(a.width, b.width);
    expect(b.top, greaterThan(a.bottom));
    expect(a.right, closeTo(884, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long details grow a whole row without hiding machine actions', (
    tester,
  ) async {
    const longName = '用于大型演出场次的备用执行节点与长名称显示验证';
    const longHost = 'long-machine-address-for-layout-check.sisters.example';
    const error = '暂时无法连接执行节点，请检查机器的网络连接、防火墙设置和服务运行状态，然后重新同步。';
    await openMachines(
      tester,
      width: 1024,
      machines: [
        machine('a'),
        Machine(
          id: 'b',
          name: longName,
          host: longHost,
          caCert: 'ca',
          clientCert: 'cert',
          clientKey: 'key',
        ),
        machine('c'),
      ],
      prepare: (c) {
        c.statuses['a'] = AgentStatus(
          platform: 'linux/arm64',
          version: '0.3.2',
          biliVersion: '2.15.18',
          runtimeReady: true,
          maxConcurrency: 2,
        );
        c.statuses['b'] = AgentStatus(
          platform: 'darwin/arm64',
          version: '0.3.2',
          biliVersion: '2.15.18',
          runtimeReady: false,
          maxConcurrency: 2,
        );
        c.connectionErrors['b'] = error;
      },
    );

    final a = tester.getRect(machineCard('a'));
    final b = tester.getRect(machineCard('b'));
    final c = tester.getRect(machineCard('c'));
    expect(a.top, b.top);
    expect(a.bottom, b.bottom);
    expect(c.top - b.bottom, closeTo(16, 0.01));
    for (final label in ['重新部署', '移除连接']) {
      Rect actionRect(String id) => tester.getRect(
        find.ancestor(
          of: find.descendant(of: machineCard(id), matching: find.text(label)),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      expect(actionRect('a').bottom, closeTo(actionRect('b').bottom, 0.01));
    }
    for (final finder in [
      find.text(longName),
      find.text('$longHost:20001'),
      find.text(error),
      find.text('运行时尚未就绪，请重新部署完整安装包。'),
      find.descendant(of: machineCard('b'), matching: find.text('重新部署')),
      find.descendant(of: machineCard('b'), matching: find.text('移除连接')),
    ]) {
      expect(finder, findsOneWidget);
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(b.left));
      expect(rect.right, lessThanOrEqualTo(b.right));
      expect(rect.top, greaterThanOrEqualTo(b.top));
      expect(rect.bottom, lessThanOrEqualTo(b.bottom));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('right-column actions operate on the selected machine', (
    tester,
  ) async {
    final c = await openMachines(tester, width: 1360);
    await tester.tap(
      find.descendant(of: machineCard('b'), matching: find.text('重新部署')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<MachineDialog>(find.byType(MachineDialog)).existing?.id,
      'b',
    );
    expect(
      tester
          .widget<TextField>(
            find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == '机器名称',
            ),
          )
          .controller
          ?.text,
      '节点 b',
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    final remove = find.descendant(
      of: machineCard('b'),
      matching: find.text('移除连接'),
    );
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.text('仅移除本地连接。远程 Sisters 与已启动任务会继续运行。'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(c.state.machines.map((m) => m.id), ['a', 'b', 'c']);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(c.state.machines.map((m) => m.id), ['a', 'c']);
    expect(machineCard('b'), findsNothing);
    expect(
      tester.getRect(machineCard('a')).top,
      tester.getRect(machineCard('c')).top,
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
  });
}
