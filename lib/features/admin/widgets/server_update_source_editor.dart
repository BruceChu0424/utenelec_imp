import 'package:flutter/material.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/server_operations.dart';
import '../providers/server_operations_access.dart';
import '../repositories/server_operations_repository.dart';
import '../repositories/server_operation_outcome.dart';
import 'server_update_dialog_guard.dart';

/// No drafts, preferences or secret readback. Editors live for one session only.
class ServerUpdateSourceEditor extends ConsumerStatefulWidget {
  const ServerUpdateSourceEditor({
    super.key,
    required this.busy,
    required this.onSaved,
  });
  final bool busy;
  final Future<void> Function() onSaved;
  @override
  ConsumerState<ServerUpdateSourceEditor> createState() => _SourceEntryState();
}

class _SourceEntryState extends ConsumerState<ServerUpdateSourceEditor> {
  late final ValueNotifier<bool> _busy = ValueNotifier(widget.busy);
  String? _pendingRequestId;
  bool _open = false;
  ModalRoute<void>? _route;

  @override
  void didUpdateWidget(ServerUpdateSourceEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _busy.value = widget.busy;
  }

  @override
  void dispose() {
    _busy.dispose();
    final route = _route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
    super.dispose();
  }

  Future<void> _edit() async {
    if (_open ||
        widget.busy ||
        !ref.read(serverSourceVisibleProvider) ||
        !ref.read(serverOperationsWritableProvider)) {
      return;
    }
    setState(() => _open = true);
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          _route = ModalRoute.of<void>(dialogContext);
          return ServerUpdateDialogGuard(
            source: true,
            child: ValueListenableBuilder<bool>(
              valueListenable: _busy,
              builder: (_, busy, _) => _ServerUpdateSourceDialog(
                busy: busy,
                onSaved: widget.onSaved,
                onReadback: () {
                  if (mounted) setState(() => _pendingRequestId = null);
                },
                onUncertain: (requestId) {
                  // This is deliberately only a nonsecret operation identifier.
                  // Credential controllers and payload never leave the dialog.
                  if (mounted) setState(() => _pendingRequestId = requestId);
                },
              ),
            ),
          );
        },
      );
    } finally {
      _route = null;
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(serverSourceVisibleProvider)) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    return UtenCard(
      child: ListTile(
        key: const ValueKey('server-source-editor'),
        contentPadding: const EdgeInsets.all(UtenSpacing.s16),
        leading: const Icon(Icons.settings_input_component_outlined),
        title: Text(
          l.serverUpdateSource,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(
          _pendingRequestId == null
              ? l.serverUpdateSourceHint
              : l.serverUpdateSourcePending,
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        enabled: !widget.busy && ref.watch(serverOperationsWritableProvider),
        onTap:
            _open || widget.busy || !ref.watch(serverOperationsWritableProvider)
            ? null
            : _edit,
      ),
    );
  }
}

class _ServerUpdateSourceDialog extends ConsumerStatefulWidget {
  const _ServerUpdateSourceDialog({
    required this.busy,
    required this.onSaved,
    required this.onReadback,
    required this.onUncertain,
  });
  final bool busy;
  final Future<void> Function() onSaved;
  final VoidCallback onReadback;
  final ValueChanged<String> onUncertain;
  @override
  ConsumerState<_ServerUpdateSourceDialog> createState() =>
      _ServerUpdateSourceEditorState();
}

