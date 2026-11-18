import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/task_edit_selection.dart';

void main() {
  final task = TicketTask(id: 'task', name: '演出', accountId: 'a');
  final selection = TaskEditSelection(task, {
    'project_id': 10,
    'screen_id': 20,
    'sku_id': 30,
    'link_id': 40,
    'deliver_info': {'addr_id': 3},
  });

  test(
    'ticket selection identifies the child project, link, screen and SKU',
    () {
      final exact = {
        'project_id': 10,
        'screen_id': 20,
        'id': 30,
        'link_id': 40,
      };
      final options = [
        {...exact, 'project_id': 11},
        {...exact, 'screen_id': 21},
        {...exact, 'id': 31},
        {...exact, 'link_id': 41},
        exact,
      ];
      expect(selection.ticketIndex(options, 1, null), 4);
      expect(selection.ticketIndex([...options, exact], 1, null), -1);
      expect(selection.projectId, isEmpty);
    },
  );

  test(
    'buyers with the same name are restored by identity after reordering',
    () {
      final first = {'id': '1', 'name': '同名'};
      final second = {'id': 2, 'name': '同名'};
      expect(TaskEditSelection.matchBuyers([second, first], [first]), {1});
      expect(TaskEditSelection.matchBuyers([second], [first]), isEmpty);
      expect(TaskEditSelection.matchBuyers([first, first], [first]), isEmpty);
      final masked = {'personal_id': '1234**********5678', 'name': '同名'};
      expect(TaskEditSelection.matchBuyers([masked], [masked]), isEmpty);
    },
  );

  test('an account change uses a unique default or a single address', () {
    final original = {'id': 3};
    final preferred = {'id': 4, 'is_default': 1};
    final other = {'id': 5};
    expect(selection.addressIndex([preferred, original], 'a'), 1);
    expect(selection.addressIndex([preferred], 'a'), -1);
    expect(selection.addressIndex([original, preferred], 'b'), 1);
    expect(selection.addressIndex([other], 'b'), 0);
    expect(selection.addressIndex([original, other], 'b'), -1);
    expect(
      selection.addressIndex([
        preferred,
        {...preferred, 'id': 6},
      ], 'b'),
      -1,
    );
  });
}
