import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

class _SensitiveValue {
  @override
  String toString() =>
      throw StateError('Sensitive objects must not be printed');
}

Map<String, dynamic> purchaseSelection() => {
  'project_name': '  示例音乐会  ',
  'selected_date': '  2030-01-02  ',
  'ticket_options': [
    {'screen': '上午场', 'desc': '普通票'},
    {
      'screen': '  晚场  ',
      'screen_name': 'unused-screen-name',
      'desc': '  前排票  ',
      'display': 'unused-display-label',
      'buyer_info': {'name': 'private-buyer'},
    },
  ],
  'cookies': [
    {'name': 'SESSDATA', 'value': 'private-cookie'},
  ],
  'buyers': [
    {'personal_id': 'private-document', 'tel': 'private-phone'},
  ],
  'addresses': [
    {'address': 'private-address'},
  ],
};

const summary = TaskSummary(
  projectName: '示例音乐会',
  screenName: '晚场',
  ticketName: '前排票',
  selectedDate: '2030-01-02',
  quantity: 2,
);

void main() {
  test('selection summary contains only the selected public details', () {
    final selected = TaskSummary.fromSelection(purchaseSelection(), 1, 2);
    expect(selected.toJson(), summary.toJson());
    final encoded = jsonEncode(selected.toJson());
    expect(encoded, isNot(contains('private-')));
    expect(encoded, isNot(contains('unused-')));
    expect(encoded, isNot(contains('上午场')));
  });

  test(
    'empty labels use string alternatives and an absent date stays empty',
    () {
      final selected = TaskSummary.fromSelection(
        {
          'project_name': ' 示例音乐会 ',
          'selected_date': null,
          'ticket_options': [
            {
              'screen': '  ',
              'screen_name': '  晚场  ',
              'desc': '',
              'display': '  前排票  ',
            },
          ],
        },
        0,
        1,
      );
      expect(selected.projectName, '示例音乐会');
      expect(selected.screenName, '晚场');
      expect(selected.ticketName, '前排票');
      expect(selected.selectedDate, isEmpty);
      expect(selected.quantity, 1);
      expect(const TaskSummary().toJson(), {
        'projectName': '',
        'screenName': '',
        'ticketName': '',
        'selectedDate': '',
        'quantity': 0,
      });
    },
  );

  test(
    'invalid option lists, indices, entries and quantities are rejected',
    () {
      for (final options in [
        null,
        'invalid',
        <String, dynamic>{},
        [],
        [null],
        [4],
      ]) {
        expect(
          () => TaskSummary.fromSelection({'ticket_options': options}, 0, 1),
          throwsA(isA<UserError>()),
        );
      }
      for (final index in [-1, 2]) {
        expect(
          () => TaskSummary.fromSelection(purchaseSelection(), index, 1),
          throwsA(isA<UserError>()),
        );
      }
      for (final quantity in [0, -1]) {
        expect(
          () => TaskSummary.fromSelection(purchaseSelection(), 0, quantity),
          throwsA(isA<UserError>()),
        );
      }
    },
  );

  test(
    'non-string public fields fail without stringifying private objects',
    () {
      for (final field in ['project_name', 'selected_date']) {
        final purchase = purchaseSelection()..[field] = _SensitiveValue();
        expect(
          () => TaskSummary.fromSelection(purchase, 1, 1),
          throwsA(isA<UserError>()),
        );
      }
      for (final field in ['screen', 'screen_name', 'desc', 'display']) {
        final purchase = purchaseSelection();
        purchase['ticket_options'] = [
          {field: _SensitiveValue()},
        ];
        expect(
          () => TaskSummary.fromSelection(purchase, 0, 1),
          throwsA(isA<UserError>()),
        );
      }
      for (final value in [
        123,
        ['private-buyer'],
        {'tel': 'private-phone'},
      ]) {
        final purchase = purchaseSelection()..['project_name'] = value;
        expect(
          () => TaskSummary.fromSelection(purchase, 0, 1),
          throwsA(isA<UserError>()),
        );
      }
    },
  );

  test(
    'saved summaries survive task roundtrip and dispatch record changes',
    () {
      final task = TicketTask(
        id: 'task',
        name: '音乐会任务',
        accountId: 'account',
        startAt: '2030-01-01T20:00:00',
        dispatchedTo: ['b'],
        summary: summary,
      ).withDispatched(['a', 'b']);
      final restored = SavedState.decode(SavedState(tasks: [task]).encode())
          .tasks
          .single;
      expect(restored.summary?.toJson(), summary.toJson());
      expect(restored.dispatchedTo, ['a', 'b']);
      expect(restored.startAt, '2030-01-01T20:00:00');
      expect(restored.accountId, 'account');
      final withoutSummary = TicketTask.fromJson({
        'id': 'task',
        'name': '既有任务',
        'accountId': 'account',
      });
      expect(withoutSummary.summary, isNull);
      expect(withoutSummary.withDispatched(['a']).summary, isNull);
      expect(withoutSummary.toJson().containsKey('summary'), isFalse);
    },
  );

  test(
    'saved summary parser rejects invalid known fields and ignores extras',
    () {
      for (final field in [
        'projectName',
        'screenName',
        'ticketName',
        'selectedDate',
        'quantity',
      ]) {
        expect(
          () => TaskSummary.fromJson({
            ...summary.toJson(),
            field: _SensitiveValue(),
          }),
          throwsFormatException,
        );
      }
      expect(
        () => TaskSummary.fromJson({'quantity': -1}),
        throwsFormatException,
      );
      expect(
        TaskSummary.fromJson({
          ...summary.toJson(),
          'private': _SensitiveValue(),
        }).toJson(),
        summary.toJson(),
      );
      expect(TaskSummary.fromJson({}).toJson(), const TaskSummary().toJson());
    },
  );

  test(
    'adding, dispatching and restarting retain metadata without secrets',
    () async {
      final store = MemoryStore();
      final gateway = FakeGateway();
      final runtime = FakeRuntime();
      final c = controller(store: store, gateway: gateway, runtime: runtime);
      await c.initialize(poll: false);
      final account = await c.addAccount('测试账号', [
        {'name': 'SESSDATA', 'value': 'private-cookie'},
      ], uid: '123');
      final config = {
        'buyer_info': [
          {'personal_id': 'private-document', 'tel': 'private-phone'},
        ],
        'address': 'private-address',
      };
      final task = await c.addTask(
        '音乐会任务',
        account,
        config,
        summary: TaskSummary.fromSelection(purchaseSelection(), 1, 2),
      );
      expect(task.summary?.toJson(), summary.toJson());
      expect(jsonDecode(store.secrets['task.${task.id}']!), config);
      expect(store.state.encode(), isNot(contains('private-')));
      expect(await c.dispatch(task, [machine('a')]), isEmpty);
      expect(jsonDecode(gateway.submitted['a']!.configJson), config);
      expect(gateway.submitted['a']!.cookieJson, contains('private-cookie'));
      expect(c.state.tasks.single.summary?.toJson(), summary.toJson());
      c.dispose();

      final restarted = controller(store: store);
      addTearDown(restarted.dispose);
      await restarted.initialize(poll: false);
      final restored = restarted.state.tasks.single;
      expect(restored.summary?.toJson(), summary.toJson());
      expect(restored.dispatchedTo, ['a']);
      expect(restored.id, task.id);
      expect(restored.accountId, account.id);
      expect(restarted.state.encode(), isNot(contains('private-')));
    },
  );

  test(
    'failed task persistence rolls back its summary and secret together',
    () async {
      final store = MemoryStore();
      final c = controller(store: store);
      addTearDown(c.dispose);
      await c.initialize(poll: false);
      final account = await c.addAccount('测试账号', [
        {'name': 'SESSDATA', 'value': 'private-cookie'},
      ], uid: '123');
      await c.addTask('已有任务', account, {'existing': true});
      final savedState = store.state.encode();
      final savedSecrets = Map<String, String>.from(store.secrets);
      store.failSave = true;
      await expectLater(
        c.addTask('未保存任务', account, {
          'private': 'private-buyer',
        }, summary: summary),
        throwsA(isA<UserError>()),
      );
      expect(store.state.encode(), savedState);
      expect(c.state.encode(), savedState);
      expect(store.secrets, savedSecrets);
      expect(c.state.tasks.single.summary, isNull);
    },
  );
}
