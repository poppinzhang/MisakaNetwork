import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/android_order_monitor.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';

import '../test/fakes.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android delivers a confirmed order polled while the Activity is stopped',
    (tester) async {
      final store = MemoryStore()
        ..state = SavedState(
          successNotificationsEnabled: true,
          machines: [machine('local-fixture')],
          accounts: [Account(id: 'account', name: '模拟账号', uid: '12345')],
          tasks: [
            TicketTask(
              id: 'execution',
              name: '模拟任务',
              accountId: 'account',
              dispatchedTo: ['local-fixture'],
            ),
          ],
        );
      var backgroundPolls = 0;
      final promoted = Completer<void>(), stopped = Completer<void>();
      final gateway = FakeGateway()
        ..statusHandler = (_) async {
          if (promoted.isCompleted &&
              binding.lifecycleState == AppLifecycleState.paused) {
            backgroundPolls++;
          }
          final created = backgroundPolls >= 2;
          return AgentStatus(
            tasks: [
              TaskStatus(
                id: 'execution',
                state: created
                    ? TaskState.TASK_STATE_SUCCEEDED
                    : TaskState.TASK_STATE_RUNNING,
                orderCreated: created,
                payment: created ? OrderPayment(orderId: '987654321') : null,
              ),
            ],
          );
        };
      final c = AppController(
        store: store,
        gateway: gateway,
        runtime: FakeRuntime(),
        helper: FakeHelper(),
        cloudTemplateLoader: () async => [],
        setAndroidBackgroundMonitoring: (enabled) async {
          final active = await setNativeAndroidBackgroundMonitoring(enabled);
          if (enabled && active && !promoted.isCompleted) promoted.complete();
          if (!enabled &&
              !active &&
              promoted.isCompleted &&
              !stopped.isCompleted) {
            stopped.complete();
          }
          return active;
        },
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      final sent = Completer<AppLifecycleState?>();
      void checkDelivery() {
        if (!sent.isCompleted &&
            !c.polling &&
            store.state.observedOrderNotifications.isNotEmpty) {
          sent.complete(binding.lifecycleState);
        }
      }

      c.addListener(checkDelivery);
      await c.initialize();
      await promoted.future.timeout(const Duration(seconds: 20));
      // On a dedicated Android emulator with notifications pre-granted, wait
      // for the ongoing monitor entry, press Home, and return after checking
      // the success notification in the system notification drawer.
      final deliveredAt = await sent.future.timeout(const Duration(minutes: 2));
      await stopped.future.timeout(const Duration(seconds: 15));
      expect(deliveredAt, AppLifecycleState.paused);
      expect(c.notificationDeliveryError, isNull);
      expect(backgroundPolls, greaterThanOrEqualTo(2));
      expect(store.state.observedOrderNotifications, hasLength(1));
    },
    skip:
        !Platform.isAndroid ||
        !const bool.fromEnvironment('MISAKA_TEST_BACKGROUND_MONITOR'),
  );
}
