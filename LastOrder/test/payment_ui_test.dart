import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/payment_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';
import 'payments_test.dart'
    show paymentState, paymentStatus, wechatCode, alipayCode;

// A synthetic one-pixel PNG tests the display transport, not QR scan validity.
const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC';

Future<
  ({
    AppController controller,
    FakeRuntime runtime,
    FakeGateway gateway,
    MemoryStore store,
  })
>
mountPayments(
  WidgetTester tester, {
  String code = wechatCode,
  bool fullApp = false,
  double width = 1000,
  OrderPageOpener? openOrder,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = MemoryStore()..state = paymentState();
  final runtime = FakeRuntime()
    ..responses['payment_qr'] = {'qr_png_base64': png};
  final gateway = FakeGateway()
    ..statusHandler = (_) async =>
        AgentStatus(tasks: [paymentStatus(code: code)]);
  final controller = AppController(
    store: store,
    gateway: gateway,
    runtime: runtime,
    helper: FakeHelper(),
  );
  addTearDown(controller.dispose);
  await controller.initialize(poll: false);
  await controller.refresh();
  await tester.pumpWidget(
    fullApp
        ? LastOrderApp(controller: controller)
        : MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (_, _) => OrderPayments(
                    controller: controller,
                    openOrder: openOrder,
                  ),
                ),
              ),
            ),
          ),
  );
  await tester.pumpAndSettle();
  if (fullApp) {
    await tester.tap(find.byTooltip('任务监控'));
    await tester.pumpAndSettle();
  }
  return (
    controller: controller,
    runtime: runtime,
    gateway: gateway,
    store: store,
  );
}

void main() {
  testWidgets(
    'monitor merges nodes into one order and QR is opened only on demand',
    (tester) async {
      final env = await mountPayments(tester, fullApp: true);
      expect(
        find.byKey(const ValueKey('payment-order-10001:12345')),
        findsOneWidget,
      );
      expect(find.text('查看付款二维码'), findsOneWidget);
      expect(find.text('付款二维码'), findsNothing);
      expect(env.runtime.calls, isEmpty);
      await env.controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('查看付款二维码'), findsOneWidget);
      await tester.tap(find.text('查看付款二维码'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(env.runtime.calls, ['payment_qr']);
      expect(env.runtime.parameters.single, {'payment_code_url': wechatCode});
      expect(find.textContaining(wechatCode), findsNothing);
      await env.controller.refresh();
      await tester.pumpAndSettle();
      expect(env.runtime.calls, ['payment_qr']);
      expect(find.text('付款二维码'), findsOneWidget);
      expect(env.store.secrets, isEmpty);
      expect(env.store.state.encode(), isNot(contains(wechatCode)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid and absent codes retain a canonical order page', (
    tester,
  ) async {
    final opened = <Uri>[];
    final env = await mountPayments(
      tester,
      code: 'javascript:secret',
      openOrder: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    expect(find.text('查看付款二维码'), findsNothing);
    expect(find.textContaining('未获取到可显示的付款码'), findsOneWidget);
    await tester.tap(find.text('打开订单详情'));
    await tester.pumpAndSettle();
    expect(
      opened.single.toString(),
      'https://show.bilibili.com/platform/orderDetail.html?order_id=12345',
    );
    expect(env.runtime.calls, isEmpty);
    expect(find.textContaining('secret'), findsNothing);
  });

  testWidgets('QR generation error is redacted and leaves the order fallback', (
    tester,
  ) async {
    final env = await mountPayments(tester);
    env.runtime.handler = (_, _) async =>
        throw const UserError('secret payment token');
    await tester.tap(find.text('查看付款二维码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('付款码暂时无法显示'), findsOneWidget);
    expect(find.textContaining('secret payment token'), findsNothing);
    expect(find.text('打开订单详情'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('malformed QR responses preserve the order fallback', (
    tester,
  ) async {
    final env = await mountPayments(tester);
    for (final response in <Map<String, dynamic>>[
      {},
      {'qr_png_base64': 'synthetic-invalid-secret'},
      {'qr_png_base64': 'c3ludGhldGljLW5vdC1wbmc='},
      {'qr_png_base64': 'a' * 700001},
    ]) {
      env.runtime.responses['payment_qr'] = response;
      await tester.tap(find.text('查看付款二维码'));
      await tester.pumpAndSettle();
      expect(find.textContaining('付款码暂时无法显示'), findsOneWidget);
      expect(find.textContaining('synthetic-invalid-secret'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(find.text('打开订单详情'), findsNWidgets(2));
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'browser failure provides manual details without exposing exception',
    (tester) async {
      await mountPayments(
        tester,
        code: '',
        openOrder: (_) async => throw Exception('secret'),
      );
      await tester.tap(find.text('打开订单详情'));
      await tester.pumpAndSettle();
      expect(find.text('无法打开订单详情'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow large-text layout and disconnected results keep actions usable',
    (tester) async {
      final env = await mountPayments(tester, width: 390);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      env.gateway.statusHandler = (_) async => throw const UserError('连接失败');
      await env.controller.refresh();
      await tester.pumpAndSettle();
      expect(find.textContaining('部分来源节点连接异常'), findsOneWidget);
      await tester.ensureVisible(find.text('查看付款二维码'));
      await tester.tap(find.text('查看付款二维码'));
      await tester.pumpAndSettle();
      expect(find.textContaining('来源节点连接异常，当前信息可能已过期'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      final size = tester.getSize(find.byType(Image));
      expect(size.width, greaterThan(200));
      expect(size.width, lessThanOrEqualTo(320));
      expect(size.height, closeTo(size.width, 0.1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late QR result cannot replace a newer payload or removed order',
    (tester) async {
      final env = await mountPayments(tester);
      final oldResult = Completer<Map<String, dynamic>>();
      env.runtime.handler = (_, params) =>
          params['payment_code_url'] == wechatCode
          ? oldResult.future
          : Future.value({'qr_png_base64': png});
      await tester.tap(find.text('查看付款二维码'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      env.gateway.statusHandler = (_) async =>
          AgentStatus(tasks: [paymentStatus(code: alipayCode, captured: 2000)]);
      await env.controller.refresh();
      await tester.pumpAndSettle();
      expect(env.runtime.calls, ['payment_qr', 'payment_qr']);
      oldResult.completeError(const UserError('old secret'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('暂时无法显示'), findsNothing);
      env.gateway.statusHandler = (_) async => AgentStatus();
      await env.controller.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('本地关联或节点记录已移除'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
