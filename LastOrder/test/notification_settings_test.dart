import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

void main() {
  testWidgets(
    'Android keeps monitoring on Home and rechecks it when visible again',
    (tester) async {
      final binding = tester.binding;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final requests = <bool>[];
      final store = MemoryStore()
        ..state = SavedState(
          successNotificationsEnabled: true,
          machines: [machine('a')],
          accounts: [Account(id: 'local', name: '测试账号', uid: '12345')],
          tasks: [
            TicketTask(
              id: 't',
              name: '演出',
              accountId: 'local',
              dispatchedTo: ['a'],
            ),
          ],
        );
      final c = AppController(
        store: store,
        gateway: FakeGateway(),
        runtime: FakeRuntime(),
        helper: FakeHelper(),
        cloudTemplateLoader: () async => [],
        setAndroidBackgroundMonitoring: (active) async {
          requests.add(active);
          return active;
        },
      );
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();
      expect(requests, [true]);
      await tester.tap(find.byTooltip('配置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('通知栏会静默显示监控状态'), findsOneWidget);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(requests, [true]);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(requests, [true, true]);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(requests, [true, true, false]);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'permission denial stays in settings and approval can be retried',
    (tester) async {
      const channel = MethodChannel('misaka/notifications');
      final messenger = tester.binding.defaultBinaryMessenger;
      bool allowed = false;
      int requests = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'requestPermission');
        requests++;
        return allowed;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final store = MemoryStore();
      final c = controller(store: store);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('配置'));
      await tester.pumpAndSettle();
      final toggle = find.byType(SwitchListTile);
      bool enabled() => tester.widget<SwitchListTile>(toggle).value;
      expect(enabled(), isFalse);
      expect(requests, 0);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(enabled(), isFalse);
      expect(requests, 1);
      expect(find.textContaining('请在系统通知设置中允许'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      allowed = true;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(enabled(), isTrue);
      expect(store.state.successNotificationsEnabled, isTrue);
      expect(requests, 2);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('配置'));
      await tester.pumpAndSettle();
      expect(enabled(), isTrue);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(enabled(), isFalse);
      expect(store.state.successNotificationsEnabled, isFalse);
      expect(requests, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
