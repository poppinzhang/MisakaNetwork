import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

const originalBuyer = {'id': 13, 'name': '原购票人', 'personal_id': 'test-id-a'};
const newBuyer = {'id': 24, 'name': '新购票人', 'personal_id': 'test-id-b'};
const contact = '合成联系人';
const phone = '13800000000';
const savedConfig = {
  'project_id': 11,
  'screen_id': 33,
  'sku_id': 202,
  'buyer_info': [originalBuyer],
  'deliver_info': {'addr_id': 17, 'name': '原收件人', 'addr': '原测试地址'},
  'buyer': contact,
  'tel': phone,
  'count': 1,
};

class EditRuntime extends FakeRuntime {
  EditRuntime({required this.legacyLink, required this.calendar});
  final bool legacyLink;
  final bool calendar;
  bool acceptConfig = true;
  bool reverseLists = false;
  final selections = <Map<String, dynamic>>[];
  final lookups = <String>[];

  @override
  Future<Map<String, dynamic>> call(
    String op,
    Map<String, dynamic> params,
  ) async {
    switch (op) {
      case 'login_state':
        return {
          'status': 'valid',
          'logged_in': true,
          'uid': (params['cookies'] as List).single['value'],
        };
      case 'purchase_context':
        final projectId = int.parse(params['project_input'].toString());
        if (!legacyLink) expect(projectId, 11);
        final uid = (params['cookies'] as List).single['value'] as String;
        final day = params['selected_date'];
        final options = switch ((calendar, day)) {
          (true, null) => <(int, int, String)>[],
          (true, '2026-12-14') => <(int, int, String)>[],
          (true, '2026-12-13') => [(203, 34, '加演')],
          _ => [(201, 32, '午场'), (202, 33, '晚场')],
        };
        final people = uid == '101'
            ? [
                {'id': 12, 'name': '其他购票人', 'personal_id': 'test-id-other'},
                originalBuyer,
              ]
            : [newBuyer];
        lookups.add(uid);
        return {
          'project_id': projectId,
          'project_name': '测试演出',
          if (calendar)
            'sales_dates': ['2026-12-12', '2026-12-13', '2026-12-14'],
          'selected_date': day,
          'ticket_options': [
            for (final (id, screen, label)
                in reverseLists ? options.reversed : options)
              {
                'id': id,
                'screen_id': screen,
                'project_id': projectId == 66 ? 66 : 11,
                if (legacyLink) 'link_id': projectId == 77 ? 45 : 44,
                'screen': label,
                'desc': '普通票',
                'display': '$label普通票',
                'price': 10000,
                'sale_start': '2026-12-02 12:15:30',
              },
          ],
          'buyers': reverseLists ? people.reversed.toList() : people,
          'addresses': uid == '101'
              ? [
                  {'id': 18, 'name': '其他收件人'},
                  {'id': 17, 'name': '原收件人'},
                ]
              : [
                  {'id': 26, 'name': '新收件人'},
                ],
          'cookies': params['cookies'],
        };
      case 'build_config':
        final context = params['purchase_context'] as Map;
        final selection = params['selection'] as Map<String, dynamic>;
        selections.add(selection);
        final ticket = context['ticket_options'][selection['ticket_index']];
        final address = context['addresses'][selection['address_index']];
        return {
          ...savedConfig,
          'screen_id': ticket['screen_id'],
          'sku_id': ticket['id'],
          'buyer_info': [
            for (final i in selection['buyer_indices']) context['buyers'][i],
          ],
          'deliver_info': {'addr_id': address['id']},
          'buyer': selection['buyer'],
          'tel': selection['tel'],
          'cookies': context['cookies'],
        };
      case 'validate':
        return {
          'ok': acceptConfig,
          'errors': acceptConfig ? [] : ['模拟校验失败'],
        };
      default:
        throw StateError('Unexpected runtime operation: $op');
    }
  }
}

Future<
  ({
    AppController c,
    MemoryStore store,
    EditRuntime runtime,
    FakeGateway gateway,
  })
