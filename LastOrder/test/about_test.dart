import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:last_order/src/about_dialog.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/app_info.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

void main() {
  for (final size in [
    const Size(1360, 1000),
    const Size(800, 640),
    const Size(850, 390),
    const Size(320, 640),
    const Size(390, 850),
  ]) {
    testWidgets('about opens and closes from the dashboard at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = controller();
      await c.initialize(poll: false);
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();

      final button = find.byKey(const ValueKey('about-button'));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getCenter(button).dx, lessThan(size.width / 2));
      expect(tester.getCenter(button).dy, greaterThan(size.height / 2));
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(find.byType(ProjectAboutDialog), findsOneWidget);
      expect(find.text('关于 LastOrder'), findsOneWidget);
      expect(find.text('MisakaNetwork'), findsOneWidget);
      expect(find.text('版本 $appVersion · 构建 $appBuildNumber'), findsOneWidget);
      expect(find.textContaining('biliTickerBuy'), findsOneWidget);
      expect(find.text('20001 · 一个有来处的端口'), findsOneWidget);
      expect(
        find.textContaining('Last Order（最后之作）是第 20001 号。'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('关闭').hitTestable(), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(find.byType(ProjectAboutDialog), findsNothing);
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'about stays scrollable and closable on a phone with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const ProjectAboutDialog(),
                  ),
                  child: const Text('打开关于'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开关于'));
      await tester.pumpAndSettle();

      expect(find.byType(ProjectAboutDialog), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.text('关闭').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.textContaining('Last Order（最后之作）是第 20001 号。'),
      );
      await tester.pumpAndSettle();
      expect(find.text('关闭').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectAboutDialog), findsNothing);
    },
  );

  for (final existingPort in <int?>[null, 24443]) {
    testWidgets(
      existingPort == null
          ? 'new machine dialog defaults to port 20001'
          : 'existing machine dialog preserves its custom port',
      (tester) async {
        final c = controller();
        await c.initialize(poll: false);
        addTearDown(c.dispose);
        final existing = existingPort == null
            ? null
            : Machine(
                id: 'custom-port',
                name: '自定义端口节点',
                host: 'node.example',
                port: existingPort,
                caCert: 'ca.pem',
                clientCert: 'client.pem',
                clientKey: 'client.key',
              );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MachineDialog(controller: c, existing: existing),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final field = tester.widget<TextField>(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.labelText == 'gRPC 端口',
          ),
        );
        expect(field.controller!.text, '${existingPort ?? 20001}');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
