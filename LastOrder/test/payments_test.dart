import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/payments.dart';

import 'fakes.dart';

const wechatCode = 'weixin://wxpay/bizpayurl?pr=synthetic_1';
const alipayCode = 'https://qr.alipay.com/synthetic-2';

SavedState paymentState() => SavedState(
  machines: [machine('a'), machine('b')],
  accounts: [
    Account(id: 'account-a', name: '账号甲', uid: '10001'),
    Account(id: 'account-b', name: '账号乙', uid: '10002'),
    Account(id: 'account-alias', name: '账号甲别名', uid: '10001'),
  ],
  tasks: [
    TicketTask(id: 'task-a', name: '任务甲', accountId: 'account-a'),
    TicketTask(id: 'task-b', name: '任务乙', accountId: 'account-a'),
    TicketTask(id: 'task-c', name: '任务丙', accountId: 'account-b'),
    TicketTask(id: 'task-alias', name: '别名任务', accountId: 'account-alias'),
    TicketTask(id: 'task-orphan', name: '已移除账号', accountId: 'missing'),
  ],
);

TaskStatus paymentStatus({
  String taskId = 'task-a',
  String orderId = '12345',
  String code = wechatCode,
  int captured = 1000,
  TaskState state = TaskState.TASK_STATE_SUCCEEDED,
}) => TaskStatus(
  id: taskId,
  state: state,
  payment: OrderPayment(
    orderId: orderId,
    paymentCodeUrl: code,
    // A trusted-looking URL for a different order must also be ignored.
    orderDetailUrl:
        'https://show.bilibili.com/platform/orderDetail.html?order_id=999',
    capturedUnixMs: Int64(captured),
  ),
);

