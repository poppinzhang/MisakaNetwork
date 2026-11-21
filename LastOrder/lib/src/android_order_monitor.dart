import 'dart:async';

import 'package:flutter/services.dart';

const _channel = MethodChannel('misaka/notifications');

Future<bool> setNativeAndroidBackgroundMonitoring(bool enabled) async {
  final active = await _channel.invokeMethod<bool>(
    'setBackgroundMonitoring',
    enabled,
  );
  if (active == null) throw StateError('Missing Android service status');
  return active;
}

/// Serializes foreground service changes while dispatch, settings, and Android
/// lifecycle updates arrive independently. The service must start while visible.
class AndroidOrderMonitor {
  AndroidOrderMonitor(this._setActive, this._changed);

  final Future<bool> Function(bool) _setActive;
  final void Function() _changed;
  bool wanted = false;
  bool _visible = false;
  bool _updating = false;
  bool? _lastRequest = false;
  String? error;

  void update({required bool wanted, bool? visible}) {
    this.wanted = wanted;
    if (visible != null) {
      // The OS can stop a service independently (for example, a dataSync
      // timeout). Reconcile once when returning from the background.
      if (visible && !_visible && (wanted || error != null)) {
        _lastRequest = null;
      }
      _visible = visible;
    }
    if (!_updating && _lastRequest != wanted && (!wanted || _visible)) {
      unawaited(_reconcile());
    }
  }

  Future<void> _reconcile() async {
    _updating = true;
    try {
      while (_lastRequest != wanted && (!wanted || _visible)) {
        final requested = wanted;
        _lastRequest = requested;
        bool applied;
        try {
          applied = await _setActive(requested) == requested;
        } catch (_) {
          applied = false;
        }
        if (wanted != requested) continue;
        final previous = error;
        error = applied
            ? null
            : requested
            ? 'Android 暂未允许后台监控。请检查系统通知权限，并在抢票期间重新打开 LastOrder。'
            : '暂时无法确认后台监控已停止，请重新打开 LastOrder 核对。';
        if (error != previous) _changed();
      }
    } finally {
      _updating = false;
    }
  }
}
