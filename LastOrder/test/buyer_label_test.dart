import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

Finder input(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  test('buyer document types use the platform id_type names', () {
    expect(
      [for (var code = 0; code <= 4; code++) buyerIdTypeName(code)],
      ['身份证', '护照', '港澳居民来往内地通行证', '台湾居民来往大陆通行证', '外国人永久居留身份证'],
    );
    expect(buyerIdTypeName(' 3 '), '台湾居民来往大陆通行证');
    for (final unknown in <Object?>[
      null,
      5,
      -1,
      '',
      '-1',
      '0x1',
      '99999999999999999999',
      '护照',
      true,
    ]) {
      expect(buyerIdTypeName(unknown), '证件类型未知', reason: '$unknown');
    }
  });

  test('buyer labels append the document type to the name', () {
    expect(buyerLabel({'name': ' 张三 ', 'id_type': 1}, 0), '张三（护照）');
    expect(buyerLabel({'name': '', 'id_type': 0}, 2), '购票人 3（身份证）');
    expect(buyerLabel({'name': 7, 'id_type': '2'}, 0), '购票人 1（港澳居民来往内地通行证）');
    expect(buyerLabel({'name': '张三'}, 0), '张三（证件类型未知）');
    expect(buyerLabel('not a buyer', 1), '购票人 2（证件类型未知）');
  });

  testWidgets(
    'phone task form tells same-name buyers apart and submits the chosen one',
    (tester) async {
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
            {'id': 1, 'name': '同名购票人', 'id_type': 0},
            {'id': 2, 'name': '同名购票人', 'id_type': 2},
            {'id': 3, 'name': '其他购票人', 'id_type': 9},
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
          home: Scaffold(body: TaskDialog(controller: c)),
        ),
      );
      await tester.ensureVisible(input('演出 ID 或会员购链接'));
      await tester.enterText(input('演出 ID 或会员购链接'), '1234');
      await tester.tap(find.text('读取演出与购票人'));
      await tester.pumpAndSettle();

      final rows = tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      );
      expect(
        [for (final row in rows) (row.title as Text).data],
        ['同名购票人（身份证）', '同名购票人（港澳居民来往内地通行证）', '其他购票人（证件类型未知）'],
      );
      // The longest document name must wrap instead of overflowing.
      expect(tester.takeException(), isNull);

      final permitHolder = find.text('同名购票人（港澳居民来往内地通行证）');
      await tester.ensureVisible(permitHolder);
      await tester.tap(permitHolder);
      await tester.ensureVisible(input('联系人（必填）'));
      await tester.enterText(input('联系人（必填）'), '测试联系人');
      await tester.ensureVisible(input('联系电话（必填）'));
      await tester.enterText(input('联系电话（必填）'), '13800000000');
      await tester.tap(find.text('保存任务'));
      await tester.pumpAndSettle();

      final request = runtime.parameters[runtime.calls.indexOf('build_config')];
      expect((request['selection'] as Map)['buyer_indices'], [1]);
      expect(c.state.tasks.single.summary!.quantity, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
