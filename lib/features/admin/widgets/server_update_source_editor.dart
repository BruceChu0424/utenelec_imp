import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/server_operations.dart';
import '../providers/server_operations_access.dart';
import '../repositories/server_operations_repository.dart';

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
  ConsumerState<ServerUpdateSourceEditor> createState() =>
      _ServerUpdateSourceEditorState();
}

class _ServerUpdateSourceEditorState
    extends ConsumerState<ServerUpdateSourceEditor> {
  final _form = GlobalKey<FormState>();
  final _endpoint = TextEditingController(), _bucket = TextEditingController();
  final _prefix = TextEditingController(), _keyId = TextEditingController();
  final _secret = TextEditingController(),
      _signingKey = TextEditingController();
  late final Object? _owner;
  ServerUpdateSource? _source;
  bool _expanded = false, _loading = false, _saving = false, _clear = false;
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
      ref.read(serverOperationsWritableProvider);

  @override
  void initState() {
    super.initState();
    _owner = ref.read(serverOperationsOwnerProvider);
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
    } catch (error) {
      if (_current) {
        setState(
          () => _error = error is ApiException ? error.message : '发布源读取失败，请重试。',
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
    final command = <String, dynamic>{
      'requestId': const Uuid().v4(),
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
      context.appSuccess('发布源已保存并由此服务器确认生效。');
      await widget.onSaved();
    } catch (error) {
      if (_current) {
        setState(
          () => _error = error is ApiException
              ? error.message
              : '发布源保存结果尚未确认，请重新读取服务器配置核对。',
        );
      }
    } finally {
      command.remove('accessKeySecret');
      if (mounted) _secret.clear();
      if (_current) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(serverSourceVisibleProvider)) return const SizedBox.shrink();
    return UtenCard(
      child: ExpansionTile(
        key: const ValueKey('server-source-editor'),
        title: const Text('发布源与凭据'),
        subtitle: const Text('仅超级管理员可配置；密钥只写不读'),
        initiallyExpanded: _expanded,
        onExpansionChanged: (expanded) {
          setState(() => _expanded = expanded);
          if (expanded && _source == null) _load();
        },
        childrenPadding: const EdgeInsets.all(UtenSpacing.s16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            UtenInlineNotice(
              level: UtenInlineNoticeLevel.error,
              message: _error,
            ),
          if (_source != null)
            Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(
                    'endpoint',
                    'OSS 区域域名',
                    _endpoint,
                    required: true,
                    hint: 'oss-cn-hangzhou.aliyuncs.com',
                    helper: '仅填区域域名，不含 https://、Bucket 名称或路径。',
                  ),
                  _field('bucket', 'Bucket', _bucket, required: true),
                  _field('prefix', '发布目录前缀（可留空）', _prefix),
                  Text(
                    _source!.accessKeyConfigured
                        ? '访问凭据：已配置${_source!.accessKeyIdHint == null ? '' : '（${_source!.accessKeyIdHint}）'}'
                        : '访问凭据：尚未配置',
                  ),
                  _field('key-id', '新访问密钥 ID（留空保留）', _keyId),
                  TextFormField(
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
                        labelText: '新访问密钥（留空保留）',
                        border: OutlineInputBorder(),
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
                  _field(
                    'signing-key',
                    '发布签名公钥',
                    _signingKey,
                    lines: 3,
                    required: _source!.signingPublicKey == null,
                    hint: 'ssh-ed25519 …（留空保留）',
                    helper: '用于验证正式发布签名。已配置时留空保留；首次配置需填写发布方提供的完整公钥。',
                  ),
                  if (_source!.signingKeyFingerprint != null)
                    SelectableText('公钥指纹：${_source!.signingKeyFingerprint}'),
                  const SizedBox(height: UtenSpacing.s12),
                  Wrap(
                    spacing: UtenSpacing.s12,
                    runSpacing: UtenSpacing.s8,
                    children: [
                      UtenButton(
                        key: const ValueKey('server-source-save'),
                        onPressed: _enabled ? _save : null,
                        isLoading: _saving,
                        child: const Text('保存发布源'),
                      ),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _enabled ? _load : null,
                        child: const Text('重新读取'),
                      ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  const Text('保存仅更新此公司的配置，不检查或下载版本。更新作业运行时不能更换发布源。'),
                ],
              ),
            ),
          if (_source == null && !_loading)
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _load,
              child: const Text('重新读取发布源'),
            ),
        ],
      ),
    );
  }

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
