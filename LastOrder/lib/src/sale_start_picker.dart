import 'package:material_ui/material_ui.dart';

/// Work with the Beijing wall-clock components throughout. Device time-zone
/// conversions (including daylight-saving rules) must not move a selection.
Future<String?> showSaleStartPicker(BuildContext context, String startAt) {
  final beijingNow = DateTime.now().toUtc().add(const Duration(hours: 8));
  final initial = startAt.isEmpty ? beijingNow : DateTime.parse('${startAt}Z');
  var date = initial;
  var hour = initial.hour;
  var minute = initial.minute;
  var second = startAt.isEmpty ? 0 : initial.second;

  return showDialog<String>(
    context: context,
    builder: (context) => Localizations.override(
      context: context,
      locale: const Locale('zh'),
      delegates: GlobalMaterialLocalizations.delegates,
      child: AlertDialog(
        title: const Text('选择开售时间（北京时间）'),
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Whole-pixel month pages avoid cumulative scroll offset errors
              // across the protocol's four-digit year range.
              FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: (MediaQuery.sizeOf(context).width - 48)
                      .clamp(0, 360)
                      .floorToDouble(),
                  child: CalendarDatePicker(
                    initialDate: initial,
                    currentDate: beijingNow,
                    firstDate: DateTime(0),
                    lastDate: DateTime(9999, 12, 31),
                    onDateChanged: (value) => date = value,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  _timeUnit('时', hour, 24, (value) => hour = value),
                  _timeUnit('分', minute, 60, (value) => minute = value),
                  _timeUnit('秒', second, 60, (value) => second = value),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final selected = DateTime.utc(
                date.year,
                date.month,
                date.day,
                hour,
                minute,
                second,
              );
              Navigator.pop(
                context,
                selected.toIso8601String().split('.').first,
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

Widget _timeUnit(
  String label,
  int value,
  int count,
  ValueChanged<int> onChanged,
) => SizedBox(
  width: 88,
  child: DropdownButtonFormField<int>(
    initialValue: value,
    isExpanded: true,
    menuMaxHeight: 288,
    decoration: InputDecoration(labelText: label),
    items: [
      for (var i = 0; i < count; i++)
        DropdownMenuItem(value: i, child: Text(i.toString().padLeft(2, '0'))),
    ],
    onChanged: (selected) => onChanged(selected!),
  ),
);