>
openTasks(
  WidgetTester tester, {
  bool legacyLink = false,
  bool calendar = false,
}) async {
  tester.view.physicalSize = const Size(1320, 1260);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = MemoryStore()
    ..state = SavedState(
      accounts: [
        Account(
          id: 'a',
          name: '账号甲',
          uid: '101',
          authStatus: AccountAuthStatus.valid,
        ),
        Account(
          id: 'b',
          name: '账号乙',
          uid: '202',
          authStatus: AccountAuthStatus.valid,
        ),
      ],
      tasks: [
        TicketTask(
          id: 'draft',
          name: '原任务名称',
          accountId: 'a',
          startAt: '2026-12-01T21:13:52',
          requestIntervalMs: 725,
          summary: TaskSummary(
            projectName: '测试演出',
            screenName: '晚场',
            ticketName: '普通票',
            selectedDate: calendar ? '2026-12-12' : '',
            quantity: 1,
          ),
        ),
        for (final finished in [false, true])
          TicketTask(
            id: 'sent-$finished',
            name: '已分发任务',
            accountId: 'a',
            dispatches: [
              TaskDispatch(
                machineId: 'worker',
                executionId: 'execution-$finished',
                finished: finished,
              ),
            ],
          ),
      ],
    )
    ..secrets['task.draft'] = jsonEncode({
      ...savedConfig,
      if (legacyLink) 'link_id': 44,
    })
    ..secrets['account.a'] = '[{"name":"session","value":"101"}]'
    ..secrets['account.b'] = '[{"name":"session","value":"202"}]';
  final runtime = EditRuntime(legacyLink: legacyLink, calendar: calendar);
  final gateway = FakeGateway();
  final c = controller(store: store, runtime: runtime, gateway: gateway);
  await c.initialize(poll: false);
  addTearDown(c.dispose);
  await tester.pumpWidget(LastOrderApp(controller: c));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('账号与任务'));
  await tester.pumpAndSettle();
  return (c: c, store: store, runtime: runtime, gateway: gateway);
}

Finder editButton(String id) => find.descendant(
  of: find.byKey(ValueKey('task-card-$id')),
  matching: find.byTooltip('编辑任务'),
);
Finder inEditor(Finder finder) =>
    find.descendant(of: find.byType(TaskDialog), matching: finder);

Finder input(String name) => inEditor(
  find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == name,
  ),
);

CheckboxListTile buyerRow(WidgetTester tester, String name) => tester.widget(
  find.ancestor(
    of: inEditor(find.text(name)),
    matching: find.byType(CheckboxListTile),
  ),
);

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> choose<T>(WidgetTester tester, String field, String option) async {
  final dropdown = inEditor(
    find.byWidgetPredicate(
      (w) => w is DropdownButtonFormField<T> && w.decoration.labelText == field,
    ),
  );
  await tapVisible(tester, dropdown);
  await tapVisible(
    tester,
    find
        .descendant(of: find.byType(ListView), matching: find.text(option))
        .last,
  );
}

