import 'models.dart';

// Only retained in memory while editing. IDs refer to records in the runtime's
// purchase context, never to their current positions in the returned lists.
class TaskEditSelection {
  TaskEditSelection(this.task, this.config);

  final TicketTask task;
  final Map<String, dynamic> config;

  static String _id(Object? value) =>
      value is int || value is String ? value.toString().trim() : '';

  String get projectId {
    final root = task.summary?.projectId ?? '';
    if (root.isNotEmpty) return root;
    // An associated ticket stores its child project in the order payload.
    return _id(config['link_id']).isEmpty ? _id(config['project_id']) : '';
  }

  bool confirmsLinkedProject(Map<String, dynamic> context) {
    final link = _id(config['link_id']);
    final child = _id(config['project_id']);
    return link.isNotEmpty &&
        child.isNotEmpty &&
        (context['ticket_options'] as List? ?? []).whereType<Map>().any(
          (option) =>
              _id(option['link_id']) == link &&
              _id(option['project_id']) == child,
        );
  }

  int ticketIndex(List options, Object? projectId, Map? previous) {
    final sku = _id(previous == null ? config['sku_id'] : previous['id']);
    final screen = _id((previous ?? config)['screen_id']);
    final child = _id(
      previous == null
          ? config['project_id']
          : previous['project_id'] ?? projectId,
    );
    if (sku.isEmpty || screen.isEmpty || child.isEmpty) return -1;
    return _uniqueIndex(
      options,
      (option) =>
          _id(option['id']) == sku &&
          _id(option['screen_id']) == screen &&
          _id(option['project_id'] ?? projectId) == child &&
          _id(option['link_id']) == _id((previous ?? config)['link_id']),
    );
  }

  static int _uniqueIndex(List items, bool Function(Map) matches) {
    var found = -1;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is Map && matches(item)) {
        if (found != -1) return -1;
        found = i;
      }
    }
    return found;
  }

  static Set<int> matchBuyers(List people, List previous) {
    final matches = <int>{};
    for (final selected in previous) {
      if (selected is! Map) return {};
      final id = _id(selected['id']);
      final personalId = _id(selected['personal_id']);
      final completeIdentity =
          personalId.isNotEmpty &&
          !RegExp(r'[*＊•●·…]|[xX]{3,}').hasMatch(personalId) &&
          selected['name'] is String &&
          (selected['name'] as String).trim().isNotEmpty;
      final index = _uniqueIndex(people, (person) {
        if (id.isNotEmpty && id != '0' && _id(person['id']).isNotEmpty) {
          return _id(person['id']) == id;
        }
        return completeIdentity &&
            _id(person['personal_id']) == personalId &&
            person['name'] == selected['name'];
      });
      if (index == -1 || !matches.add(index)) return {};
    }
    return matches;
  }

  int addressIndex(List addresses, String accountId) {
    if (accountId == task.accountId) {
      final address = config['deliver_info'];
      final id = address is Map ? _id(address['addr_id']) : '';
      if (id.isEmpty) return -1;
      return _uniqueIndex(addresses, (item) => _id(item['id']) == id);
    }
    if (addresses.length == 1) return 0;
    return _uniqueIndex(addresses, (item) {
      final flag = item['is_default'] ?? item['isDefault'] ?? item['def'];
      return flag == true || flag == 1 || flag == '1';
    });
  }
}
