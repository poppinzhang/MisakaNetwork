import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

class _CopyStore extends MemoryStore {
  Future<void> Function(String key)? afterWrite;

  @override
  Future<void> writeSecret(String key, String value) async {
    await super.writeSecret(key, value);
    await afterWrite?.call(key);
  }
}

void main() {
  final account = Account(
    id: 'account',
    name: '测试账号',
    uid: '123',
    authStatus: AccountAuthStatus.valid,
  );
  const summary = TaskSummary(
    projectId: '100',
    projectName: '演出',
    screenName: '晚场',
    ticketName: '指定席',
    selectedDate: '2030-01-02',
    quantity: 1,
  );
  const config = {
    'project_id': 100,
    'screen_id': 2,
    'sku_id': 3,
    'buyer_info': [
      {'id': 5, 'name': '测试购票人'},
    ],
    'buyer': '测试联系人',
    'tel': '测试电话',
    'deliver_info': {'addr_id': 6},
  };

  late TicketTask source;
  late _CopyStore store;
  late FakeRuntime runtime;
  late FakeGateway gateway;
  late AppController c;

  setUp(() async {
    source = TicketTask(
      id: 'source',
      name: '演出',
      accountId: account.id,
      startAt: '2030-01-01T12:34:56',
      startDelayMs: 0,
      requestIntervalMs: 725,
      summary: summary,
      configRevision: 1,
    );
    final other = TicketTask(id: 'other', name: '其他演出', accountId: account.id);
    store = _CopyStore()
      ..state = SavedState(accounts: [account], tasks: [source, other])
      ..secrets[source.configKey] = jsonEncode(config);
    runtime = FakeRuntime();
    gateway = FakeGateway();
    c = controller(store: store, runtime: runtime, gateway: gateway);
    addTearDown(c.dispose);
    await c.initialize(poll: false);
  });

  test('copies the active configuration locally, independent of execution history and login', () async {
    final dispatched = source.withDispatches([
      const TaskDispatch(machineId: 'one', executionId: 'unconfirmed'),
      const TaskDispatch(machineId: 'two', executionId: 'done', finished: true),
    ]);
    c.state = SavedState(
      accounts: [account.copyWith(authStatus: AccountAuthStatus.expired)],
      tasks: [dispatched, c.state.tasks.last],
    );
    final raw = jsonEncode({
      ...config,
      'cookies': ['obsolete login'],
      'nested': [
        {'cookie_json': 'obsolete login', 'preserve': 7},
      ],
    });
    store.secrets[source.configKey] = raw;
    store.failRead.add('account.${account.id}');
    final copy = await c.copyTask(source);
    expect(copy.id, isNot(source.id));
    expect(copy.configRevision, 0);
    expect(copy.name, source.name);
    expect(copy.accountId, source.accountId);
    expect(copy.startAt, source.startAt);
    expect(copy.startDelayMs, 0);
    expect(copy.requestIntervalMs, source.requestIntervalMs);
    expect(copy.summary!.toJson(), summary.toJson());
    expect(copy.dispatches, isEmpty);
    expect(c.canEditTask(copy), isTrue);
    expect(c.canEditTask(dispatched), isFalse);
    expect(store.state.tasks.map((t) => t.id), ['source', copy.id, 'other']);
    expect(store.state.tasks.first.toJson(), dispatched.toJson());
    expect(store.secrets[source.configKey], raw);
    expect(store.state.encode(), isNot(contains('测试购票人')));
    expect(runtime.calls, isEmpty);
    expect(gateway.statusRequests, isEmpty);
    expect(gateway.submitted, isEmpty);
    final restarted = controller(store: store);
    addTearDown(restarted.dispose);
    await restarted.initialize(poll: false);
    await restarted.removeTask(restarted.state.tasks.first);
    expect(await restarted.readTaskConfig(restarted.state.tasks.first), {
      ...config,
      'nested': [
        {'preserve': 7},
      ],
    });
  });

  test(
    'copy during dispatch leaves each first submission with its own ID',
    () async {
      final querying = Completer<void>();
      final response = Completer<AgentStatus>();
      gateway.statusHandler = (_) {
        if (!querying.isCompleted) querying.complete();
        return response.future;
      };
      store.secrets['account.${account.id}'] = '[{"name":"s","value":"test"}]';
      final node = machine('one');
      final sending = c.dispatch(source, [node]);
      await querying.future;
      final copy = await c.copyTask(source);
      expect(c.canEditTask(copy), isTrue);
      expect(gateway.submitted, isEmpty);
      response.complete(
        AgentStatus(
          supportsTimeStart: true,
          supportsStartDelay: true,
          supportsRequestInterval: true,
        ),
      );
      expect(await sending, isEmpty);
      expect(gateway.submitted[node.id]!.id, source.id);
      final updated = await c.updateTask(
        copy,
        account,
        {...config, 'sku_id': 9},
        startAt: '',
        requestIntervalMs: 900,
        summary: summary,
      );
      expect(await c.dispatch(updated, [node]), isEmpty);
      expect(gateway.submitted[node.id]!.id, copy.id);
      expect(jsonDecode(gateway.submitted[node.id]!.configJson)['sku_id'], 9);
      expect(jsonDecode(store.secrets[source.configKey]!), config);
    },
  );

  test('an unreadable, missing or corrupt source creates no copy', () async {
    store.failRead.add(source.configKey);
    await expectLater(c.copyTask(source), throwsA(isA<UserError>()));
    store.failRead.clear();
    for (final invalid in [null, '[]', '{broken']) {
      if (invalid == null) {
        store.secrets.remove(source.configKey);
      } else {
        store.secrets[source.configKey] = invalid;
      }
      await expectLater(c.copyTask(source), throwsA(isA<UserError>()));
      expect(c.state.tasks.map((t) => t.id), ['source', 'other']);
      expect(store.secrets[source.configKey], invalid);
    }
  });

  test(
    'write and metadata failures clean up the new secret and permit retry',
    () async {
      final original = Map.of(store.secrets);
      store.afterWrite = (_) async => throw const UserError('写入失败');
      await expectLater(c.copyTask(source), throwsA(isA<UserError>()));
      expect(store.secrets, original);
      store.afterWrite = null;
      store.failSave = true;
      await expectLater(c.copyTask(source), throwsA(isA<UserError>()));
      expect(store.secrets, original);
      expect(store.state.tasks.map((t) => t.id), ['source', 'other']);
      store.failSave = false;
      final first = await c.copyTask(source);
      final second = await c.copyTask(source);
      expect(first.id, isNot(second.id));
      expect(store.state.tasks.map((t) => t.id), [
        'source',
        second.id,
        first.id,
        'other',
      ]);
    },
  );

  for (final remove in [false, true]) {
    test(
      'discards a staged copy when the source is ${remove ? "removed" : "edited"}',
      () async {
        final reached = Completer<void>();
        final release = Completer<void>();
        store.afterWrite = (_) async {
          store.afterWrite = null;
          reached.complete();
          await release.future;
        };
        final copying = c.copyTask(source);
        await reached.future;
        if (remove) {
          await c.removeTask(source);
        } else {
          store.secrets['account.${account.id}'] =
              '[{"name":"s","value":"test"}]';
          await c.updateTask(
            source,
            account,
            config,
            startAt: '',
            requestIntervalMs: 600,
            summary: summary,
          );
        }
        release.complete();
        await expectLater(copying, throwsA(isA<UserError>()));
        expect(
          store.state.tasks.map((t) => t.id),
          remove ? ['other'] : ['source', 'other'],
        );
        final configKeys = store.secrets.keys.where(
          (key) => key.startsWith('task.'),
        );
        expect(configKeys, remove ? isEmpty : [source.inactiveConfigKey]);
      },
    );
  }
}