void main() {
  test(
    'only exact payment formats and ASCII positive order IDs are accepted',
    () {
      for (final value in [wechatCode, alipayCode]) {
        expect(isValidPaymentCode(value), isTrue, reason: value);
      }
      for (final value in [
        '',
        'https://show.bilibili.com/platform/orderDetail.html?order_id=123',
        'http://qr.alipay.com/token',
        'https://qr.alipay.com.evil.test/token',
        'https://qr.alipay.com@evil.test/token',
        'https://user:password@qr.alipay.com/token',
        'https://qr.alipay.com:443/token',
        'https://qr.alipay.com/token?redirect=evil',
        'https://qr.alipay.com/token#fragment',
        'https://qr.alipay.com/%74oken',
        'https://qr.alipay.com/a/../token',
        'https://qr.alipay.com/token\\evil',
        'weixin://wxpay/bizpayurl?pr=token&pr=other',
        'weixin://wxpay/bizpayurl?pr=token&redirect=evil',
        'weixin://evil/bizpayurl?pr=token',
        'weixin://wxpay/bizpayurl?pr=%74oken',
        'weixin://wxpay/bizpayurl?pr=中文',
        '$wechatCode\n',
        '$alipayCode\r',
        ' $wechatCode',
        '$wechatCode ',
        'https://qr.alipay.com/${'a' * 513}',
        'javascript:alert(1)',
        'file:///private/file',
      ]) {
        expect(isValidPaymentCode(value), isFalse, reason: value);
      }
      for (final id in ['1', '12345', '9' * 80]) {
        expect(isValidOrderId(id), isTrue);
      }
      for (final id in ['', '0', '01', '-1', '１', '1\n', '1&x=2', '9' * 81]) {
        expect(isValidOrderId(id), isFalse, reason: id);
        expect(() => orderDetailUri(id), throwsFormatException);
      }
    },
  );

  test('same UID and order merge across nodes, tasks and account aliases', () {
    final orders = collectOrderPayments(paymentState(), {
      'a': AgentStatus(
        tasks: [
          paymentStatus(),
          paymentStatus(taskId: 'task-b'),
        ],
      ),
      'b': AgentStatus(tasks: [paymentStatus(taskId: 'task-alias')]),
    });
    expect(orders, hasLength(1));
    expect(orders.single.key, '10001:12345');
    expect(orders.single.sources, hasLength(3));
    expect(
      orders.single.detailUri.toString(),
      'https://show.bilibili.com/platform/orderDetail.html?order_id=12345',
    );
  });

  test('different orders or accounts never merge', () {
    final orders = collectOrderPayments(paymentState(), {
      'a': AgentStatus(
        tasks: [
          paymentStatus(),
          paymentStatus(taskId: 'task-b', orderId: '12346'),
          paymentStatus(taskId: 'task-c'),
        ],
      ),
    });
    expect(orders.map((o) => o.key), [
      '10001:12345',
      '10001:12346',
      '10002:12345',
    ]);
  });

  test('keeps valid code over detail-only, selects latest valid code deterministically', () {
    final a = AgentStatus(
      tasks: [
        paymentStatus(code: wechatCode, captured: 2000),
        paymentStatus(taskId: 'task-b', code: '', captured: 9000),
      ],
    );
    final b = AgentStatus(
      tasks: [paymentStatus(code: alipayCode, captured: 3000)],
    );
    final orders = collectOrderPayments(
      paymentState(),
      {'a': a, 'b': b},
      disconnected: {'b'},
    );
    expect(orders.single.paymentCode, alipayCode);
    expect(orders.single.capturedAt!.millisecondsSinceEpoch, 3000);
    expect(orders.single.disconnected, isTrue);
    final reversed = paymentState();
    reversed.machines.setAll(0, reversed.machines.reversed.toList());
    expect(
      collectOrderPayments(reversed, {'b': b, 'a': a}).single.paymentCode,
      alipayCode,
    );
    b.tasks.single.payment.capturedUnixMs = Int64(2000);
    expect(
      collectOrderPayments(reversed, {'b': b, 'a': a}).single.paymentCode,
      wechatCode,
    );
    expect(
      collectOrderPayments(paymentState(), {'a': a, 'b': b}).single.paymentCode,
      wechatCode,
    );
  });

  test('invalid code keeps canonical details without revealing remote URL', () {
    final orders = collectOrderPayments(paymentState(), {
      'a': AgentStatus(
        tasks: [paymentStatus(code: 'https://evil.test/secret')],
      ),
    });
    expect(orders.single.hasPaymentCode, isFalse);
    expect(orders.single.detailUri.host, 'show.bilibili.com');
    expect(orders.single.detailUri.queryParameters, {'order_id': '12345'});
  });

  test(
    'only confirmed results with a known local account and order are shown',
    () {
      final orders = collectOrderPayments(paymentState(), {
        'a': AgentStatus(
          tasks: [
            paymentStatus(orderId: ''),
            paymentStatus(orderId: '01'),
            paymentStatus(taskId: 'missing-task'),
            paymentStatus(taskId: 'task-orphan'),
            paymentStatus(state: TaskState.TASK_STATE_RUNNING),
            paymentStatus(state: TaskState.TASK_STATE_FAILED),
            paymentStatus(state: TaskState.TASK_STATE_CANCELLED),
            TaskStatus(id: 'task-b', state: TaskState.TASK_STATE_SUCCEEDED),
          ],
        ),
        'unknown-machine': AgentStatus(tasks: [paymentStatus()]),
      });
      expect(orders, isEmpty);
    },
  );

  test('invalid timestamps cannot crash UI; repeated polling cannot duplicate orders', () {
    final state = paymentState();
    final snapshot = {
      'a': AgentStatus(tasks: [paymentStatus(captured: -1)]),
    };
    for (var i = 0; i < 3; i++) {
      final orders = collectOrderPayments(state, snapshot);
      expect(orders, hasLength(1));
      expect(orders.single.capturedAt, isNull);
    }
    snapshot['a']!.tasks.single.payment.capturedUnixMs = Int64.MAX_VALUE;
    expect(collectOrderPayments(state, snapshot).single.capturedAt, isNull);
    expect(state.encode(), isNot(contains(wechatCode)));
    expect(collectOrderPayments(state, {}), isEmpty);
    state.accounts.clear();
    expect(collectOrderPayments(state, snapshot), isEmpty);
  });
}
