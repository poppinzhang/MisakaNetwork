import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../generated/misaka/v1/sisters.pb.dart';
import 'models.dart';
import 'payments.dart';

const _channel = MethodChannel('misaka/notifications');
const notificationPermissionHint = '请在系统通知设置中允许 LastOrder 发送通知。';

Future<void> requestSuccessNotificationPermission() async {
  bool? allowed;
  try {
    allowed = await _channel.invokeMethod<bool>('requestPermission');
  } catch (_) {
    throw const UserError('暂时无法访问系统通知设置，请稍后重试。');
  }
  if (allowed != true) throw const UserError(notificationPermissionHint);
}

Future<bool> showSuccessNotification(String id) async =>
    await _channel.invokeMethod<bool>('showSuccess', {
      'id': id,
      'title': '抢票成功',
      'body': '已创建订单，请前往哔哩哔哩核对订单并及时付款。',
    }) ==
    true;

/// Use only the confirmed creation signal. A duplicate order may have the
/// same successful task state and a valid payment code.
Set<String> createdOrderNotificationIds(
  SavedState state,
  Map<String, AgentStatus> statuses,
) {
  final ids = <String>{};
  for (final machine in state.machines) {
    for (final result in statuses[machine.id]?.tasks ?? <TaskStatus>[]) {
      if (result.state != TaskState.TASK_STATE_SUCCEEDED ||
          !result.orderCreated) {
        continue;
      }
      final task = state.tasks
          .where((t) => t.ownsExecution(machine.id, result.id))
          .firstOrNull;
      final account = state.accounts
          .where((a) => a.id == task?.accountId)
          .firstOrNull;
      if (account == null) continue;
      final orderId = result.payment.orderId;
      final key = isValidOrderId(orderId)
          ? 'order/${account.uid}/$orderId'
          : 'execution/${machine.id}/${result.id}';
      ids.add(const Uuid().v5(Namespace.url.value, 'misaka:notification/$key'));
    }
  }
  return ids;
}
