import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

const summary = TaskSummary(projectId: '400', projectName: '演出', quantity: 1);
const config = {
  'project_id': 401,
  'link_id': 100,
  'screen_id': 1,
  'sku_id': 3,
  'buyer_info': [
    {'id': 12},
  ],
  'buyer': '测试联系人',
  'tel': '测试电话',
  'deliver_info': {'addr_id': 1},
};

class _Fixture {
  final store = MemoryStore()..state = SavedState(machines: [machine('a')]);
  final runtime = FakeRuntime();
  final gateway = FakeGateway();
  late final AppController c = controller(
    store: store,
    runtime: runtime,
    gateway: gateway,
  );
  late Account a, b;
  late TicketTask task;

  Future<void> init() async {
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    a = await c.addAccount('甲', [
      {'name': 's', 'value': 'old-cookie'},
    ], uid: '100');
    b = await c.addAccount('乙', [
      {'name': 's', 'value': 'new-cookie'},
    ], uid: '123');
    task = await c.addTask('固定名称', a, config, summary: summary);
  }

  Future<TicketTask> edit({
    Account? account,
    TicketTask? original,
    TaskSummary newSummary = summary,
    Map<String, dynamic>? replacement,
  }) => c.updateTask(
    original ?? task,
    account ?? b,
    replacement ??
        {
          ...config,
          'screen_id': 2,
          'sku_id': 7,
          'buyer_info': [
            {'id': 19},
          ],
          'deliver_info': {'addr_id': 2},
          'nested': {'cookie_json': 'must-be-stripped'},
        },
    startAt: '2030-03-05 13:14:15',
    requestIntervalMs: 775,
    summary: newSummary,
  );
}