class _ServerUpdateSourceEditorState
    extends ConsumerState<_ServerUpdateSourceDialog> {
  final _form = GlobalKey<FormState>();
  final _endpoint = TextEditingController(), _bucket = TextEditingController();
  final _prefix = TextEditingController(), _keyId = TextEditingController();
  final _secret = TextEditingController(),
      _signingKey = TextEditingController();
  late final Object? _owner;
  ServerUpdateSource? _source;
  bool _loading = false, _saving = false, _clear = false;
  bool _readbackRequired = false, _outcomeUnknown = false;
  String? _error;
  bool get _current =>
      mounted &&
      _owner != null &&
      _owner == ref.read(serverOperationsOwnerProvider) &&
      ref.read(serverSourceVisibleProvider);
  bool get _enabled =>
      _current &&
      !widget.busy &&
      !_loading &&
      !_saving &&
      !_readbackRequired &&
      ref.read(serverOperationsWritableProvider);

  @override
  void initState() {
    super.initState();
    _owner = ref.read(serverOperationsOwnerProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final controller in [
      _endpoint,
      _bucket,
      _prefix,
      _keyId,
      _secret,
      _signingKey,
    ]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  void _accept(ServerUpdateSource source) {
    _source = source;
    _endpoint.text = source.endpoint;
    _bucket.text = source.bucket;
    _prefix.text = source.objectPrefix;
    _signingKey.clear();
    _keyId.clear();
    _secret.clear();
    _clear = false;
  }

  Future<void> _load() async {
    if (!_current || _loading || _saving) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = await ref
          .read(serverOperationsRepositoryProvider)
          .source();
      if (_current) setState(() => _accept(source));
      if (_current) {
        _readbackRequired = false;
        _outcomeUnknown = false;
        widget.onReadback();
      }
    } catch (error) {
      if (_current) {
        setState(
          () => _error = error is ApiException
              ? safeServerOperationText(error.message) ?? '发布源读取失败，请重试。'
              : '发布源读取失败，请重试。',
        );
      }
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_enabled ||
        _source == null ||
        !(_form.currentState?.validate() ?? false)) {
      return;
    }
    if (_clear && (_keyId.text.trim().isNotEmpty || _secret.text.isNotEmpty)) {
      setState(() => _error = '清除凭据时请勿同时填写新密钥。');
      return;
    }
    if (_keyId.text.trim().isNotEmpty && _secret.text.isEmpty) {
      setState(() => _error = '更换访问密钥 ID 时，请同时填写新密钥。');
      return;
    }
    final requestId = const Uuid().v4();
    final command = <String, dynamic>{
      'requestId': requestId,
      'expectedRevision': _source!.revision,
      'endpoint': _endpoint.text.trim(),
      'bucket': _bucket.text.trim(),
      'objectPrefix': _prefix.text.trim(),
      'clearCredentials': _clear,
      if (_signingKey.text.trim().isNotEmpty)
        'signingPublicKey': _signingKey.text.trim(),
      if (_keyId.text.trim().isNotEmpty) 'accessKeyId': _keyId.text.trim(),
      if (_secret.text.isNotEmpty) 'accessKeySecret': _secret.text,
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final source = await ref
          .read(serverOperationsRepositoryProvider)
          .saveSource(command);
      if (!mounted || !_current) return;
      setState(() => _accept(source));
      widget.onReadback();
      context.appSuccess('发布源已保存并由此服务器确认生效。');
      await widget.onSaved();
    } catch (error) {
      if (_current) {
        final certain = serverOperationDefinitelyRejected(error);
        setState(() {
          _readbackRequired = true;
          _outcomeUnknown = !certain;
          _error = certain
              ? safeServerOperationText((error as ApiException).message) ??
                    '服务器拒绝保存，请重新读取当前配置。'
              : '发布源保存结果尚未确认，请重新读取服务器配置核对。';
        });
        if (!certain) widget.onUncertain(requestId);
      }
    } finally {
      command.remove('accessKeySecret');
      if (mounted) _secret.clear();
      if (_current) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: UtenAlertDialog(
        key: const ValueKey('server-source-dialog'),
        alignment: Alignment.center,
        maxWidth: 800,
        title: Row(
          children: [
            Expanded(child: Text(l.serverUpdateSource)),
            const UtenFieldHintIcon(
              info: '保存仅更新此公司的配置，不检查或下载版本。更新作业运行时不能更换发布源。',
              dense: true,
            ),
          ],
        ),
        content: SizedBox(
          width: 720,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.serverUpdateSourceHint, style: theme.textTheme.bodySmall),
              if (_loading) ...[
                const SizedBox(height: UtenSpacing.s12),
                const LinearProgressIndicator(),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                UtenInlineNotice(
                  level: UtenInlineNoticeLevel.error,
                  message: _error,
                ),
              ],
              if (_readbackRequired) ...[
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  _outcomeUnknown
                      ? l.serverUpdateReadbackRequired
                      : '请重新读取当前发布源后再保存。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: UtenSpacing.s16),
              if (_source != null)
                Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _pair(
                        _field(
                          'endpoint',
                          'OSS 区域域名',
                          _endpoint,
                          required: true,
                          hint: 'oss-cn-hangzhou.aliyuncs.com',
                          helper: '仅填区域域名，不含 https://、Bucket 名称或路径。',
                        ),
                        _field('bucket', 'Bucket', _bucket, required: true),
                      ),
                      _field('prefix', '发布目录前缀', _prefix, helper: '发布目录前缀可留空。'),
                      const SizedBox(height: UtenSpacing.s8),
                      Text('访问凭据', style: theme.textTheme.titleMedium),
                      const SizedBox(height: UtenSpacing.s8),
                      Text(
                        _source!.accessKeyConfigured ? '访问凭据：已配置' : '访问凭据：尚未配置',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      _pair(
                        _field(
                          'key-id',
                          '新访问密钥 ID',
                          _keyId,
                          helper: '留空保留已保存的访问密钥 ID。',
                        ),
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UtenSpacing.s12,
                          ),
                          child: TextFormField(
                            key: const ValueKey('server-source-secret'),
                            errorBuilder: utenTextFieldErrorBuilder,
                            controller: _secret,
                            enabled: _enabled && !_clear,
                            obscureText: true,
                            enableSuggestions: false,
                            autocorrect: false,
                            autofillHints: const [],
                            decoration: const UtenInputDecoration(
                              InputDecoration(
                                labelText: '新访问密钥',
                                border: OutlineInputBorder(),
                              ),
                              info: '留空保留已保存的访问密钥。',
                            ),
                          ),
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _clear,
                        onChanged: _enabled
                            ? (value) => setState(() {
                                _clear = value == true;
                                if (_clear) {
                                  _keyId.clear();
                                  _secret.clear();
                                }
                                _error = null;
                              })
                            : null,
                        title: const Text('明确清除已保存的访问凭据'),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      Text('签名验证', style: theme.textTheme.titleMedium),
                      const SizedBox(height: UtenSpacing.s12),
                      _field(
                        'signing-key',
                        '发布签名公钥',
                        _signingKey,
                        lines: 3,
                        required: _source!.signingPublicKey == null,
                        hint: 'ssh-ed25519 …（留空保留）',
                        helper: '用于验证正式发布签名。已配置时留空保留；首次配置需填写发布方提供的完整公钥。',
                      ),
                      if (safeServerOperationText(
                            _source!.signingKeyFingerprint,
                          ) !=
                          null)
                        Text(
                          '公钥指纹：${safeServerOperationText(_source!.signingKeyFingerprint)}',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: UtenSpacing.s12),
              Align(
                alignment: Alignment.centerLeft,
                child: UtenButton(
                  key: const ValueKey('server-source-readback'),
                  type: UtenButtonType.secondary,
                  onPressed: _loading || _saving ? null : _load,
                  child: const Text('重新读取'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          UtenButton(
            key: const ValueKey('server-source-close'),
            type: UtenButtonType.secondary,
            onPressed: _saving
                ? null
                : () {
                    if (_current && !_saving) Navigator.pop(context);
                  },
            child: Text(
              _outcomeUnknown ? l.serverUpdateCloseTemporarily : '关闭',
            ),
          ),
          UtenButton(
            key: const ValueKey('server-source-save'),
            onPressed: _enabled && _source != null ? _save : null,
            isLoading: _saving,
            child: const Text('保存发布源'),
          ),
        ],
      ),
    );
  }

  Widget _pair(Widget first, Widget second) => Builder(
    builder: (context) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      if (serverUpdateDialogContentWidth(
            context,
            maxWidth: 800,
            designWidth: 720,
          ) >=
          560 * scale) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: first),
            const SizedBox(width: UtenSpacing.s16),
            Expanded(child: second),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [first, second],
      );
    },
  );

  Widget _field(
    String key,
    String label,
    TextEditingController controller, {
    bool required = false,
    int lines = 1,
    String? hint,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
    child: TextFormField(
      key: ValueKey('server-source-$key'),
      errorBuilder: utenTextFieldErrorBuilder,
      controller: controller,
      enabled: _enabled && !(key == 'key-id' && _clear),
      minLines: lines,
      maxLines: lines,
      decoration: UtenInputDecoration(
        InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          hintText: hint,
        ),
        info: helper,
      ),
      validator: (value) {
        final text = value?.trim() ?? '';
        if (required && text.isEmpty) return '请填写$label';
        if (key == 'endpoint' &&
            !RegExp(r'^oss-[a-z0-9-]+\.aliyuncs\.com$').hasMatch(text)) {
          return '请填写区域域名，例如 oss-cn-hangzhou.aliyuncs.com，不含 https://';
        }
        if (key == 'signing-key' &&
            text.isNotEmpty &&
            !text.startsWith('ssh-ed25519 ')) {
          return '请填写 ssh-ed25519 格式的完整发布签名公钥';
        }
        return null;
      },
    ),
  );
}
