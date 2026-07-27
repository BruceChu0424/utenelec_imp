// AdminSystemSettingsPage - 系统设置（超级管理员 user:manage）
//
// 运行时可配的安全/业务策略阈值：登录限流 / 账号锁定 / 密码历史 / 导出限流 / 令牌TTL /
// 短信验证 / 导出行数上限。密钥与部署类（jwt.secret/crypto/sms AK/CORS/swagger/DB）不在此
// （走 application.yml / 环境变量）。
//
// 安全（用户铁律，全方面）：
//   * 路由守卫 /admin/ 前缀要求 user:manage（permission_by_path.dart），普通用户连入口卡片都看不到；
//   * 改设置【二次密码确认】（后端 SystemSettingsService.write 校验当前账号密码，即使 access token
//     被盗也无法改安全策略）；
//   * 改设置全过审计（action=update_system_setting，审计页可查谁改了哪项 旧→新值）；
//   * 后端类型/非负校验（前端也提示），防恶意值。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/system_setting_entry.dart';
import '../repositories/system_setting_repository.dart';

class AdminSystemSettingsPage extends ConsumerStatefulWidget {
  const AdminSystemSettingsPage({super.key});

  @override
  ConsumerState<AdminSystemSettingsPage> createState() =>
      _AdminSystemSettingsPageState();
}

class _AdminSystemSettingsPageState
    extends ConsumerState<AdminSystemSettingsPage> {
  List<SystemSettingEntry>? _all;
  final Map<String, TextEditingController> _controllers = {};
  final Set<String> _dirty = {};
  bool _loading = false;
  bool _saving = false;
  String? _error;

  // 分组顺序：(category, 中文标题, 图标)。
  static const _groups = <(String, String, IconData)>[
    ('security', '安全策略', Icons.lock_outline),
    ('token', '登录令牌', Icons.vpn_key_outlined),
    ('sms', '短信验证', Icons.sms_outlined),
    ('business', '业务限制', Icons.assessment_outlined),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref.read(systemSettingRepositoryProvider).list();
      if (!mounted) return;
      for (final c in _controllers.values) {
        c.dispose();
      }
      _controllers.clear();
      for (final e in list) {
        _controllers[e.key] = TextEditingController(text: e.value);
      }
      setState(() {
        _all = list;
        _dirty.clear();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载系统设置失败';
        _loading = false;
      });
    }
  }

  void _markDirty(String key) {
    if (!_dirty.contains(key)) {
      setState(() => _dirty.add(key));
    }
  }

  Future<void> _save() async {
    if (_dirty.isEmpty || _saving) return;
    final pwd = await showDialog<String>(
      context: context,
      builder: (_) => const _ConfirmPasswordDialog(),
    );
    if (pwd == null || pwd.isEmpty || !mounted) return;
    setState(() => _saving = true);
    final repo = ref.read(systemSettingRepositoryProvider);
    final keys = _dirty.toList();
    try {
      for (final key in keys) {
        await repo.update(key, _controllers[key]!.text.trim(), pwd);
      }
      if (!mounted) return;
      context.appSuccess('已保存 ${keys.length} 项设置');
      await _load(); // 重载拿最新 updatedAt
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message); // 如 BAD_CREDENTIALS 密码错 / VALIDATION_FAILED 类型错
    } catch (_) {
      if (!mounted) return;
      context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '系统设置',
        leading: const UtenBackButton(),
      ),
      body: UtenContentContainer(
        child: _loading && _all == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _error != null
                ? _ErrorState(error: _error!, onRetry: _load)
                : _all == null || _all!.isEmpty
                    ? const Center(child: Text('暂无设置项'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.all(UtenSpacing.s16),
                          children: [
                            _warningBanner(theme),
                            for (final g in _groups)
                              if (_all!.any((e) => e.category == g.$1))
                                _SettingGroupCard(
                                  group: g,
                                  items: _all!
                                      .where((e) => e.category == g.$1)
                                      .toList(),
                                  controllers: _controllers,
                                  isDirty: (k) => _dirty.contains(k),
                                  onChanged: _markDirty,
                                ),
                            const SizedBox(height: 80),
                          ],
                        ),
                      ),
      ),
      bottomNavigationBar: _saveBar(theme),
    );
  }

  Widget _saveBar(ThemeData theme) {
    final hasDirty = _dirty.isNotEmpty;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s16, vertical: UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(children: [
          Text(
            hasDirty ? '${_dirty.length} 项已修改' : '所有设置保持当前值',
            style: theme.textTheme.bodyMedium?.copyWith(
                color: hasDirty ? theme.colorScheme.primary : theme.colorScheme.outline),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: (hasDirty && !_saving) ? _save : null,
            icon: _saving
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? '保存中…' : '保存改动'),
          ),
        ]),
      ),
    );
  }

  Widget _warningBanner(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              color: theme.colorScheme.error, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '此处调整将立即影响全员安全策略（登录/锁定/令牌/导出等），请谨慎操作。保存需二次密码确认，且记入审计日志。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一组设置卡片（按 category）。
class _SettingGroupCard extends StatelessWidget {
  const _SettingGroupCard({
    required this.group,
    required this.items,
    required this.controllers,
    required this.isDirty,
    required this.onChanged,
  });
  final (String, String, IconData) group;
  final List<SystemSettingEntry> items;
  final Map<String, TextEditingController> controllers;
  final bool Function(String) isDirty;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12, vertical: UtenSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(group.$3, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(group.$2,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ]),
            const Divider(height: 20),
            for (final e in items)
              _SettingRow(
                entry: e,
                controller: controllers[e.key]!,
                dirty: isDirty(e.key),
                onChanged: () => onChanged(e.key),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单个设置项：label + 数值输入(带单位) + 说明 + 上次修改时间。
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.entry,
    required this.controller,
    required this.dirty,
    required this.onChanged,
  });
  final SystemSettingEntry entry;
  final TextEditingController controller;
  final bool dirty;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updated = entry.updatedAt == null
        ? null
        : (entry.updatedAt!.length > 19
            ? entry.updatedAt!.substring(0, 19).replaceAll('T', ' ')
            : entry.updatedAt!.replaceAll('T', ' '));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(child: Text(entry.label, style: theme.textTheme.bodyLarge)),
            SizedBox(
              width: 150,
              child: TextField(
                controller: controller,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: false),
                decoration: InputDecoration(
                  isDense: true,
                  suffixText: entry.unit,
                  hintText: '0',
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  filled: dirty,
                  fillColor:
                      theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
                ),
                onChanged: (_) => onChanged(),
              ),
            ),
          ]),
          if (entry.description != null && entry.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                entry.description!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (updated != null)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                '上次修改 $updated',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
        ],
      ),
    );
  }
}

/// 二次密码确认对话框（防令牌被盗后恶意改安全策略）。
class _ConfirmPasswordDialog extends StatefulWidget {
  const _ConfirmPasswordDialog();
  @override
  State<_ConfirmPasswordDialog> createState() => _ConfirmPasswordDialogState();
}

class _ConfirmPasswordDialogState extends State<_ConfirmPasswordDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final p = _ctrl.text;
    if (p.isEmpty) {
      setState(() => _error = '请输入账号密码');
      return;
    }
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.lock_outline),
      title: const Text('二次密码确认'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '为防止账号令牌被盗后恶意篡改安全策略，请输入您当前登录账号的密码以确认修改。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '账号密码',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确认修改')),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
