import 'package:flutter_animate/flutter_animate.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../generated/misaka/v1/sisters.pb.dart';

/// A short, automatically advancing window of user-facing Sisters messages.
class TaskMessages extends StatefulWidget {
  const TaskMessages({super.key, required this.status});

  final TaskStatus status;

  @override
  State<TaskMessages> createState() => _TaskMessagesState();
}

class _TaskMessagesState extends State<TaskMessages> {
  bool _expanded = false;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_restored) {
      _expanded = PageStorage.maybeOf(context)?.readState(context) == true;
      _restored = true;
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final messages = _messages(widget.status);
    final count = _expanded ? 3 : 1;
    final visible = messages.length > count
        ? messages.sublist(messages.length - count)
        : messages;
    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (visible.isEmpty)
          Text(
            '等待执行信息',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        for (var i = 0; i < visible.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i + 1 < visible.length ? 10 : 0),
            child: Semantics(
              liveRegion: i == visible.length - 1,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (visible[i].timestamp case final int timestamp) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        _time(timestamp),
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 10,
                          height: 1.45,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      visible[i].text,
                      style: TextStyle(
                        color: i == visible.length - 1
                            ? colors.onSurface
                            : colors.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
    if (!MediaQuery.disableAnimationsOf(context)) {
      // Stable identity avoids replaying the animation on unchanged polling
      // responses. A countdown change animates once, without adding a row.
      final signature = visible
          .map((m) => '${m.text.length}:${m.text}')
          .join('|');
      content = content
          .animate(key: ValueKey(signature))
          .fade(begin: .65, end: 1, duration: 180.ms)
          .moveY(begin: 6, end: 0, duration: 180.ms, curve: Curves.easeOut);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Text(
              'Sisters 回报',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (messages.length > 1)
              TextButton.icon(
                onPressed: _toggle,
                icon: Icon(
                  _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  size: 15,
                ),
                label: Text(_expanded ? '收起消息' : '展开消息'),
                style: TextButton.styleFrom(
                  textStyle: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(fontSize: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(12),
          ),
          child: content,
        ),
      ],
    );
  }
}

class _Message {
  const _Message(this.text, this.timestamp);

  final String text;
  final int? timestamp;
}

int? _timestamp(int value) =>
    value > 0 && value <= 8640000000000000 ? value : null;

List<_Message> _messages(TaskStatus status) {
  final events = [
    for (final event in status.events)
      if (event.message.trim().isNotEmpty)
        _Message(
          event.message.trim(),
          _timestamp(event.timestampUnixMs.toInt()),
        ),
  ];
  // Sort meaningful event times, preserving source order for ties and messages
  // without a timestamp. Untimed events precede dated events.
  final ordered = events.indexed.toList()
    ..sort((a, b) {
      final time = (a.$2.timestamp ?? 0).compareTo(b.$2.timestamp ?? 0);
      return time == 0 ? a.$1.compareTo(b.$1) : time;
    });
  final result = ordered.map((entry) => entry.$2).toList();
  final text = status.message.trim();
  if (text.isNotEmpty) {
    final timestamp = _timestamp(status.updatedUnixMs.toInt());
    final sameTime = timestamp == null
        ? -1
        : result.lastIndexWhere((event) => event.timestamp == timestamp);
    if (sameTime >= 0) {
      // Sisters keeps the stage event's timestamp while updating status.message
      // with a live countdown. Replace that event instead of duplicating it.
      result[sameTime] = _Message(text, timestamp);
    } else if (timestamp != null) {
      final next = result.indexWhere(
        (event) => event.timestamp != null && event.timestamp! > timestamp,
      );
      result.insert(next < 0 ? result.length : next, _Message(text, timestamp));
    } else if (result.isEmpty || result.last.text != text) {
      // An untimed current snapshot still supplies the latest text, but zero
      // timestamps must never merge unrelated messages.
      result.add(_Message(text, null));
    }
  }
  final distinct = <_Message>[];
  for (final message in result) {
    if (distinct.isNotEmpty && distinct.last.text == message.text) {
      distinct[distinct.length - 1] = message;
    } else {
      distinct.add(message);
    }
  }
  return distinct;
}

String _time(int timestamp) {
  final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