void main() {
  testWidgets(
    'an empty calendar date preserves edited selections when the previous date is reloaded',
    (tester) async {
      final f = await openTasks(tester, calendar: true);
      await tapVisible(tester, editButton('draft'));
      await choose<int>(tester, '场次 / 票档', '午场普通票');
      await tapVisible(tester, inEditor(find.text('原购票人')));
      await tapVisible(tester, inEditor(find.text('其他购票人')));
      await choose<String>(tester, '场次日期', '2026-12-14');
      expect(inEditor(find.textContaining('没有可选票档')), findsOneWidget);
      expect(inEditor(find.text('保存修改')), findsNothing);
      f.runtime.reverseLists = true;
      await choose<String>(tester, '场次日期', '2026-12-12');
      expect(buyerRow(tester, '原购票人').value, isFalse);
      expect(buyerRow(tester, '其他购票人').value, isTrue);
      await tapVisible(tester, inEditor(find.text('保存修改')));
      expect(f.store.state.tasks.first.summary!.screenName, '午场');
      expect(f.runtime.selections.single['buyer_indices'], [1]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing a calendar task reloads its saved date and can select a ticket on another date',
    (tester) async {
      final f = await openTasks(tester, calendar: true);
      await tapVisible(tester, editButton('draft'));
      expect(inEditor(find.text('2026-12-12')), findsOneWidget);
      expect(inEditor(find.text('晚场普通票')), findsOneWidget);
      await choose<String>(tester, '场次日期', '2026-12-13');
      await choose<int>(tester, '场次 / 票档', '加演普通票');
      expect(buyerRow(tester, '原购票人').value, isTrue);
      await tapVisible(tester, inEditor(find.text('保存修改')));
      final task = f.store.state.tasks.first;
      expect(task.summary!.selectedDate, '2026-12-13');
      expect(task.summary!.screenName, '加演');
      expect(task.startAt, '2026-12-01T21:13:52');
      expect(task.requestIntervalMs, 725);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy linked tickets require proof that the original project contains the saved item',
    (tester) async {
      final f = await openTasks(tester, legacyLink: true);
      await tapVisible(tester, editButton('draft'));
      final project = input('原演出 ID 或会员购链接');
      expect(project, findsOneWidget);
      expect(f.runtime.lookups, isEmpty);
      for (final otherProject in ['66', '77']) {
        await tester.enterText(project, otherProject);
        await tapVisible(tester, find.text('核对原演出'));
        expect(project, findsOneWidget);
        expect(inEditor(find.text('保存修改')), findsNothing);
        expect(f.store.state.tasks.first.summary!.screenName, '晚场');
      }

      await tester.enterText(project, '55');
      await tapVisible(tester, find.text('核对原演出'));
      expect(inEditor(find.text('保存修改')), findsOneWidget);
      expect(inEditor(find.text('晚场普通票')), findsOneWidget);
      expect(buyerRow(tester, '原购票人').value, isTrue);
      expect(f.runtime.lookups, ['101', '101', '101']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only unsent tasks can be edited and dispatched with the revised account and selection',
    (tester) async {
      final f = await openTasks(tester);
      expect(editButton('sent-false'), findsNothing);
      expect(editButton('sent-true'), findsNothing);
      await tapVisible(tester, editButton('draft'));
      expect(find.text('编辑抢票任务'), findsOneWidget);
      expect(f.runtime.lookups, ['101']);
      expect(inEditor(find.text('晚场普通票')), findsOneWidget);
      expect(buyerRow(tester, '原购票人').value, isTrue);
      expect(buyerRow(tester, '其他购票人').value, isFalse);
      expect(inEditor(find.text('2026-12-01 21:13:52')), findsOneWidget);
      final interval = input('抢票请求间隔（毫秒）');
      expect(tester.widget<TextField>(interval).controller!.text, '725');
      for (final name in ['任务名称', '演出 ID 或会员购链接', '联系人（必填）', '联系电话（必填）']) {
        expect(input(name), findsNothing);
      }
      expect(inEditor(find.text('重新选择演出')), findsNothing);
      expect(
        inEditor(find.byType(DropdownButtonFormField<int>)).evaluate().where(
          (e) =>
              (e.widget as DropdownButtonFormField<int>).decoration.labelText ==
              '收货地址',
        ),
        isEmpty,
      );

      await choose<String>(tester, '使用账号', '账号乙');
      expect(f.runtime.lookups, ['101', '202']);
      expect(inEditor(find.text('原购票人')), findsNothing);
      expect(buyerRow(tester, '新购票人').value, isFalse);
      await choose<int>(tester, '场次 / 票档', '午场普通票');
      await tapVisible(tester, inEditor(find.text('新购票人')));
      await tapVisible(tester, inEditor(find.byTooltip('清除开售时间')));
      await tester.enterText(interval, '650');
      await tapVisible(tester, find.text('保存修改'));
      expect(find.byType(TaskDialog), findsNothing);
      final task = f.store.state.tasks.firstWhere((t) => t.id == 'draft');
      expect(f.store.state.tasks, hasLength(3));
      expect(task.name, '原任务名称');
      expect(task.accountId, 'b');
      expect(task.summary!.screenName, '午场');
      expect(task.summary!.quantity, 1);
      expect(task.startAt, isEmpty);
      expect(task.requestIntervalMs, 650);
      expect(await f.c.dispatch(task, [machine('worker')]), isEmpty);
      final sent = f.gateway.submitted['worker']!;
      final config = jsonDecode(sent.configJson) as Map;
      expect(
        jsonDecode(sent.cookieJson),
        jsonDecode(f.store.secrets['account.b']!),
      );
      expect(config['sku_id'], 201);
      expect(config['buyer_info'], [newBuyer]);
      expect(config['deliver_info']['addr_id'], 26);
      expect(config['buyer'], contact);
      expect(config['tel'], phone);
      expect(config.containsKey('cookies'), isFalse);
      expect(sent.timeStart, '');
      expect(sent.requestIntervalMs, 650);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed validation keeps the editable draft, closing discards changes',
    (tester) async {
      final f = await openTasks(tester);
      final original = f.store.state.tasks.first.toJson();
      final originalConfig = f.store.secrets['task.draft'];
      await tapVisible(tester, editButton('draft'));
      await tester.enterText(input('抢票请求间隔（毫秒）'), '850');
      f.runtime.acceptConfig = false;
      await tapVisible(tester, find.text('保存修改'));
      expect(inEditor(find.textContaining('模拟校验失败')), findsOneWidget);
      expect(f.store.state.tasks.first.toJson(), original);
      expect(f.store.secrets['task.draft'], originalConfig);
      expect(f.runtime.selections.single['buyer_indices'], [1]);
      expect(f.runtime.selections.single['address_index'], 1);
      await tapVisible(tester, inEditor(find.text('关闭')));
      expect(find.byType(TaskDialog), findsNothing);
      await tapVisible(tester, editButton('draft'));
      expect(
        tester.widget<TextField>(input('抢票请求间隔（毫秒）')).controller!.text,
        '725',
      );
      expect(buyerRow(tester, '原购票人').value, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
