import '../generated/misaka/v1/sisters.pb.dart';
import 'models.dart';

// Keep these exact formats aligned with runtime/bridge.py and Sisters. Payment
// payloads are QR data, never arbitrary URLs to launch, fetch, log or persist.
final _orderId = RegExp(r'[1-9][0-9]{0,79}');
final _paymentCode = RegExp(
  r'(?:weixin://wxpay/bizpayurl\?pr=[A-Za-z0-9_-]{1,512}|https://qr\.alipay\.com/[A-Za-z0-9_-]{1,512})',
);

bool _fullMatch(RegExp pattern, String value) {
  final match = pattern.matchAsPrefix(value);
  return match != null && match.end == value.length;
}

bool isValidOrderId(String value) => _fullMatch(_orderId, value);
bool isValidPaymentCode(String value) =>
    value.length <= 2048 && _fullMatch(_paymentCode, value);

/// Never trust the URL a node supplies, including a valid host with a different
/// order ID or a redirect query. Only this fixed order page may be opened.
Uri orderDetailUri(String orderId) {
  if (!isValidOrderId(orderId)) {
    throw const FormatException('订单号无效');
  }
  return Uri.https('show.bilibili.com', '/platform/orderDetail.html', {
    'order_id': orderId,
  });
}

class PaymentSource {
  const PaymentSource(this.machine, this.task, {required this.disconnected});
  final Machine machine;
  final TicketTask task;
  final bool disconnected;
  String get key => '${machine.id}:${task.id}';
}

class DisplayOrderPayment {
  DisplayOrderPayment({
    required this.account,
    required this.orderId,
    required this.paymentCode,
    required this.capturedAt,
    required this.sources,
  });
  final Account account;
  final String orderId, paymentCode;
  final DateTime? capturedAt;
  final List<PaymentSource> sources;
  String get key => '${account.uid}:$orderId';
  Uri get detailUri => orderDetailUri(orderId);
  bool get hasPaymentCode => paymentCode.isNotEmpty;
  bool get disconnected => sources.any((source) => source.disconnected);
}

class _OrderCandidate {
  const _OrderCandidate(this.account, this.payment, this.source);
  final Account account;
  final OrderPayment payment;
  final PaymentSource source;
  String get code =>
      isValidPaymentCode(payment.paymentCodeUrl) ? payment.paymentCodeUrl : '';
  DateTime? get capturedAt {
    final ms = payment.capturedUnixMs.toInt();
    // DateTime supports only a bounded range. Invalid remote timestamps do not
    // make the order disappear or turn into a fabricated expiration countdown.
    return ms > 0 && ms <= 253402300799999
        ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
        : null;
  }
}

/// An in-memory projection of confirmed node results, associated with known
/// local accounts and tasks. No payment token is added to SavedState.
List<DisplayOrderPayment> collectOrderPayments(
  SavedState state,
  Map<String, AgentStatus> statuses, {
  Set<String> disconnected = const {},
}) {
  final tasks = {for (final task in state.tasks) task.id: task};
  final accounts = {for (final account in state.accounts) account.id: account};
  final grouped = <String, List<_OrderCandidate>>{};
  for (final machine in state.machines) {
    for (final status in statuses[machine.id]?.tasks ?? <TaskStatus>[]) {
      if (status.state != TaskState.TASK_STATE_SUCCEEDED ||
          !status.hasPayment() ||
          !isValidOrderId(status.payment.orderId)) {
        continue;
      }
      final task = tasks[status.id];
      final account = accounts[task?.accountId];
      // Without the original local association we cannot safely label the
      // account or merge orders. The normal task status still remains visible.
      if (task == null || account == null) continue;
      final key = '${account.uid}:${status.payment.orderId}';
      (grouped[key] ??= []).add(
        _OrderCandidate(
          account,
          status.payment,
          PaymentSource(
            machine,
            task,
            disconnected: disconnected.contains(machine.id),
          ),
        ),
      );
    }
  }
  final result = <DisplayOrderPayment>[];
  for (final entries in grouped.values) {
    entries.sort((a, b) {
      // A detail-only report must not erase a code held by another node.
      final byCode = (b.code.isNotEmpty ? 1 : 0).compareTo(
        a.code.isNotEmpty ? 1 : 0,
      );
      if (byCode != 0) return byCode;
      final byTime = (b.capturedAt?.millisecondsSinceEpoch ?? 0).compareTo(
        a.capturedAt?.millisecondsSinceEpoch ?? 0,
      );
      if (byTime != 0) return byTime;
      final bySource = a.source.key.compareTo(b.source.key);
      return bySource != 0 ? bySource : a.code.compareTo(b.code);
    });
    final selected = entries.first;
    final sources = {
      for (final entry in entries) entry.source.key: entry.source,
    }.values.toList()..sort((a, b) => a.key.compareTo(b.key));
    result.add(
      DisplayOrderPayment(
        account: selected.account,
        orderId: selected.payment.orderId,
        paymentCode: selected.code,
        capturedAt: selected.capturedAt,
        sources: List.unmodifiable(sources),
      ),
    );
  }
  return result..sort((a, b) => a.key.compareTo(b.key));
}