void main() {
  late _Fixture f;
  setUp(() async {
    f = _Fixture();
    await f.init();
  });

  test('invalid stored revision never selects another encrypted slot', () {
    for (final invalid in [-1, '1', false, 1.5, null]) {
      expect(
        () => TicketTask.fromJson({
          ...f.task.toJson(),
          'configRevision': invalid,
        }),
        throwsFormatException,
      );
    }
    expect(TicketTask.fromJson(f.task.toJson()).configRevision, 0);
  });

  test('edit commits the same task with the new account and dispatch payload after restart', () async {
    final selected = TaskSummary.fromSelection(
      {
        'project_id': 400,
        'project_name': '演出',
        'ticket_options': [
          {'screen': '晚场', 'desc': '普通票', 'project_id': 401},
        ],
      },
      0,
      1,
    );
    final updated = await f.edit(newSummary: selected);
    expect(updated.id, f.task.id);
    expect(updated.name, f.task.name);
    expect(updated.accountId, f.b.id);
    expect(f.c.state.tasks.single, same(updated));
    expect(f.store.secrets.containsKey(f.task.configKey), isFalse);
    expect(f.store.state.encode(), isNot(contains('buyer_info')));
    final validation = f.runtime.parameters.last['config'] as Map;
    expect(validation['cookies'].single['value'], 'new-cookie');
    expect(validation['nested'], isEmpty);
    expect(f.c.canEditTask(f.task), isFalse);
    await expectLater(
      f.c.dispatch(f.task, [machine('a')]),
      throwsA(isA<UserError>()),
    );
    await expectLater(f.edit(), throwsA(isA<UserError>()));
    expect(f.gateway.submitted, isEmpty);
    final restarted = controller(store: f.store, gateway: f.gateway);
    addTearDown(restarted.dispose);
    await restarted.initialize(poll: false);
    final saved = restarted.state.tasks.single;
    expect(saved.summary?.projectId, '400');
    expect(saved.summary?.ticketName, '普通票');
    expect(restarted.canEditTask(saved), isTrue);
    final editedConfig = await restarted.readTaskConfig(saved);
    expect(editedConfig['sku_id'], 7);
    expect(editedConfig['buyer_info'].single['id'], 19);
    expect(editedConfig['deliver_info']['addr_id'], 2);
    expect(await restarted.dispatch(saved, [machine('a')]), isEmpty);
    final request = f.gateway.submitted['a']!;
    expect(request.id, f.task.id);
    expect(request.name, '固定名称');
    expect(request.cookieJson, contains('new-cookie'));
    expect(jsonDecode(request.configJson), editedConfig);
    expect(request.timeStart, '2030-03-05T13:14:15');
    expect(request.requestIntervalMs, 775);
    expect(restarted.state.tasks.single.configKey, saved.configKey);
    expect(restarted.canEditTask(saved), isFalse);
  });

  test(
    'rejects changed project, contact, or original-account address',
    () async {
      final before = Map.of(f.store.secrets);
      for (final attempt in [
        () => f.edit(newSummary: const TaskSummary(projectId: '999')),
        () =>
            f.edit(replacement: {...config, 'link_id': '', 'project_id': 999}),
        () => f.edit(replacement: {...config, 'tel': '其他'}),
        () => f.edit(replacement: {...config, 'buyer': '其他'}),
        () => f.edit(account: f.a),
      ]) {
        await expectLater(attempt(), throwsA(isA<UserError>()));
      }
      expect(f.store.secrets, before);
      expect(f.c.canEditTask(f.task), isTrue);
    },
  );

  test(
    'failed validation, secret write or metadata commit keeps both originals',
    () async {
      final before = Map.of(f.store.secrets);
      f.runtime.valid = false;
      await expectLater(f.edit(), throwsA(isA<UserError>()));
      expect(f.store.secrets, before);
      f.runtime.valid = true;
      f.store.failWrite.add(f.task.inactiveConfigKey);
      await expectLater(f.edit(), throwsA(isA<UserError>()));
      f.store.failWrite.clear();
      f.store.failSave = true;
      await expectLater(f.edit(), throwsA(isA<UserError>()));
      expect(f.store.secrets, before);
      expect(f.store.state.tasks.single.configRevision, 0);
      expect(await f.c.readTaskConfig(f.task), config);
      f.store.failSave = false;
      expect((await f.edit()).configRevision, 1);
    },
  );

  test(
    'dispatch and removal cannot interleave with saving a changed account',
    () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      f.store.beforeSave = (next) async {
        reached.complete();
        await release.future;
      };
      final edit = f.edit();
      await reached.future;
      // A restart before switching metadata will still use the old secret.
      expect(f.store.state.tasks.single.configKey, f.task.configKey);
      expect(jsonDecode(f.store.secrets[f.task.configKey]!), config);
      expect(f.c.canEditTask(f.task), isFalse);
      await expectLater(
        f.c.dispatch(f.task, [machine('a')]),
        throwsA(isA<UserError>()),
      );
      await expectLater(f.c.removeTask(f.task), throwsA(isA<UserError>()));
      await expectLater(f.edit(), throwsA(isA<UserError>()));
      expect(f.gateway.submitted, isEmpty);
      release.complete();
      final updated = await edit;
      f.store.beforeSave = null;
      expect(f.c.canEditTask(updated), isTrue);
    },
  );

  test(
    'dispatch reservation blocks edits until a pre-submit failure is known',
    () async {
      final reached = Completer<void>();
      final response = Completer<AgentStatus>();
      var first = true;
      f.gateway.statusHandler = (_) async {
        if (!first) return AgentStatus();
        first = false;
        reached.complete();
        return response.future;
      };
      // FakeRuntime normally authenticates the other test account.
      f.runtime.responses['login_state'] = {
        'status': 'valid',
        'logged_in': true,
        'uid': f.a.uid,
      };
      final sending = f.c.dispatch(f.task, [machine('a')]);
      await reached.future;
      expect(f.c.canEditTask(f.task), isFalse);
      await expectLater(f.edit(), throwsA(isA<UserError>()));
      response.completeError(const UserError('无法获取节点信息'));
      expect(await sending, isNotEmpty);
      expect(f.c.canEditTask(f.task), isTrue);
      expect(await f.edit(), isA<TicketTask>());
    },
  );

  test(
    'terminal, uncertain, legacy and newly observed executions block editing',
    () async {
      final remote = TaskStatus(
        id: f.task.id,
        state: TaskState.TASK_STATE_SUCCEEDED,
      );
      f.c.statuses['a'] = AgentStatus(tasks: [remote]);
      expect(f.c.canEditTask(f.task), isFalse);
      await expectLater(f.c.readTaskConfig(f.task), throwsA(isA<UserError>()));
      f.c.statuses.clear();
      for (final fields in [
        {
          'dispatchedTo': ['a'],
        },
        {
          'dispatches': [
            const TaskDispatch(machineId: 'a', executionId: 'old-run').toJson(),
          ],
        },
        {
          'dispatches': [
            const TaskDispatch(
              machineId: 'a',
              executionId: 'old-run',
              finished: true,
            ).toJson(),
          ],
        },
      ]) {
        final stored = TicketTask.fromJson({...f.task.toJson(), ...fields});
        f.c.state = SavedState(accounts: f.c.state.accounts, tasks: [stored]);
        expect(f.c.canEditTask(f.task), isFalse);
        await expectLater(f.edit(), throwsA(isA<UserError>()));
      }
    },
  );

  test('inactive secret cleanup is retried by deletion and leaves active configuration intact', () async {
    f.store.failDelete.add(f.task.configKey);
    final updated = await f.edit();
    expect(await f.c.readTaskConfig(updated), containsPair('sku_id', 7));
    await expectLater(f.c.removeTask(updated), throwsA(isA<UserError>()));
    expect(f.store.state.tasks.single.configKey, updated.configKey);
    expect(f.store.secrets[updated.configKey], isNotNull);
    f.store.failDelete.clear();
    await f.c.removeTask(updated);
    expect(
      f.store.secrets.keys.where((key) => key.startsWith('task.')),
      isEmpty,
    );
    expect(f.store.state.tasks, isEmpty);
  });
}
