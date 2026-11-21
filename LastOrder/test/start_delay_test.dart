import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

void main() {
  test('start delay accepts whole milliseconds and survives storage', () {
    final legacy = {'id': 'task', 'name': '定时任务', 'accountId': 'account'};
    expect(TicketTask.fromJson(legacy).startDelayMs, 30);
    for (final delay in [0, 30, 60000]) {
      expect(parseStartDelayMs(' $delay '), delay);
      final task = TicketTask.fromJson({...legacy, 'startDelayMs': delay});
      final saved = SavedState(
        tasks: [
          task.withDispatched(['machine']),
        ],
      );
      expect(
        SavedState.decode(saved.encode()).tasks.single.startDelayMs,
        delay,
      );
    }
    for (final invalid in ['', '-1', '60001', '1.5', '1e2', '0x20']) {
      expect(() => parseStartDelayMs(invalid), throwsA(isA<UserError>()));
    }
    for (final invalid in [-1, 60001, 1.5, true, '30', null]) {
      expect(
        () => TicketTask.fromJson({...legacy, 'startDelayMs': invalid}),
        throwsFormatException,
      );
    }
  });

  test('only scheduled tasks require an agent with the new clock', () async {
    final gateway = FakeGateway()..startDelaySupported = false;
    final c = controller(gateway: gateway);
    addTearDown(c.dispose);
    await c.initialize(poll: false);
    final account = await c.addAccount('测试', [
      {'name': 's', 'value': 'v'},
    ], uid: '123');
    final old = machine('old');
    final immediate = await c.addTask('立即', account, {}, startDelayMs: 500);
    expect(await c.dispatch(immediate, [old]), isEmpty);
    expect(gateway.submitted[old.id]!.hasStartDelayMs(), isFalse);
    final scheduled = [
      await c.addTask('默认', account, {}, startAt: '2030-01-01T09:00:00'),
      await c.addTask(
        '零延迟',
        account,
        {},
        startAt: '2030-01-01T09:00:00',
        startDelayMs: 0,
      ),
    ];
    for (final task in scheduled) {
      final errors = await c.dispatch(task, [old]);
      expect(errors[old.name], contains('重新部署'));
      expect(
        c.state.tasks.firstWhere((t) => t.id == task.id).dispatches,
        isEmpty,
      );
    }
    expect(gateway.submitted[old.id]!.id, immediate.id);

    gateway.startDelaySupported = true;
    final updated = machine('updated');
    for (final (index, task) in scheduled.indexed) {
      expect(await c.dispatch(task, [updated]), isEmpty);
      final request = gateway.submitted[updated.id]!;
      expect(request.hasStartDelayMs(), isTrue);
      expect(request.startDelayMs, [30, 0][index]);
    }
  });
}
