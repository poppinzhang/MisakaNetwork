import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cloud_controller.dart';
import 'cloud_models.dart';
import 'models.dart';

class CloudProviderMark extends StatelessWidget {
  const CloudProviderMark(this.provider, {super.key, this.size = 44});
  final CloudProvider provider;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: EdgeInsets.all(size * .12),
    decoration: BoxDecoration(
      // Preserve the official artwork's colors on both app themes.
      color: Colors.white,
      borderRadius: BorderRadius.circular(size * .28),
      border: Border.all(
        color: Theme.of(context).colorScheme.outlineVariant
            .withValues(alpha: .5),
      ),
    ),
    child: Image.asset(
      'assets/cloud_providers/${provider.name}.png',
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      excludeFromSemantics: true,
    ),
  );
}

class CloudPill extends StatelessWidget {
  const CloudPill(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class CloudNotice extends StatelessWidget {
  const CloudNotice(
    this.text, {
    super.key,
    this.icon = LucideIcons.info,
    this.error = false,
  });
  final String text;
  final IconData icon;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = error ? colors.error : colors.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .065),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: error ? colors.error : colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CloudCredentialsPage extends StatefulWidget {
  const CloudCredentialsPage({
    super.key,
    required this.controller,
    this.initialProvider,
    this.onCreate,
  });
  final CloudController controller;
  final CloudProvider? initialProvider;
  final VoidCallback? onCreate;
  @override
  State<CloudCredentialsPage> createState() => _CloudCredentialsPageState();
}

class _CloudCredentialsPageState extends State<CloudCredentialsPage> {
  late CloudProvider selected = widget.initialProvider ?? CloudProvider.tencent;
  bool upcoming = false;
  @override
  void didUpdateWidget(CloudCredentialsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialProvider != oldWidget.initialProvider &&
        widget.initialProvider != null) {
      selected = widget.initialProvider!;
      upcoming = false;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'CLOUD ACCESS',
            style: TextStyle(
              color: colors.primary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '连接你的公有云',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '管理云凭证，为每一次创建做好准备。',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          const CloudNotice(
            '凭证提交后联网验证，通过后才保存。每家云厂商仅保留一份凭证。腾讯云和火山引擎支持创建和释放按量计费服务器，费用由云厂商收取。',
            icon: LucideIcons.info,
          ),
          const SizedBox(height: 24),
          if (widget.controller.startupError != null) ...[
            CloudNotice(widget.controller.startupError!, error: true),
            TextButton(
              onPressed: widget.controller.initialize,
              child: const Text('重新读取云配置'),
            ),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= 820 &&
                  MediaQuery.textScalerOf(context).scale(14) < 22;
              final providers = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '云服务商',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final provider in CloudProvider.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _providerTile(provider),
                    ),
                  Material(
                    color: upcoming
                        ? colors.secondaryContainer
                        : colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      key: const ValueKey('cloud-provider-upcoming'),
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => setState(() => upcoming = true),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.ellipsis,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '其他云厂商',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '等待接入',
                                    style: TextStyle(
                                      color: colors.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
              final form = upcoming
                  ? Container(
                      constraints: const BoxConstraints(minHeight: 330),
                      padding: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            LucideIcons.cloud,
                            size: 52,
                            color: colors.outline,
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            '更多云厂商，等待接入',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '接入后，你可以在这里管理凭证并选择配置。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              height: 1.7,
                            ),
                          ),
                        ],
                      ),
                    )
                  : CloudCredentialForm(
                      key: ValueKey(selected),
                      controller: widget.controller,
                      provider: selected,
                      onCreate: widget.onCreate,
                    );
              if (!wide) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 10,
                      children: [
                        for (final provider in CloudProvider.values)
                          ChoiceChip(
                            key: ValueKey('cloud-provider-${provider.name}'),
                            avatar: CloudProviderMark(provider, size: 24),
                            avatarBoxConstraints: const BoxConstraints.tightFor(
                              width: 24,
                              height: 24,
                            ),
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 24),
                              child: Align(
                                widthFactor: 1,
                                heightFactor: 1,
                                child: Text(provider.displayName),
                              ),
                            ),
                            selected: !upcoming && selected == provider,
                            showCheckmark: false,
                            onSelected: (_) => setState(() {
                              selected = provider;
                              upcoming = false;
                            }),
                          ),
                        ChoiceChip(
                          key: const ValueKey('cloud-provider-upcoming'),
                          label: const Text('其他 · 等待接入'),
                          selected: upcoming,
                          onSelected: (_) => setState(() => upcoming = true),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    form,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 250, child: providers),
                  const SizedBox(width: 24),
                  Expanded(child: form),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          CloudSshIdentity(controller: widget.controller),
        ],
      );
    },
  );

  Widget _providerTile(CloudProvider provider) {
    final colors = Theme.of(context).colorScheme;
    final active = !upcoming && selected == provider;
    final credential = widget.controller.credentialFor(provider);
    return Material(
      color: active
          ? colors.secondaryContainer.withValues(alpha: .6)
          : colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: active ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: InkWell(
        key: ValueKey('cloud-provider-${provider.name}'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() {
          selected = provider;
          upcoming = false;
        }),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CloudProviderMark(provider, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      provider.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      credential == null
                          ? '尚未录入凭证'
                          : credential.onlineVerified
                          ? '联网验证通过'
                          : '待联网验证',
                      style: TextStyle(
                        color: credential == null
                            ? colors.onSurfaceVariant
                            : colors.primary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (active)
                Icon(LucideIcons.chevronRight, size: 16, color: colors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class CloudCredentialForm extends StatefulWidget {
  const CloudCredentialForm({
    super.key,
    required this.controller,
    required this.provider,
    this.onCreate,
  });
  final CloudController controller;
  final CloudProvider provider;
  final VoidCallback? onCreate;
  @override
  State<CloudCredentialForm> createState() => _CloudCredentialFormState();
}

class _CloudCredentialFormState extends State<CloudCredentialForm> {
  final form = GlobalKey<FormState>();
  final keyId = TextEditingController(), secret = TextEditingController();
  bool busy = false, removing = false, reveal = false;
  String? error, saved;
  @override
  void dispose() {
    keyId.dispose();
    secret.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      removing = false;
      error = null;
      saved = null;
    });
    try {
      await widget.controller.saveCredential(
        widget.provider,
        accessKeyId: keyId.text,
        accessKeySecret: secret.text,
      );
      if (!mounted) return;
      keyId.clear();
      secret.clear();
      setState(() => saved = '联网验证通过，已安全保存。');
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    if (busy) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除云凭证'),
        content: Text(
          '从本机移除${widget.provider.displayName}凭证。尚有未释放或状态待核实的云资源时不能移除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      busy = true;
      removing = true;
      error = null;
      saved = null;
    });
    try {
      await widget.controller.removeCredential(widget.provider);
      if (mounted) {
        keyId.clear();
        secret.clear();
        setState(() {
          reveal = false;
          saved = '已从本机移除凭证。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> help() async {
    try {
      if (!await launchUrl(
        Uri.parse(widget.provider.docsUrl),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('unavailable');
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法打开官方说明，请稍后重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final credential = widget.controller.credentialFor(widget.provider);
    final canEnterCredential = credential?.onlineVerified != true;
    return Container(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 20 : 28),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CloudProviderMark(widget.provider),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${widget.provider.displayName}凭证',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        switch (widget.provider) {
                          CloudProvider.tencent => 'CAM 子用户 · API 访问密钥',
                          CloudProvider.aliyun => 'RAM 用户 · AccessKey 访问密钥',
                          CloudProvider.volcengine =>
                            'IAM 用户 · Access Key 访问密钥',
                        },
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (credential != null) ...[
              CloudNotice(
                '已保存${widget.provider.displayName}凭证 · ${credential.maskedId}\n${credential.onlineVerified ? '联网验证通过。' : '待联网验证，请重新提交验证。'}${widget.provider.supportsResources ? '仍有未释放或待核实的云资源时，不能移除凭证。' : ''}',
                icon: credential.onlineVerified
                    ? LucideIcons.shieldCheck
                    : LucideIcons.info,
              ),
              const SizedBox(height: 20),
            ],
            Text(
              credential == null
                  ? '每家云厂商只能保存一份凭证。'
                  : credential.onlineVerified
                  ? '如需更换凭证，请先移除当前凭证。'
                  : '重新提交并通过联网验证后即可使用；验证失败时保留原记录。',
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
                height: 1.6,
              ),
            ),
            if (canEnterCredential) ...[
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('cloud-key-id'),
                controller: keyId,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: widget.provider.credentialIdLabel,
                ),
                validator: (v) => CloudController.validateCredentialValue(
                  v ?? '',
                  widget.provider.credentialIdLabel,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('cloud-key-secret'),
                controller: secret,
                enabled: !busy,
                obscureText: !reveal,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: widget.provider.credentialSecretLabel,
                  suffixIcon: IconButton(
                    tooltip: reveal ? '隐藏密钥' : '显示密钥',
                    onPressed: () => setState(() => reveal = !reveal),
                    icon: Icon(
                      reveal ? LucideIcons.eyeOff : LucideIcons.eye,
                      size: 18,
                    ),
                  ),
                ),
                validator: (v) => CloudController.validateCredentialValue(
                  v ?? '',
                  widget.provider.credentialSecretLabel,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                switch (widget.provider) {
                  CloudProvider.tencent => '使用 CAM 子用户的 API 密钥，无需填写 AppID。',
                  CloudProvider.aliyun => '使用 RAM 用户的访问密钥，无需填写网页登录密码。',
                  CloudProvider.volcengine =>
                    '使用 IAM 用户的访问密钥；不是火山方舟的模型 API Key。',
                },
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: help,
                  icon: const Icon(LucideIcons.externalLink, size: 14),
                  label: const Text('查看官方凭证说明'),
                ),
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: CloudNotice(error!, error: true),
              ),
            if (saved != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: CloudNotice(saved!, icon: LucideIcons.circleCheck),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (canEnterCredential)
                  FilledButton.icon(
                    key: const ValueKey('cloud-save-credential'),
                    onPressed: busy || !widget.controller.initialized
                        ? null
                        : save,
                    icon: Icon(
                      busy ? LucideIcons.loaderCircle : LucideIcons.shieldCheck,
                      size: 17,
                    ),
                    label: Text(busy && !removing ? '正在验证并保存' : '联网验证并保存'),
                  ),
                if (credential != null)
                  OutlinedButton.icon(
                    onPressed: busy || !credential.onlineVerified
                        ? null
                        : widget.onCreate,
                    icon: const Icon(LucideIcons.plus, size: 16),
                    label: const Text('去创建云服务器'),
                  ),
                if (credential != null)
                  TextButton(
                    onPressed: busy ? null : remove,
                    child: Text(busy && removing ? '正在移除凭证' : '移除凭证'),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  LucideIcons.lockKeyhole,
                  size: 15,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '凭证保存在本机系统安全存储，不会发送给 Sisters。',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CloudSshIdentity extends StatefulWidget {
  const CloudSshIdentity({super.key, required this.controller});
  final CloudController controller;
  @override
  State<CloudSshIdentity> createState() => _CloudSshIdentityState();
}

class _CloudSshIdentityState extends State<CloudSshIdentity> {
  bool busy = false;
  Future<void> retry() async {
    setState(() => busy = true);
    try {
      await widget.controller.ensureSshIdentity();
    } catch (_) {
      /* Controller supplies a sanitized error. */
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.keyRound, color: colors.primary, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '本机 SSH 登录密钥',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      c.sshReady
                          ? '已生成并安全保存 · RSA 2048\n云服务器将使用同一份公钥，私钥始终留在本机。'
                          : c.keyError ?? '首次启动正在生成，后续会自动复用。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (c.sshReady) const CloudPill('已就绪'),
            ],
          ),
          if (c.sshReady) ...[
            const SizedBox(height: 12),
            SelectableText(
              c.sshFingerprint,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  try {
                    await Clipboard.setData(
                      ClipboardData(text: c.sshPublicKey),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制 SSH 公钥')),
                      );
                    }
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('无法复制公钥，请重试')),
                      );
                    }
                  }
                },
                icon: const Icon(LucideIcons.copy, size: 14),
                label: const Text('复制公钥'),
              ),
            ),
          ] else if (c.keyError != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: busy ? null : retry,
                child: Text(busy ? '正在准备密钥' : '重试生成密钥'),
              ),
            ),
        ],
      ),
    );
  }
}

/// The dialog returns a provider when credentials need editing, and true after
/// a cloud operation or a preview machine has been saved.
class CloudCreateDialog extends StatefulWidget {
  const CloudCreateDialog({super.key, required this.controller});
  final CloudController controller;
  @override
  State<CloudCreateDialog> createState() => _CloudCreateDialogState();
}

class _CloudCreateDialogState extends State<CloudCreateDialog> {
  CloudProvider? provider;
  CloudTemplate? selected;
  CloudPreviewOutcome outcome = CloudPreviewOutcome.success;
  bool busy = false;
  String? error;

  Future<void> create() async {
    if (provider == null || selected == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (provider?.supportsResources == true) {
        await widget.controller.startCloudCreation(provider!, selected!);
      } else {
        await widget.controller.startPreviewCreation(
          provider!,
          selected!,
          outcome: outcome,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      return PopScope(
        canPop: !busy,
        child: Dialog(
          insetPadding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 600 ? 12 : 32,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 600 ? 20 : 28,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (provider != null)
                        IconButton(
                          tooltip: '返回云厂商选择',
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  provider = null;
                                  selected = null;
                                  error = null;
                                }),
                          icon: const Icon(LucideIcons.arrowLeft, size: 20),
                        ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              provider == null ? '云服务器创建' : '选择一套内置配置',
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              provider == null
                                  ? '选择云厂商，开启新的执行节点。'
                                  : '${provider!.displayName} · ${provider!.productName}  /  02 配置选择',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭云服务器创建',
                        onPressed: busy ? null : () => Navigator.pop(context),
                        icon: const Icon(LucideIcons.x, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          CloudNotice(
                            provider?.supportsResources == true
                                ? '${provider!.displayName} · 创建真实的按量计费 ${provider!.productName}，每次创建一台。确认后开始云端创建并产生费用，关闭应用不会释放服务器。'
                                : provider == null
                                ? '支持创建腾讯云和火山引擎的按量计费服务器，费用由云厂商收取。'
                                : '交互预览 · 不会创建、部署或释放真实资源，也不会产生费用。',
                            icon:
                                provider == null || provider!.supportsResources
                                ? LucideIcons.info
                                : LucideIcons.flaskConical,
                          ),
                          const SizedBox(height: 20),
                          if (provider == null) ...[
                            for (final item in CloudProvider.values)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _providerOption(item),
                              ),
                            Container(
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: colors.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    LucideIcons.ellipsis,
                                    color: colors.outline,
                                  ),
                                  const SizedBox(width: 18),
                                  const Expanded(child: Text('其他云厂商')),
                                  Text(
                                    '等待接入',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else ...[
                            Text(
                              provider?.supportsResources == true
                                  ? '管理员配置模板'
                                  : '示例模板',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 10),
                            if (provider?.supportsResources == true &&
                                widget.controller
                                    .templatesFor(provider!)
                                    .isEmpty)
                              CloudNotice(
                                widget.controller.templateErrorFor(provider!) ??
                                    '管理员尚未配置${provider!.displayName}模板，请填写模板并重新打包应用。',
                                error:
                                    widget.controller.templateErrorFor(
                                      provider!,
                                    ) !=
                                    null,
                              ),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final horizontal =
                                    constraints.maxWidth >= 680 &&
                                    widget.controller
                                            .templatesFor(provider!)
                                            .length <=
                                        3 &&
                                    MediaQuery.textScalerOf(context).scale(14) <
                                        22;
                                final cards = [
                                  for (final template
                                      in widget.controller.templatesFor(
                                        provider!,
                                      ))
                                    _templateCard(template),
                                ];
                                if (!horizontal) {
                                  return Column(
                                    children: [
                                      for (final card in cards)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 12,
                                          ),
                                          child: card,
                                        ),
                                    ],
                                  );
                                }
                                return IntrinsicHeight(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (
                                        var i = 0;
                                        i < cards.length;
                                        i++
                                      ) ...[
                                        if (i > 0) const SizedBox(width: 12),
                                        Expanded(child: cards[i]),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 16),
                            Text(
                              provider?.supportsResources == true
                                  ? '模板由管理员维护并随应用打包。LastOrder 会自动创建并复用 VPC 和子网；释放服务器时保留共享网络。库存、权限与实际价格以${provider!.displayName}为准。'
                                  : '模板参数为界面示例，地域、机型、网络与费用将在后续确定。',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.6,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  LucideIcons.keyRound,
                                  size: 18,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    widget.controller.sshReady
                                        ? provider?.supportsResources == true
                                              ? '导入并复用本机 SSH 公钥 · RSA 2048\n创建后保留服务器记录。Sisters 需另行部署，连接身份由应用自动记录并校验。'
                                              : '自动使用本机 SSH 公钥 · RSA 2048\n创建后演示 Sisters 部署。'
                                        : '本机 SSH 登录密钥尚未就绪，请先前往公有云凭证页面完成准备。',
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.6,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (!widget.controller.sshReady)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, provider),
                                  child: const Text('前往准备 SSH 密钥'),
                                ),
                              ),
                            const SizedBox(height: 20),
                            if (provider?.supportsResources == true &&
                                selected != null)
                              switch (provider!) {
                                CloudProvider.tencent => _tencentSummary(
                                  selected!,
                                ),
                                CloudProvider.volcengine => _volcengineSummary(
                                  selected!,
                                ),
                                CloudProvider.aliyun => _aliyunSummary(
                                  selected!,
                                ),
                              },
                            if (provider?.supportsResources != true)
                              DropdownButtonFormField<CloudPreviewOutcome>(
                                key: const ValueKey('cloud-preview-outcome'),
                                initialValue: outcome,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '预览结果',
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: CloudPreviewOutcome.success,
                                    child: Text('正常创建与部署'),
                                  ),
                                  DropdownMenuItem(
                                    value: CloudPreviewOutcome.createFailure,
                                    child: Text('创建失败'),
                                  ),
                                  DropdownMenuItem(
                                    value: CloudPreviewOutcome.deployFailure,
                                    child: Text('部署失败'),
                                  ),
                                ],
                                onChanged: busy
                                    ? null
                                    : (value) =>
                                          setState(() => outcome = value!),
                              ),
                          ],
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: CloudNotice(error!, error: true),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  if (provider != null)
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '确认后回到机器列表，可继续添加其他机器。',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        FilledButton.icon(
                          key: const ValueKey('cloud-confirm-create'),
                          onPressed:
                              busy ||
                                  selected == null ||
                                  !widget.controller.sshReady
                              ? null
                              : create,
                          icon: Icon(
                            busy ? LucideIcons.loaderCircle : LucideIcons.plus,
                            size: 18,
                          ),
                          label: Text(
                            busy
                                ? '正在添加'
                                : provider?.supportsResources == true
                                ? '确认按量付费创建'
                                : '确认创建（预览）',
                          ),
                        ),
                      ],
                    )
                  else
                    Text(
                      '请先联网验证并保存凭证，再选择云服务器配置。验证通过不代表所有资源操作均已授权。',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _volcengineSummary(CloudTemplate template) {
    final value = template.volcengine!;
    final parameters = value['runInstances'] as Map;
    final eip = parameters['EipAddress'] as Map;
    return CloudNotice(
      '本次创建：1 台 · 按量计费\n'
      '地域：${value['region']} · 机型：${parameters['InstanceTypeId']}\n'
      '建议可用区：${parameters['ZoneId']}\n'
      '仅明确库存或容量不足时，依次尝试同地域其他可售可用区，保持相同机型、镜像、系统盘和带宽。创建结果不确定时暂停尝试并查询核实。\n'
      '镜像 ${parameters['ImageId']} · ${template.diskGb} GB 系统盘\n'
      '系统：${template.os} · 需满足 Linux glibc 2.39+、GTK 3.24 与 systemd 要求，管理员需核对镜像与登录账号。\n'
      '独立公网 IP 按流量计费 · 带宽上限 ${eip['BandwidthMbps']} Mbps\n'
      '服务器与公网 IP 一同释放；确认两者均已释放后才移除记录。系统盘随实例删除，共享网络保留。\n'
      'SSH 登录：${template.sshUsername}（密钥）\n'
      'SSH TCP 22 与 Sisters TCP 20001 来源：0.0.0.0/0\n'
      '创建会产生云费用。创建完成后点击「部署 Sisters」；暂不提供费用查询。',
    );
  }

  Widget _aliyunSummary(CloudTemplate template) {
    final value = template.aliyun!;
    final parameters = value['runInstances'] as Map;
    return CloudNotice(
      '本次创建：1 台 · 按量计费\n'
      '地域：${value['region']} · 机型：${parameters['InstanceType']}\n'
      '建议可用区：${parameters['ZoneId']}\n'
      '仅明确库存或容量不足时，依次尝试同地域其他可售可用区，保持相同机型、镜像、系统盘和带宽。创建结果不确定时暂停尝试并查询核实。\n'
      '镜像 ${parameters['ImageId']} · ${template.diskGb} GB 系统盘\n'
      '系统：${template.os} · 需满足 Linux glibc 2.39+、GTK 3.24 与 systemd 要求，管理员需核对镜像与登录账号。\n'
      '公网按流量计费 · 出网带宽上限 ${parameters['InternetMaxBandwidthOut']} Mbps\n'
      '本次公网地址与系统盘随实例释放，共享 VPC、交换机、安全组和公钥保留。\n'
      'SSH 登录：${template.sshUsername}（密钥）\n'
      'SSH TCP 22 与 Sisters TCP 20001 来源：0.0.0.0/0\n'
      '创建会产生云费用。创建完成后点击「部署 Sisters」；暂不提供费用查询。',
    );
  }

  Widget _tencentSummary(CloudTemplate template) {
    final value = template.tencent!;
    final parameters = value['runInstances'] as Map;
    final placement = parameters['Placement'] as Map;
    final internet = parameters['InternetAccessible'] as Map;
    return CloudNotice(
      '本次创建：1 台 · 按量计费（按小时后付费）\n'
      '地域：${value['region']} · 机型：${parameters['InstanceType']}\n'
      '建议可用区：${placement['Zone']}\n'
      '建议可用区售罄时，将依次尝试同地域其他可用区，保持相同机型、镜像、系统盘和带宽。创建结果不确定时暂停尝试并查询核实。\n'
      '镜像 ${parameters['ImageId']} · ${template.diskGb} GB 系统盘\n'
      '系统：${template.os} · 需满足 Linux glibc 2.39+、GTK 3.24 与 systemd 要求，管理员需核对镜像与登录账号。\n'
      '公网按流量计费 · 出网带宽上限 ${internet['InternetMaxBandwidthOut']} Mbps\n'
      'SSH 登录：${template.sshUsername}（密钥）\n'
      'SSH TCP ${TencentAccessPolicy.sshPort} 来源：${TencentAccessPolicy.ingressCidr}\n'
      'Sisters TCP ${TencentAccessPolicy.sistersPort} 来源：${TencentAccessPolicy.ingressCidr}\n'
      '创建会产生云费用。创建完成后，点击「部署 Sisters」即可部署；暂不提供费用查询。',
    );
  }

  Widget _providerOption(CloudProvider item) {
    final colors = Theme.of(context).colorScheme;
    final credential = widget.controller.credentialFor(item);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final button = credential?.onlineVerified != true
              ? OutlinedButton(
                  onPressed: () => Navigator.pop(context, item),
                  child: Text(credential == null ? '录入凭证' : '验证凭证'),
                )
              : FilledButton.tonal(
                  key: ValueKey('cloud-select-provider-${item.name}'),
                  onPressed: () => setState(() {
                    provider = item;
                    selected = null;
                  }),
                  child: const Text('创建'),
                );
          final title = Row(
            children: [
              CloudProviderMark(item),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      credential == null
                          ? '验证并保存凭证后即可选择配置'
                          : !credential.onlineVerified
                          ? '待联网验证'
                          : '已验证 · ${item.supportsResources ? '按量付费' : '交互预览'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          if (constraints.maxWidth < 450) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                title,
                const SizedBox(height: 14),
                Align(alignment: Alignment.centerRight, child: button),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 20),
              button,
            ],
          );
        },
      ),
    );
  }

  Widget _templateCard(CloudTemplate template) {
    final colors = Theme.of(context).colorScheme;
    final active = selected?.id == template.id;
    return Semantics(
      selected: active,
      button: true,
      label: '${template.name}，${template.cpu} 核 ${template.memoryGb} GB 内存',
      child: Material(
        color: active
            ? colors.secondaryContainer.withValues(alpha: .45)
            : colors.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: active ? colors.primary : colors.outlineVariant,
            width: active ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          key: ValueKey('cloud-template-${template.id}'),
          borderRadius: BorderRadius.circular(16),
          onTap: busy ? null : () => setState(() => selected = template),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      LucideIcons.server,
                      color: active ? colors.primary : colors.onSurfaceVariant,
                      size: 22,
                    ),
                    const Spacer(),
                    Icon(
                      active ? LucideIcons.circleCheck : LucideIcons.circle,
                      color: active ? colors.primary : colors.outlineVariant,
                      size: 21,
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  template.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${template.cpu} 核 / ${template.memoryGb} GB',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  template.description,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 16),
                Text(
                  '${template.os}\n${template.diskGb} GB 系统盘 · ${template.architecture}\n${template.regionLabel}',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.9,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CloudMachineCard extends StatefulWidget {
  const CloudMachineCard({
    super.key,
    required this.machine,
    required this.controller,
    this.onDeploy,
    this.sistersLinked = false,
    this.sistersReady = false,
    this.sistersProgress,
    this.sistersDetails,
    this.onRemoveConnection,
  });
  final CloudMachine machine;
  final CloudController controller;
  final Future<void> Function()? onDeploy, onRemoveConnection;
  final bool sistersLinked, sistersReady;
  final Widget? sistersProgress, sistersDetails;
  @override
  State<CloudMachineCard> createState() => _CloudMachineCardState();
}

class _CloudMachineCardState extends State<CloudMachineCard> {
  bool busy = false;
  String? error;
  Future<void> act(Future<void> Function() operation) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> release() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('释放云服务器'),
        content: Text(
          widget.machine.isReal
              ? '确认释放「${widget.machine.name}」？\n'
                    '公网地址：${widget.machine.publicIp.isEmpty ? '等待云端返回' : widget.machine.publicIp}\n\n'
                    '释放将结束此实例上的所有任务并删除系统盘数据，无法恢复。共享安全组、SSH 公钥、VPC 和子网会保留。\n\n'
                    '${widget.machine.provider == CloudProvider.volcengine ? '本次创建的独立公网 IP 将随服务器一同释放。只有实例和该公网 IP 均确认释放后才移除记录；公网 IP 留存或结果未知时保留记录供核对。' : '提交后还需查询云端确认；确认按钮不代表费用已停止。额外绑定的磁盘、弹性公网 IP 等资源需在${widget.machine.provider.displayName}控制台另行核对。'}'
              : '确认演示释放「${widget.machine.name}」？\n\n当前仅演示此流程，不操作云端资源。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留服务器'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.machine.isReal ? '确认释放并删除数据' : '确认释放（预览）'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await act(
        () => widget.machine.isReal
            ? widget.controller.requestCloudRelease(widget.machine.id)
            : widget.controller.requestPreviewRelease(widget.machine.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final m = widget.machine;
    final released = m.phase == CloudMachinePhase.released;
    final color = m.failed
        ? colors.error
        : released
        ? colors.onSurfaceVariant
        : colors.primary;
    final progress = switch (m.phase) {
      CloudMachinePhase.creating => .22,
      CloudMachinePhase.deploying => .68,
      CloudMachinePhase.releasing => .5,
      _ => 1.0,
    };
    return Card(
      key: ValueKey('cloud-machine-${m.id}'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CloudProviderMark(m.provider),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${m.provider.displayName} ${m.provider.productName} · ${m.template.os}',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                CloudPill(
                  m.phase == CloudMachinePhase.created && widget.sistersReady
                      ? '已创建 · Sisters 已部署'
                      : m.phase == CloudMachinePhase.created &&
                            widget.sistersLinked
                      ? '云服务器已创建'
                      : m.statusLabel,
                  color: color,
                ),
                CloudPill(
                  m.isReal ? '按量计费' : '交互预览',
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '${m.template.cpu} 核 / ${m.template.memoryGb} GB 内存 / ${m.template.diskGb} GB 系统盘',
              style: TextStyle(fontSize: 13, color: colors.onSurface),
            ),
            if (m.isReal) ...[
              const SizedBox(height: 12),
              SelectableText(
                '公网地址：${m.publicIp.isEmpty ? '等待云端返回' : m.publicIp}',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.7,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 18),
            if (m.active) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: m.isReal ? null : progress,
                  minHeight: 5,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                m.isReal
                    ? m.phase == CloudMachinePhase.releasing
                          ? '正在请求释放并核对云端结果。关闭应用不会取消云端操作。'
                          : '正在准备共享网络、安全组与登录公钥，并创建云服务器。关闭应用不会取消云端操作。'
                    : m.phase == CloudMachinePhase.releasing
                    ? '正在演示释放，请稍候。'
                    : '流程独立进行，你可以继续添加其他机器。',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ] else if (m.error.isNotEmpty)
              CloudNotice(m.error, error: true)
            else
              Text(
                m.isReal
                    ? released
                          ? '云端已确认释放。请在${m.provider.displayName}控制台核对账单及额外关联资源。'
                          : widget.sistersReady
                          ? 'Sisters 已部署，可在此查看连接状态并分发任务。云服务器仍按量计费。'
                          : widget.sistersLinked
                          ? 'Sisters 部署与连接状态见下方。云服务器仍按量计费。'
                          : m.phase != CloudMachinePhase.created
                          ? '请先查询云端状态，确认服务器已运行后再部署 Sisters。云资源可能继续计费。'
                          : '云服务器已创建，可能持续产生费用。点击「部署 Sisters」即可使用已保存的 SSH 密钥部署。'
                    : released
                    ? '释放流程已演示完成，没有操作真实云资源。'
                    : '创建与部署流程已演示完成。此预览节点不能执行抢票任务。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: colors.onSurfaceVariant,
                ),
              ),
            if (widget.sistersDetails != null) ...[
              const SizedBox(height: 18),
              widget.sistersDetails!,
            ],
            if (widget.sistersProgress != null) ...[
              const SizedBox(height: 12),
              widget.sistersProgress!,
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CloudNotice(error!, error: true),
              ),
            if (!m.active || (m.isReal && m.instanceId.isNotEmpty)) ...[
              const SizedBox(height: 18),
              const Divider(height: 1),
              const SizedBox(height: 12),
              _CloudMachineActions(
                minimumColumnWidth:
                    180 *
                    math.max(
                      1,
                      MediaQuery.textScalerOf(context).scale(14) / 14,
                    ),
                children: [
                  if (m.isReal &&
                      m.phase == CloudMachinePhase.created &&
                      widget.onDeploy != null)
                    FilledButton.icon(
                      key: ValueKey('cloud-deploy-${m.id}'),
                      style: _actionStyle(),
                      onPressed:
                          busy || widget.controller.isDeployingCloud(m.id)
                          ? null
                          : () => act(widget.onDeploy!),
                      icon: const Icon(LucideIcons.upload, size: 16),
                      label: Text(
                        widget.sistersReady
                            ? '重新部署 Sisters'
                            : widget.sistersLinked
                            ? '重试部署 Sisters'
                            : '部署 Sisters',
                      ),
                    ),
                  if (m.isReal &&
                      !released &&
                      (m.instanceId.isNotEmpty || m.createSubmitted))
                    OutlinedButton.icon(
                      key: ValueKey('cloud-refresh-${m.id}'),
                      style: _actionStyle(),
                      onPressed: busy
                          ? null
                          : () => act(
                              () => widget.controller.refreshCloudMachine(m.id),
                            ),
                      icon: const Icon(LucideIcons.refreshCw, size: 16),
                      label: const Text('查询云端状态'),
                    ),
                  if (m.isReal &&
                      m.phase == CloudMachinePhase.createFailed &&
                      !m.createSubmitted &&
                      m.instanceId.isEmpty)
                    OutlinedButton.icon(
                      key: ValueKey('cloud-retry-prepare-${m.id}'),
                      style: _actionStyle(),
                      onPressed: busy
                          ? null
                          : () => act(
                              () =>
                                  widget.controller.retryCloudPreparation(m.id),
                            ),
                      icon: const Icon(LucideIcons.refreshCw, size: 16),
                      label: const Text('重试准备并创建'),
                    ),
                  if (!released &&
                      (m.isReal
                          ? m.instanceId.isNotEmpty && !m.active
                          : m.phase != CloudMachinePhase.createFailed))
                    OutlinedButton.icon(
                      key: ValueKey('cloud-release-${m.id}'),
                      style: _actionStyle(foreground: colors.error),
                      onPressed:
                          busy || widget.controller.isDeployingCloud(m.id)
                          ? null
                          : release,
                      icon: const Icon(LucideIcons.power, size: 16),
                      label: const Text('释放云服务器'),
                    ),
                  if (m.canRemove)
                    OutlinedButton.icon(
                      style: _actionStyle(foreground: colors.onSurfaceVariant),
                      onPressed: busy
                          ? null
                          : () => act(
                              () => widget.controller.removeMachine(m.id),
                            ),
                      icon: const Icon(LucideIcons.trash2, size: 15),
                      label: Text(
                        m.isReal
                            ? released
                                  ? '删除已释放记录'
                                  : '删除失败记录'
                            : m.failed
                            ? '删除失败机器'
                            : '删除预览记录',
                      ),
                    ),
                  if (widget.onRemoveConnection != null)
                    OutlinedButton.icon(
                      key: ValueKey('cloud-remove-connection-${m.id}'),
                      style: _actionStyle(foreground: colors.onSurfaceVariant),
                      onPressed:
                          busy || widget.controller.isDeployingCloud(m.id)
                          ? null
                          : () => act(widget.onRemoveConnection!),
                      icon: const Icon(LucideIcons.unlink, size: 15),
                      label: const Text('移除 Sisters 连接'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  ButtonStyle _actionStyle({Color? foreground}) => OutlinedButton.styleFrom(
    foregroundColor: foreground,
    minimumSize: const Size(0, 48),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.standard,
    textStyle: Theme.of(context).textTheme.labelLarge
        ?.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
  );
}

// The surrounding card rows use IntrinsicHeight. A render layout keeps the
// actions responsive to each card's width while also supporting that pass.
class _CloudMachineActions extends MultiChildRenderObjectWidget {
  const _CloudMachineActions({
    required this.minimumColumnWidth,
    required super.children,
  });

  final double minimumColumnWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCloudMachineActions(minimumColumnWidth);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCloudMachineActions renderObject,
  ) {
    renderObject.minimumColumnWidth = minimumColumnWidth;
  }
}

class _CloudMachineActionParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderCloudMachineActions extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CloudMachineActionParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _CloudMachineActionParentData
        > {
  _RenderCloudMachineActions(this._minimumColumnWidth);

  static const gap = 10.0;
  double _minimumColumnWidth;

  set minimumColumnWidth(double value) {
    if (value == _minimumColumnWidth) return;
    _minimumColumnWidth = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CloudMachineActionParentData) {
      child.parentData = _CloudMachineActionParentData();
    }
  }

  int columns(double width) =>
      childCount > 1 && width >= 2 * _minimumColumnWidth + gap ? 2 : 1;

  double layoutWidth(BoxConstraints constraints) => constraints.hasBoundedWidth
      ? constraints.maxWidth
      : computeMaxIntrinsicWidth(double.infinity);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    if (childCount == 0) return constraints.constrain(Size.zero);
    final width = layoutWidth(constraints);
    final count = columns(width);
    final cellWidth = (width - gap * (count - 1)) / count;
    var cellHeight = 0.0;
    visitChildren((child) {
      cellHeight = math.max(
        cellHeight,
        (child as RenderBox)
            .getDryLayout(BoxConstraints.tightFor(width: cellWidth))
            .height,
      );
    });
    final rows = (childCount / count).ceil();
    return constraints.constrain(
      Size(width, rows * cellHeight + gap * (rows - 1)),
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) => _minimumColumnWidth;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      childCount > 1 ? 2 * _minimumColumnWidth + gap : _minimumColumnWidth;

  @override
  double computeMinIntrinsicHeight(double width) =>
      computeMaxIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeDryLayout(BoxConstraints.tightFor(width: width)).height;

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
    if (childCount == 0) return;
    final count = columns(size.width);
    final rows = (childCount / count).ceil();
    final cellSize = Size(
      (size.width - gap * (count - 1)) / count,
      (size.height - gap * (rows - 1)) / rows,
    );
    var index = 0;
    visitChildren((child) {
      final box = child as RenderBox;
      box.layout(BoxConstraints.tight(cellSize));
      final data = box.parentData! as _CloudMachineActionParentData;
      data.offset = Offset(
        (index % count) * (cellSize.width + gap),
        (index ~/ count) * (cellSize.height + gap),
      );
      index++;
    });
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
