import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

const contactName = '联系人（必填）';
const contactPhone = '联系电话（必填）';
// Buyer rows show the trimmed name followed by the document type.
const firstRow = '购票人甲（身份证）';
const secondRow = '购票人乙（护照）';
const noPhoneRow = '无电话购票人（身份证）';
const hiddenPhoneRow = '隐藏号码购票人（身份证）';

Finder input(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

/// The contact fields' current text, as (name, phone).
(String, String) contact(WidgetTester tester) => (
  tester.widget<TextField>(input(contactName)).controller!.text,
  tester.widget<TextField>(input(contactPhone)).controller!.text,
);

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> type(WidgetTester tester, String label, String text) async {
  await tester.ensureVisible(input(label));
  await tester.enterText(input(label), text);
  await tester.pumpAndSettle();
}

/// Opens a new task form at phone width with large text and reads a show
/// whose buyers have full, missing and partly hidden phone numbers.
Future<FakeRuntime> openNewTask(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.6;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final runtime = FakeRuntime()
    ..responses['purchase_context'] = {
      'project_name': '测试演出',
      'ticket_options': [
        {'display': '测试票档'},
      ],
      'buyers': [
        {'id': 1, 'name': ' 购票人甲 ', 'tel': ' 13800000001 ', 'id_type': 0},
        {'id': 2, 'name': '购票人乙', 'tel': '13800000002', 'id_type': 1},
        {'id': 3, 'name': '无电话购票人', 'id_type': 0},
        {'id': 4, 'name': '隐藏号码购票人', 'tel': '138****0004', 'id_type': 0},
      ],
      'addresses': [
        {'name': '测试地址', 'city': '测试城市'},
      ],
    }
    ..responses['build_config'] = {
      'ticket': {'id': 1},
    };
  final c = controller(runtime: runtime);
  await c.initialize(poll: false);
  await c.addAccount('测试账号', [
    {'name': 'session', 'value': 'synthetic'},
  ], uid: '123');
  addTearDown(c.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => TaskDialog(controller: c),
            ),
            child: const Text('新任务'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('新任务'));
  await tester.pumpAndSettle();
  await type(tester, '演出 ID 或会员购链接', '1234');
  await tapVisible(tester, find.text('读取演出与购票人'));
  return runtime;
}

void main() {
  test('a buyer suggests its trimmed name and full phone as the contact', () {
    expect(buyerContact({'name': ' 张三 ', 'tel': ' 13800000000 '}), (
      name: '张三',
      tel: '13800000000',
    ));
    // Names are copied as written, including the middle dot in names such as
    // 迪丽热巴·迪力木拉提; only phones are checked for hidden digits.
    expect(buyerContact({'name': '迪丽热巴·迪力木拉提', 'tel': '13800000000'}), (
      name: '迪丽热巴·迪力木拉提',
      tel: '13800000000',
    ));
    expect(buyerContact({'name': '张三'}), (name: '张三', tel: ''));
    expect(buyerContact({'name': 7, 'tel': 13800000000}), (name: '', tel: ''));
    expect(buyerContact('not a buyer'), (name: '', tel: ''));
    expect(buyerContact(null), (name: '', tel: ''));
    for (final hidden in [
      '138****0000',
      '138＊＊＊＊0000',
      '138••••0000',
      '138●●●●0000',
      '138xxxx0000',
      '138…0000',
    ]) {
      expect(buyerContact({'name': '张三', 'tel': hidden}), (
        name: '张三',
        tel: '',
      ), reason: hidden);
    }
  });

  testWidgets(
    'the first checked buyer fills a blank contact that later buyers keep',
    (tester) async {
      final runtime = await openNewTask(tester);
      expect(contact(tester), ('', ''));

      await tapVisible(tester, find.text(firstRow));
      expect(contact(tester), ('购票人甲', '13800000001'));

      // Both fields now have text, so another buyer changes nothing, and
      // unchecking the buyer that filled them does not clear them either.
      await tapVisible(tester, find.text(secondRow));
      await tapVisible(tester, find.text(firstRow));
      expect(contact(tester), ('购票人甲', '13800000001'));

      // The filled contact stays an ordinary editable field.
      await type(tester, contactPhone, '13900000000');
      await tapVisible(tester, find.text('保存任务'));

      expect(find.byType(TaskDialog), findsNothing);
      final request = runtime.parameters[runtime.calls.indexOf('build_config')];
      final selection = request['selection'] as Map;
      expect(selection['buyer_indices'], [1]);
      expect(selection['buyer'], '购票人甲');
      expect(selection['tel'], '13900000000');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('checked buyers never replace contact text already entered', (
    tester,
  ) async {
    await openNewTask(tester);

    // A name alone keeps the phone blank rather than pairing the name with
    // another person's number.
    await type(tester, contactName, '自填联系人');
    await tapVisible(tester, find.text(firstRow));
    expect(contact(tester), ('自填联系人', ''));

    // A phone alone is kept as well.
    await type(tester, contactName, '');
    await type(tester, contactPhone, '13700000000');
    await tapVisible(tester, find.text(secondRow));
    expect(contact(tester), ('', '13700000000'));

    // Whitespace counts as blank. Unchecking never fills, and the next buyer
    // checked fills both fields again.
    await type(tester, contactPhone, '  ');
    await tapVisible(tester, find.text(secondRow));
    expect(contact(tester), ('', '  '));
    await tapVisible(tester, find.text(secondRow));
    expect(contact(tester), ('购票人乙', '13800000002'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a buyer without a usable phone fills only the name', (
    tester,
  ) async {
    final runtime = await openNewTask(tester);

    await tapVisible(tester, find.text(hiddenPhoneRow));
    expect(contact(tester), ('隐藏号码购票人', ''));
    // The name now counts as entered, so a buyer with a full number adds
    // nothing, and the missing phone still blocks saving.
    await tapVisible(tester, find.text(firstRow));
    expect(contact(tester), ('隐藏号码购票人', ''));
    await tapVisible(tester, find.text('保存任务'));
    expect(find.text('联系人和联系电话为必填项。'), findsOneWidget);
    expect(runtime.calls, isNot(contains('build_config')));

    await type(tester, contactName, '');
    await tapVisible(tester, find.text(noPhoneRow));
    expect(contact(tester), ('无电话购票人', ''));
    expect(tester.takeException(), isNull);
  });
}
