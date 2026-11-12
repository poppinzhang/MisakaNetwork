import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

class DelayedStatusGateway extends FakeGateway {
  final requests = <Completer<AgentStatus>>[];

  @override
  Future<AgentStatus> status(Machine m) {
    final result = Completer<AgentStatus>();
    requests.add(result);
    return result.future;
  }
}

void main() {
  test('concurrent refreshes wait for status and dispatch records', () async {
    final store = MemoryStore()
      ..state = SavedState(
        machines: [machine('a')],
        tasks: [TicketTask(id: 'task', name: '演出', accountId: 'account')],
      );
    final gateway = DelayedStatusGateway();
    final c = controller(store: store, gateway: gateway);
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    final saving = Completer<void>();
    final allowSave = Completer<void>();
    store.beforeSave = (_) async {
      saving.complete();
      await allowSave.future;
    };

    final first = c.refresh();
    final second = c.refresh();
    expect(identical(first, second), isTrue);
    var complete = false;
    final observed = second.then((_) => complete = true);
    await Future<void>.value();
    expect(gateway.requests, hasLength(1));
    expect(c.polling, isTrue);
    expect(complete, isFalse);

    gateway.requests.single.complete(
      AgentStatus(
        tasks: [TaskStatus(id: 'task', state: TaskState.TASK_STATE_RUNNING)],
      ),
    );
    await saving.future;
    expect(complete, isFalse);
    expect(c.polling, isTrue);
    expect(c.state.tasks.single.dispatchedTo, isEmpty);

    allowSave.complete();
    await Future.wait([first, second, observed]);
    expect(c.polling, isFalse);
    expect(c.statuses['a']!.tasks.single.id, 'task');
    expect(c.state.tasks.single.dispatchedTo, ['a']);
    expect(store.state.tasks.single.dispatchedTo, ['a']);
    expect(gateway.requests, hasLength(1));
  });

  test('failed shared refresh preserves state and allows recovery', () async {
    final store = MemoryStore()..state = SavedState(machines: [machine('a')]);
    final gateway = DelayedStatusGateway();
    final c = controller(store: store, gateway: gateway);
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    final previous = AgentStatus(version: 'cached');
    c.statuses['a'] = previous;

    final first = c.refresh();
    final second = c.refresh();
    await Future<void>.value();
    gateway.requests.single.completeError(const UserError('连接失败'));
    await Future.wait([first, second]);
    expect(c.polling, isFalse);
    expect(c.connectionErrors['a'], '连接失败');
    expect(c.statuses['a'], same(previous));

    final retry = c.refresh();
    expect(identical(first, retry), isFalse);
    await Future<void>.value();
    expect(gateway.requests, hasLength(2));
    gateway.requests.last.complete(AgentStatus(version: 'recovered'));
    await retry;
    expect(c.polling, isFalse);
    expect(c.connectionErrors, isEmpty);
    expect(c.statuses['a']!.version, 'recovered');
    expect(c.lastSeen['a'], isNotNull);
  });

  test('refresh requested by a listener joins the active operation', () async {
    final store = MemoryStore()..state = SavedState(machines: [machine('a')]);
    final gateway = DelayedStatusGateway();
    final c = controller(store: store, gateway: gateway);
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    Future<void>? fromListener;
    c.addListener(() {
      if (c.polling) fromListener ??= c.refresh();
    });

    final refresh = c.refresh();
    expect(fromListener, same(refresh));
    await Future<void>.value();
    expect(gateway.requests, hasLength(1));
    gateway.requests.single.complete(AgentStatus());
    await refresh;
    expect(c.polling, isFalse);
  });
}
