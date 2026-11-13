import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'controller.dart';
import 'payments.dart';
import 'services.dart';

typedef OrderPageOpener = Future<bool> Function(Uri uri);

Future<bool> _openOrderPage(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

List<DisplayOrderPayment> _orders(AppController controller) =>
    collectOrderPayments(
      controller.state,
      controller.statuses,
      disconnected: controller.connectionErrors.keys.toSet(),
    );

String _captureTime(DisplayOrderPayment order) => order.capturedAt == null
    ? '获取时间未知'
    : '获取于 ${order.capturedAt!.toLocal().toString().split('.').first}';

/// A single payment entry per account UID and order ID. Node execution cards
/// stay separate so stopping one node never appears to stop every node.
class OrderPayments extends StatelessWidget {
  const OrderPayments({super.key, required this.controller, this.openOrder});
  final AppController controller;
  final OrderPageOpener? openOrder;

  @override
  Widget build(BuildContext context) {
    final orders = _orders(controller);
    if (orders.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('订单与付款', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('以下为已获取的订单信息。是否需要付款、是否已出票，请以平台订单详情为准。'),
        const SizedBox(height: 12),
        for (final order in orders)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card.outlined(
              key: ValueKey('payment-order-${order.key}'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${order.account.name} · 订单 ${order.orderId}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text('账号 UID：${order.account.uid}'),
                    for (final source in order.sources)
                      Text(
                        '${source.machine.name} · ${source.task.name}'
                        '${_session(source).isEmpty ? '' : ' · ${_session(source)}'}',
                      ),
                    const SizedBox(height: 8),
                    Text(_captureTime(order)),
                    if (order.disconnected)
                      const Text('部分来源节点连接异常，当前展示的是上次获取的信息。'),
                    if (!order.hasPaymentCode)
                      const Text('未获取到可显示的付款码。请打开订单详情核对是否需要付款。'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (order.hasPaymentCode)
                          FilledButton.tonalIcon(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => _PaymentDialog(
                                controller: controller,
                                orderKey: order.key,
                                openOrder: openOrder,
                              ),
                            ),
                            icon: const Icon(LucideIcons.qrCode, size: 18),
                            label: const Text('查看付款二维码'),
                          ),
                        _OrderLinkButton(order: order, openOrder: openOrder),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _session(PaymentSource source) {
    final summary = source.task.summary;
    if (summary == null) return '';
    return [
      summary.projectName,
      summary.selectedDate,
      summary.screenName,
      summary.ticketName,
    ].where((value) => value.isNotEmpty).join(' · ');
  }
}

class _OrderLinkButton extends StatelessWidget {
  const _OrderLinkButton({required this.order, this.openOrder});
  final DisplayOrderPayment order;
  final OrderPageOpener? openOrder;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () async {
      try {
        // Reconstructed from a validated ID; never launch the payment payload
        // or a node-supplied order URL, and never attach cookies to a browser.
        if (await (openOrder ?? _openOrderPage)(order.detailUri)) return;
      } catch (_) {
        // Exceptions may contain the input URL. Only fixed text is displayed.
      }
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('无法打开订单详情'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('请在哔哩哔哩登录同一账号后查看会员购订单，也可手动打开以下订单地址。'),
              const SizedBox(height: 12),
              SelectableText(order.detailUri.toString()),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    },
    icon: const Icon(LucideIcons.externalLink, size: 18),
    label: const Text('打开订单详情'),
  );
}

class _PaymentDialog extends StatelessWidget {
  const _PaymentDialog({
    required this.controller,
    required this.orderKey,
    this.openOrder,
  });
  final AppController controller;
  final String orderKey;
  final OrderPageOpener? openOrder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final order = _orders(controller)
          .where((order) => order.key == orderKey)
          .firstOrNull;
      return AlertDialog(
        scrollable: true,
        title: const Text('付款二维码'),
        content: SizedBox(
          width: 380,
          child: order == null
              ? const Text('此订单的本地关联或节点记录已移除，请到平台订单中心核对。')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${order.account.name} · UID ${order.account.uid}'),
                    Text('订单 ${order.orderId}'),
                    const SizedBox(height: 16),
                    if (order.hasPaymentCode)
                      _PaymentQr(
                        runtime: controller.runtime,
                        code: order.paymentCode,
                      )
                    else
                      const Text('未获取到可显示的付款码，请打开订单详情。'),
                    const SizedBox(height: 16),
                    Text(_captureTime(order)),
                    if (order.disconnected) const Text('来源节点连接异常，当前信息可能已过期。'),
                    const Text('请使用对应支付 App 扫码，并核对订单与金额后确认付款。'),
                    const SizedBox(height: 8),
                    const Text(
                      '此付款码不会自动刷新，也不查询付款状态。若二维码不可用、已付款或使用同一部手机，请打开订单详情核对；浏览器可能需要登录同一账号。',
                    ),
                  ],
                ),
        ),
        actions: [
          if (order != null)
            _OrderLinkButton(order: order, openOrder: openOrder),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

class _PaymentQr extends StatefulWidget {
  const _PaymentQr({required this.runtime, required this.code});
  final RuntimeBridge runtime;
  final String code;
  @override
  State<_PaymentQr> createState() => _PaymentQrState();
}

class _PaymentQrState extends State<_PaymentQr> {
  Uint8List? bytes;
  bool failed = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void didUpdateWidget(_PaymentQr oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code || oldWidget.runtime != widget.runtime) {
      bytes = null;
      failed = false;
      _generate();
    }
  }

  Future<void> _generate() async {
    final current = ++generation;
    try {
      if (!isValidPaymentCode(widget.code)) throw const FormatException();
      final result = await widget.runtime.call('payment_qr', {
        'payment_code_url': widget.code,
      });
      final encoded = result['qr_png_base64'];
      if (encoded is! String || encoded.length > 700000) {
        throw const FormatException();
      }
      final decoded = base64Decode(encoded);
      const signature = [137, 80, 78, 71, 13, 10, 26, 10];
      if (decoded.length < signature.length ||
          decoded.length > 512 * 1024 ||
          !List.generate(
            8,
            (i) => decoded[i] == signature[i],
          ).every((v) => v)) {
        throw const FormatException();
      }
      if (mounted && current == generation) setState(() => bytes = decoded);
    } catch (_) {
      if (mounted && current == generation) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    const error = Text('付款码暂时无法显示，请打开订单详情继续核对与付款。');
    if (failed) return error;
    if (bytes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: SizedBox(
        width: 320,
        child: AspectRatio(
          aspectRatio: 1,
          child: Image.memory(
            bytes!,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.none,
            semanticLabel: '付款二维码，请使用对应支付 App 扫码',
            frameBuilder: (_, child, frame, _) =>
                frame == null ? const Center(child: Text('正在显示付款码…')) : child,
            errorBuilder: (_, _, _) => error,
          ),
        ),
      ),
    );
  }
}
