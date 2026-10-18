import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../models/sms_settings.dart';
import '../providers/server_operations_access.dart';
import '../repositories/sms_settings_repository.dart';

class AdminSmsSettingsPage extends ConsumerWidget {
  const AdminSmsSettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = ref.watch(serverOperationsOwnerProvider);
    if (owner == null || !ref.watch(serverSourceVisibleProvider)) {
      return const Scaffold(
        appBar: UtenAppBar(title: '短信网关设置', showBackButton: true),
        body: UtenEmpty(icon: Icons.lock_outline, message: '仅超级管理员可管理短信网关'),
      );
    }
    return _SmsEditor(key: ValueKey(owner));
  }
}

class _SmsEditor extends ConsumerStatefulWidget {
  const _SmsEditor({super.key});
  @override
  ConsumerState<_SmsEditor> createState() => _SmsEditorState();
}

class _SmsEditorState extends ConsumerState<_SmsEditor> {
  final _form = GlobalKey<FormState>();
  final _endpoint = TextEditingController(),
      _sign = TextEditingController(),
      _template = TextEditingController();
  final _keyId = TextEditingController(), _secret = TextEditingController();
  late final Object? _owner;
  SmsSettings? _settings;
  String _provider = 'DISABLED';
  String? _error;
  bool _loading = false, _saving = false, _clear = false, _verified = false;
  bool get _current =>
      mounted &&
      _owner != null &&
      _owner == ref.read(serverOperationsOwnerProvider) &&
      ref.read(serverSourceVisibleProvider);
  bool get _enabled =>
      _current &&
      _settings?.canManage == true &&
      ref.read(serverOperationsWritableProvider) &&
      !_loading &&
      !_saving &&
      _verified;
  @override
  void initState() {
    super.initState();
    _owner = ref.read(serverOperationsOwnerProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final controller in [_endpoint, _sign, _template, _keyId, _secret]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  void _accept(SmsSettings settings) {
    _settings = settings;
    _provider =
        {
          'DISABLED',
          'ALIYUN',
          if (settings.canUseLog) 'LOG',
        }.contains(settings.provider)
        ? settings.provider
        : 'DISABLED';
    _endpoint.text = settings.endpoint;
    _sign.text = settings.signName;
    _template.text = settings.templateCode;
    _keyId.clear();
    _secret.clear();
    _clear = false;
    _verified = true;
  }

  Future<void> _load() async {
    if (!_current || _loading || _saving) return;
    setState(() {
      _loading = true;
      _error = null;
      _verified = false;
    });
    try {
      final settings = await ref.read(smsSettingsRepositoryProvider).fetch();
      if (_current) setState(() => _accept(settings));
    } catch (error) {
      if (_current) {
        setState(
          () => _error = error is ApiException
              ? error.message
              : '短信网关配置读取失败，请重试。',
        );
      }
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  Future<void> _save({bool environment = false}) async {
    if (!_enabled || _settings == null) return;
    if (!environment && !(_form.currentState?.validate() ?? false)) return;
    if (!environment) {
      final id = _keyId.text.trim(), secret = _secret.text;
      if (id.isEmpty != secret.isEmpty) {
        setState(() => _error = '更换访问凭据时，请同时填写新的密钥 ID 和密钥。');
        return;
      }
      if (_provider == 'ALIYUN' &&
          !_settings!.accessKeyConfigured &&
          id.isEmpty) {
        setState(() => _error = '启用阿里云短信前，请填写访问密钥 ID 和密钥。');
        return;
      }
      if (_provider == 'ALIYUN' && _settings!.secretUnreadable && id.isEmpty) {
        setState(() => _error = '原凭据无法读取，请重新填写两项访问凭据。');
        return;
      }
      if (_endpoint.text.trim().toLowerCase() !=
              _settings!.endpoint.toLowerCase() &&
          _settings!.accessKeyConfigured &&
          id.isEmpty &&
          !_clear) {
        setState(() => _error = '更换接口域名时需重新填写两项凭据，或明确清除凭据并停用。');
        return;
      }
    }
    if (environment) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => UtenAlertDialog(
          title: const Text('恢复部署配置'),
          content: const Text(
            '将停止使用数据库覆盖，下一次发码按此公司部署环境配置执行。尚未保存的编辑会被放弃，已有验证码与发送记录保持原规则。',
          ),
          actions: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            UtenButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('恢复部署配置'),
            ),
          ],
        ),
      );
      if (confirmed != true || !_current || !_enabled) return;
    }
    final command = <String, dynamic>{
      'expectedRevision': _settings!.revision,
      if (environment)
        'useEnvironment': true
      else ...{
        'provider': _provider,
        'endpoint': _endpoint.text.trim().toLowerCase(),
        'signName': _sign.text.trim(),
        'templateCode': _template.text.trim(),
        'clearCredentials': _clear,
        if (_keyId.text.trim().isNotEmpty) 'accessKeyId': _keyId.text.trim(),
        if (_secret.text.isNotEmpty) 'accessKeySecret': _secret.text,
      },
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref.read(smsSettingsRepositoryProvider).save(command);
      if (!mounted || !_current) return;
      setState(() => _accept(saved));
      if (const {'READY', 'DISABLED'}.contains(saved.status)) {
        context.appSuccess('配置已保存，下一次发码使用当前网关配置。');
      } else {
        context.appWarning('配置已保存，但网关暂不可用，请查看服务器说明。');
      }
    } catch (error) {
      if (!_current) return;
      final rejected =
          error is ApiException &&
          error.httpStatus != null &&
          error.httpStatus! >= 400 &&
          error.httpStatus! < 500;
      setState(() {
        _verified = rejected;
        _error = rejected ? error.message : '保存结果尚未确认，请重新读取服务器配置核对后再操作。';
      });
    } finally {
      command.remove('accessKeySecret');
      if (mounted) _secret.clear();
      if (_current) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Scaffold(
      appBar: UtenAppBar(
        title: '短信网关设置',
        showBackButton: true,
        showPagePermissionAction: false,
        actions: [
          IconButton(
            tooltip: '重新读取服务器配置',
            onPressed: _loading || _saving ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: UtenContentContainer.narrow(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_loading) const LinearProgressIndicator(),
                if (_error != null)
                  UtenInlineNotice(
                    level: UtenInlineNoticeLevel.error,
                    message: _error,
                  ),
                if (settings != null) ...[
                  UtenCard(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '此公司的短信服务',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '配置来源：${settings.source == 'ENV' ? '部署环境' : '数据库覆盖'}',
                          ),
                          Text(
                            '当前网关：${_providerLabel(settings.effectiveProvider, settings.canUseLog)}',
                          ),
                          Text('配置状态：${_status(settings.status)}'),
                          if (settings.detail?.isNotEmpty == true)
                            Text(settings.detail!),
                          const Text(
                            '保存后用于下一次发码，不会发送测试短信，也不会改变验证码时限、发送间隔和每日限额。',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  UtenCard(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: Form(
                        key: _form,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            DropdownButtonFormField<String>(
                              key: const ValueKey('sms-provider'),
                              initialValue: _provider,
                              isExpanded: true,
                              decoration: const UtenInputDecoration(
                                InputDecoration(
                                  labelText: '短信网关',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              selectedItemBuilder: (context) => [
                                for (final provider in [
                                  'DISABLED',
                                  'ALIYUN',
                                  if (settings.canUseLog) 'LOG',
                                ])
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      _providerLabel(
                                        provider,
                                        settings.canUseLog,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              items: [
                                const DropdownMenuItem(
                                  value: 'DISABLED',
                                  child: Text('停用短信'),
                                ),
                                const DropdownMenuItem(
                                  value: 'ALIYUN',
                                  child: Text('阿里云短信'),
                                ),
                                if (settings.canUseLog)
                                  const DropdownMenuItem(
                                    value: 'LOG',
                                    child: Text('开发日志'),
                                  ),
                              ],
                              onChanged: _enabled
                                  ? (value) {
                                      if (value != null) {
                                        setState(() {
                                          _provider = value;
                                          if (value != 'DISABLED') {
                                            _clear = false;
                                          }
                                        });
                                      }
                                    }
                                  : null,
                            ),
                            const SizedBox(height: UtenSpacing.s12),
                            _field(
                              'endpoint',
                              '短信接口域名',
                              _endpoint,
                              required: _provider == 'ALIYUN',
                              hint: 'dysmsapi.aliyuncs.com',
                            ),
                            _field(
                              'sign',
                              '短信签名',
                              _sign,
                              required: _provider == 'ALIYUN',
                            ),
                            _field(
                              'template',
                              '验证码模板代码',
                              _template,
                              required: _provider == 'ALIYUN',
                            ),
                            Text(
                              settings.accessKeyConfigured
                                  ? '访问凭据：已配置${settings.accessKeyIdHint == null ? '' : '（${settings.accessKeyIdHint}）'}'
                                  : '访问凭据：尚未配置',
                            ),
                            _field(
                              'key-id',
                              '新访问密钥 ID',
                              _keyId,
                              helper: '留空保留已保存的访问密钥 ID。',
                            ),
                            TextFormField(
                              key: const ValueKey('sms-secret'),
                              errorBuilder: utenTextFieldErrorBuilder,
                              controller: _secret,
                              enabled: _enabled && !_clear,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: const [],
                              decoration: const UtenInputDecoration(
                                InputDecoration(
                                  labelText: '新访问密钥',
                                  border: OutlineInputBorder(),
                                ),
                                info: '留空保留已保存的访问密钥。',
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s8),
                            const Text(
                              '更换访问凭据需同时填写两项；更换接口域名时必须重新填写凭据。密钥只写不读，不会保存在本机草稿。',
                            ),
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: _clear,
                              title: const Text('明确清除已保存凭据并停用短信'),
                              onChanged: _enabled
                                  ? (value) => setState(() {
                                      _clear = value == true;
                                      if (_clear) {
                                        _provider = 'DISABLED';
                                        _keyId.clear();
                                        _secret.clear();
                                      }
                                    })
                                  : null,
                            ),
                            Wrap(
                              spacing: UtenSpacing.s12,
                              runSpacing: UtenSpacing.s8,
                              children: [
                                UtenButton(
                                  key: const ValueKey('sms-settings-save'),
                                  onPressed: _enabled ? () => _save() : null,
                                  isLoading: _saving,
                                  child: const Text('保存短信网关'),
                                ),
                                if (settings.source == 'DATABASE')
                                  UtenButton(
                                    key: const ValueKey('sms-settings-env'),
                                    type: UtenButtonType.secondary,
                                    isLoading: _saving,
                                    onPressed: _enabled
                                        ? () => _save(environment: true)
                                        : null,
                                    child: const Text('恢复部署配置'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _providerLabel(String provider, bool logAllowed) => switch (provider) {
    'ALIYUN' => '阿里云短信',
    'DISABLED' => '已停用',
    'LOG' when logAllowed => '开发日志',
    _ => '不可用（部署限制）',
  };
  String _status(String status) => switch (status) {
    'READY' => '配置就绪',
    'DISABLED' => '已停用',
    'BLOCKED' => '受部署规则限制',
    'KEY_UNREADABLE' => '原访问凭据无法读取',
    _ => '配置无效',
  };
  Widget _field(
    String key,
    String label,
    TextEditingController controller, {
    bool required = false,
    String? hint,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
    child: TextFormField(
      key: ValueKey('sms-$key'),
      errorBuilder: utenTextFieldErrorBuilder,
      controller: controller,
      enabled: _enabled && !(key == 'key-id' && _clear),
      decoration: UtenInputDecoration(
        InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon:
              key == 'endpoint' &&
                  (_settings?.allowedEndpoints.isNotEmpty ?? false)
              ? PopupMenuButton<String>(
                  key: const ValueKey('sms-endpoint-options'),
                  tooltip: '选择官方短信接口',
                  enabled: _enabled,
                  icon: const Icon(Icons.arrow_drop_down),
                  onSelected: (value) => _endpoint.text = value,
                  itemBuilder: (context) => [
                    for (final endpoint in _settings!.allowedEndpoints)
                      PopupMenuItem(value: endpoint, child: Text(endpoint)),
                  ],
                )
              : null,
          border: const OutlineInputBorder(),
        ),
        info: key == 'endpoint'
            ? '从服务器允许的官方短信接口中选择；不含协议、端口或路径。停用时可留空。'
            : helper,
      ),
      validator: (value) {
        if (required && (value == null || value.trim().isEmpty)) {
          return '请填写$label';
        }
        if (key == 'endpoint') {
          final endpoint = value?.trim().toLowerCase() ?? '';
          if (endpoint.isEmpty && _provider != 'ALIYUN') return null;
          if (_settings?.allowedEndpoints.isEmpty ?? true) {
            return '服务器未提供短信接口允许列表，请重新读取配置后重试。';
          }
          if (!_settings!.allowedEndpoints.contains(endpoint)) {
            return '请选择服务器允许的官方短信接口域名。';
          }
        }
        return null;
      },
    ),
  );
}
