import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'models.dart';

class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key, required this.controller, this.account});
  final AppController controller;
  final Account? account;

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 2);
  final _cookie = TextEditingController();
  Timer? _timer;
  Uint8List? _qr;
  String? _qrKey, _error;
  String _status = '正在生成登录二维码…';
  Map<String, dynamic>? _candidate;
  int _session = 0, _networkFailures = 0;
  bool _manual = false, _foreground = true, _inFlight = false;
  bool _needsQr = true, _polling = false, _holdingChecks = false;
  bool _saving = false, _saveFailed = false, _canRetryPoll = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _holdChecks(true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _continueFlow());
  }

  void _holdChecks(bool hold) {
    if (hold == _holdingChecks) return;
    _holdingChecks = hold;
    if (hold) {
      widget.controller.holdRoutineAccountChecks();
    } else {
      widget.controller.releaseRoutineAccountChecks();
    }
  }

  bool _current(int session) => mounted && !_closed && session == _session;

  // A lifecycle pause preserves the session, including a successful response
  // which may only be available once. Explicit dismissal/replacement abandons it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _timer?.cancel();
      _timer = null;
    } else {
      _continueFlow(immediate: true);
    }
  }

  void _abandon() {
    _session++;
    _timer?.cancel();
    _timer = null;
    _candidate = null;
    _saveFailed = false;
    _needsQr = false;
    _polling = false;
    _canRetryPoll = false;
    _networkFailures = 0;
    _qr = null;
    _qrKey = null;
    _holdChecks(false);
    // Keep _inFlight until its Future settles, even if its session is obsolete.
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _abandon();
    _cookie.dispose();
    super.dispose();
  }

  void _continueFlow({bool immediate = false}) {
    if (!mounted || _closed || !_foreground || _inFlight || _saving) return;
    if (_candidate != null && !_saveFailed) {
      unawaited(_saveCandidate());
    } else if (!_manual && _needsQr) {
      unawaited(_generateQr());
    } else if (!_manual && _polling && _timer == null) {
      if (immediate) {
        unawaited(_checkQr());
      } else {
        _schedulePoll(_pollInterval);
      }
    }
  }

  void _schedulePoll(Duration delay) {
    if (!_foreground || !_polling || _manual || _closed) return;
    final session = _session;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      if (_current(session) && _foreground && !_inFlight) {
        unawaited(_checkQr());
      }
    });
  }

  void _stopPolling() {
    _polling = false;
    _timer?.cancel();
    _timer = null;
    _holdChecks(false);
  }

  void _regenerate() {
    if (_saving) return;
    // Keep the hold throughout replacement so a routine scan cannot slip in.
    _session++;
    _timer?.cancel();
    _timer = null;
    _candidate = null;
    _saveFailed = false;
    _polling = false;
    _canRetryPoll = false;
    _networkFailures = 0;
    _qr = null;
    _qrKey = null;
    _needsQr = true;
    _holdChecks(true);
    setState(() {
      _error = null;
      _status = '正在生成登录二维码…';
    });
    _continueFlow();
  }

  Future<void> _generateQr() async {
    final session = _session;
    _needsQr = false;
    setState(() => _inFlight = true);
    try {
      final result = await widget.controller.runtime.call('qr_start', {});
      if (!_current(session)) return;
      final key = result['qrcode_key'];
      final encoded = result['qr_png_base64'];
      if (key is! String ||
          key.isEmpty ||
          key.length > 2048 ||
          encoded is! String ||
          encoded.isEmpty) {
        throw const UserError('登录二维码不完整，请重新生成。');
      }
      final bytes = base64Decode(encoded);
      if (bytes.isEmpty) throw const UserError('登录二维码不完整，请重新生成。');
      setState(() {
        _qrKey = key;
        _qr = bytes;
        _polling = true;
        _status = '请使用手机客户端扫码并确认，完成后将自动登录。';
      });
    } catch (e) {
      if (_current(session)) {
        _stopPolling();
        setState(() {
          _status = '二维码生成失败，请重试。';
          _error = readableError(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _inFlight = false);
        _continueFlow();
      }
    }
  }

  Future<void> _checkQr() async {
    final session = _session;
    final key = _qrKey;
    if (key == null || !_polling || !_foreground || _inFlight) return;
    _inFlight = true;
    try {
      final result = await widget.controller.runtime.call('qr_poll', {
        'qrcode_key': key,
      });
      if (!_current(session)) return;
      switch (result['status']) {
        case 'pending':
        case 'scanned':
          _networkFailures = 0;
          setState(() {
            _error = null;
            _status = result['status'] == 'scanned'
                ? '已扫码，请在手机客户端确认登录。'
                : '请使用手机客户端扫码并确认，完成后将自动登录。';
          });
        case 'confirmed':
          // Runtime has already verified this new credential and its UID.
          // Do not re-poll or revalidate after a pause or a storage failure.
          _polling = false;
          _acceptCandidate(result);
        case 'expired':
          _stopPolling();
          setState(() {
            _error = null;
            _status = '二维码已失效，请重新生成。';
          });
        case 'transient_error':
          _networkFailures++;
          if (_networkFailures >= 3) {
            _stopPolling();
            _canRetryPoll = true;
          }
          setState(() {
            _error = null;
            _status = _canRetryPoll
                ? '暂时无法连接登录服务，自动检测已暂停，请重试。'
                : '暂时无法连接登录服务，稍后自动重试…';
          });
        default:
          _stopPolling();
          setState(() {
            _status = '登录未完成，请重新生成二维码。';
            // Only runtime's fixed, sanitized messages cross this boundary.
            _error = result['status'] == 'failed' && result['message'] is String
                ? result['message'] as String
                : '登录服务返回了无法识别的状态，请重新扫码。';
          });
      }
    } catch (e) {
      if (_current(session)) {
        // A native timeout does not cancel Python. Do not automatically enqueue
        // another operation on installation/protocol/native transport failures.
        _stopPolling();
        setState(() {
          _status = '自动检测已停止，请重新生成二维码。';
          _error = readableError(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _inFlight = false);
        if (_current(session) && _polling && _networkFailures > 0) {
          _schedulePoll(Duration(seconds: _networkFailures == 1 ? 4 : 8));
        }
        _continueFlow();
      }
    }
  }

  void _acceptCandidate(Map<String, dynamic> result) {
    final uid = result['uid'];
    final cookies = result['cookies'];
    if (uid is! String ||
        !Account.isValidUid(uid) ||
        cookies is! List ||
        cookies.isEmpty) {
      throw const UserError('登录结果未包含有效 Cookie 或账号身份，请重新登录。');
    }
    if (widget.account case final Account account) {
      if (uid != account.uid) {
        throw const UserError('本次登录的账号与原账号 UID 不一致，原账号及任务保持不变。请登录原账号。');
      }
    }
    setState(() {
      _candidate = result;
      _error = null;
      _status = '登录已确认，正在保存账号…';
    });
  }

  Future<void> _saveCandidate() async {
    final result = _candidate;
    if (result == null || !_foreground || _saving || _closed) return;
    setState(() => _saving = true);
    try {
      final name = (result['username'] ?? '').toString();
      final cookies = result['cookies'] as List;
      final uid = result['uid'] as String;
      if (widget.account case final Account account) {
        await widget.controller.refreshAccount(
          account,
          name: name,
          cookies: cookies,
          uid: uid,
        );
      } else {
        await widget.controller.addAccount(name, cookies, uid: uid);
      }
      _candidate = null;
      // Allow PopScope to observe the committed state before closing the route.
      if (mounted) {
        setState(() => _saving = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_closed) _close();
        });
      }
    } catch (e) {
      if (mounted) {
        _holdChecks(false);
        setState(() {
          _saveFailed = true;
          _error = readableError(e);
          _status = '账号未能保存，请重试保存或重新登录。';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _retrySave() {
    setState(() => _saveFailed = false);
    _continueFlow();
  }

  void _retryPoll() {
    _networkFailures = 0;
    _canRetryPoll = false;
    _polling = true;
    _holdChecks(true);
    setState(() {
      _error = null;
      _status = '正在恢复自动检测…';
    });
    _continueFlow(immediate: true);
  }

  void _switchMode(bool manual) {
    _abandon();
    setState(() {
      _manual = manual;
      _error = null;
    });
    if (!manual) _regenerate();
  }

  Future<void> _submitCookie() async {
    final session = _session;
    setState(() {
      _inFlight = true;
      _error = null;
    });
    try {
      dynamic value;
      try {
        value = jsonDecode(_cookie.text);
      } catch (_) {
        throw const UserError(
          '请输入 JSON Cookie 数组，例如 [{"name":"…","value":"…"}]。',
        );
      }
      if (value is! List) throw const UserError('Cookie 必须为 JSON 数组。');
      final result = await widget.controller.runtime.call('login_cookie', {
        'cookies': value,
      });
      if (!_current(session)) return;
      if (result['status'] != 'valid' || result['logged_in'] != true) {
        throw UserError(
          result['status'] == 'expired'
              ? 'Cookie 已失效，请使用手机客户端重新扫码登录。'
              : '暂时无法验证登录状态，请检查网络后重试。尚未保存此 Cookie。',
        );
      }
      _acceptCandidate(result);
    } catch (e) {
      if (_current(session)) setState(() => _error = readableError(e));
    } finally {
      if (mounted) {
        setState(() => _inFlight = false);
        _continueFlow();
      }
    }
  }

  void _close() {
    if (_saving) return;
    _closed = true;
    _abandon();
    Navigator.pop(context);
  }

  Widget _qrImage() {
    final session = _session;
    return Image.memory(
      _qr!,
      width: 220,
      height: 220,
      errorBuilder: (_, error, stack) {
        // Image callbacks can arrive after a replacement. Never stop its new
        // session, and never mutate the dialog while Flutter is building it.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_current(session) || _saving) return;
          _session++;
          _stopPolling();
          setState(() {
            _qr = null;
            _qrKey = null;
            _candidate = null;
            _canRetryPoll = false;
            _saveFailed = false;
            _error = null;
            _status = '二维码无法显示，请重新生成。';
          });
        });
        return const Text('二维码无法显示，请重新生成。');
      },
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) {
        _closed = true;
        _abandon();
      }
    },
    child: AlertDialog(
      title: Text(widget.account == null ? '登录哔哩哔哩' : '重新登录账号'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.account case final Account account) ...[
                Text('请使用「${account.name}」原账号扫码。登录成功后更新 Cookie，保留已有任务与场次选择。'),
                const SizedBox(height: 8),
                const Text('更新后不会自动启动任务；已分发到 Sisters 的执行不会被替换。'),
                const SizedBox(height: 12),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('使用已有 Cookie'),
                value: _manual,
                onChanged: _saving ? null : _switchMode,
              ),
              if (_manual) ...[
                const Text(
                  '仅接受 biliTickerBuy 兼容的 Cookie JSON 数组。验证成功后保存至系统安全存储。',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _cookie,
                  decoration: const InputDecoration(labelText: 'Cookie JSON'),
                  maxLines: 6,
                  autocorrect: false,
                  enableSuggestions: false,
                  enabled: !_saving && _candidate == null,
                ),
              ] else ...[
                Semantics(liveRegion: true, child: Text(_status)),
                const SizedBox(height: 20),
                if (_qr != null) Center(child: _qrImage()),
                if (_canRetryPoll)
                  Center(
                    child: TextButton(
                      onPressed: _saving ? null : _retryPoll,
                      child: const Text('重试连接'),
                    ),
                  ),
                Center(
                  child: TextButton(
                    onPressed: _saving || _needsQr ? null : _regenerate,
                    child: const Text('重新生成二维码'),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '登录凭据不会写入普通配置文件。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (_saving || _manual && _inFlight)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        TextButton(onPressed: _saving ? null : _close, child: const Text('关闭')),
        if (_saveFailed)
          FilledButton(
            onPressed: _saving ? null : _retrySave,
            child: const Text('重试保存'),
          ),
        if (_manual && _candidate == null)
          FilledButton(
            onPressed: _saving || _inFlight ? null : _submitCookie,
            child: const Text('验证并保存'),
          ),
      ],
    ),
  );
}
