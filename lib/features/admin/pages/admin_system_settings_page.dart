// AdminSystemSettingsPage - 系统设置（authorization:manage + 后端 superAdmin）
//
// 运行时可配的安全/业务策略阈值：登录限流 / 账号锁定 / 密码历史 / 导出限流 / 令牌TTL /
// 短信验证 / 导出行数上限 / 审计留存。密钥与部署类（jwt.secret/crypto/sms AK/CORS/swagger/DB）不在此
// （走 application.yml / 环境变量）。
//
// 安全（用户铁律，全方面）：
//   * 前端路由要求 authorization:manage，后端同时校验 superAdmin；
//   * 改设置【二次密码确认】（后端 SystemSettingsService.write 校验当前账号密码，即使 access token
//     被盗也无法改安全策略）；
//   * 改设置全过审计（action=update_system_setting，审计页可查谁改了哪项 旧→新值）；
//   * 后端类型/非负校验（前端也提示），防恶意值。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/providers/idle_timeout_controller.dart';
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
  final _formKey = GlobalKey<FormState>();

  // 分组顺序：(category, 中文标题, 图标)。
  static const _groups = <(String, String, IconData)>[
    ('security', '安全策略', Icons.lock_outline),
    ('token', '登录令牌', Icons.vpn_key_outlined),
    ('sms', '短信验证', Icons.sms_outlined),
    ('business', '业务限制', Icons.assessment_outlined),
    ('audit', '审计与留存', Icons.policy_outlined),
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
    final original = _all!.firstWhere((entry) => entry.key == key).value;
    setState(() {
      if (_controllers[key]!.text.trim() == original) {
        _dirty.remove(key);
      } else {
        _dirty.add(key);
      }
    });
  }

  Future<void> _refresh() async {
    if (_loading || _saving) return;
    if (_dirty.isNotEmpty) {
      context.appWarning(
        AppLocalizations.of(context).systemSettingUnsavedRefresh,
      );
      return;
    }
    await _load();
  }

  Future<void> _save() async {
    if (_dirty.isEmpty || _saving || _loading || _error != null) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      context.appWarning(AppLocalizations.of(context).systemSettingFixFields);
      return;
    }
    final keys = _dirty.toList();
    final changes = [
      for (final key in keys)
        (
          key: key,
          value: _controllers[key]!.text.trim(),
          expectedValue: _all!.firstWhere((entry) => entry.key == key).value,
        ),
    ];
    setState(() => _saving = true);
    try {
      // 缩短审计留存会在下一次清理中永久删日志：保存前单独确认一次。
      if (keys.any((key) => key.startsWith('audit_'))) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => const _RetentionConfirmDialog(),
        );
        if (confirmed != true || !mounted) return;
      }
      // 不挂整页遮罩：服务端要求再认证时网络层会弹统一密码框 (ADR-110)，遮罩不能盖住它。
      final saved = await ref
          .read(systemSettingRepositoryProvider)
          .updateBatch(changes);
      if (!mounted) return;
      final byKey = {for (final entry in saved) entry.key: entry};
      setState(() {
        _all = [for (final entry in _all!) byKey[entry.key] ?? entry];
        _dirty.clear();
      });
      context.appSuccess('已保存 ${keys.length} 项设置');
      // 公共运行时设置变更后立即重拉：同步空闲阈值，也让本机回执采用新的总留存月数。
      if (keys.contains('session_idle_timeout_minutes') ||
          keys.any((key) => key.startsWith('audit_'))) {
        ref.read(idleThresholdVersionProvider.notifier).state++;
      }
      await _load(); // 重载拿最新 updatedAt
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message); // 如 CONFLICT 已被修改 / VALIDATION_FAILED 越界
    } catch (_) {
      if (!mounted) return;
      context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const UtenAppBar(title: '系统设置', leading: UtenBackButton()),
      body: UtenContentContainer(
        child: Stack(
          children: [
            _loading && _all == null
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : _error != null
                ? _ErrorState(error: _error!, onRetry: _load)
                : _all == null || _all!.isEmpty
                ? const UtenEmpty(message: '暂无设置项')
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: Form(
                      key: _formKey,
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
                                enabled: !_saving && !_loading,
                              ),
                          const SizedBox(
                            height: UtenFloatingActionGroup.scrollClearance,
                          ),
                        ],
                      ),
                    ),
                  ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _saveBar(theme),
    );
  }

  Widget _saveBar(ThemeData theme) {
    if (_all == null || _error != null) return const SizedBox.shrink();
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          key: const ValueKey('system-settings-save'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          isLoading: _saving,
          icon: Icons.save_outlined,
          onPressed: _dirty.isNotEmpty && !_saving && !_loading ? _save : null,
          child: Text(_dirty.isEmpty ? '保存改动' : '保存 ${_dirty.length} 项改动'),
        ),
      ],
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
          Icon(
            Icons.warning_amber_rounded,
            color: theme.colorScheme.error,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppLocalizations.of(context).systemSettingEffectTiming,
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
    required this.enabled,
  });
  final (String, String, IconData) group;
  final List<SystemSettingEntry> items;
  final Map<String, TextEditingController> controllers;
  final bool Function(String) isDirty;
  final void Function(String) onChanged;
  final bool enabled;

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
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(group.$3, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  group.$2,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            if (group.$1 == 'audit' &&
                controllers.containsKey('audit_hot_retention_months') &&
                controllers.containsKey('audit_archive_retention_months')) ...[
              _AuditRetentionNotice(
                hotController: controllers['audit_hot_retention_months']!,
                archiveController:
                    controllers['audit_archive_retention_months']!,
              ),
              const Divider(height: 20),
            ],
            for (final e in items)
              _SettingRow(
                entry: e,
                controller: controllers[e.key]!,
                dirty: isDirty(e.key),
                onChanged: () => onChanged(e.key),
                enabled: enabled,
              ),
          ],
        ),
      ),
    );
  }
}

/// 把两个独立月份翻译成用户真正关心的“何时归档、何时永久删除”。
class _AuditRetentionNotice extends StatelessWidget {
  const _AuditRetentionNotice({
    required this.hotController,
    required this.archiveController,
  });

  final TextEditingController hotController;
  final TextEditingController archiveController;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: hotController,
      builder: (context, hotValue, _) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: archiveController,
        builder: (context, archiveValue, _) {
          final hot = int.tryParse(hotValue.text.trim());
          final archive = int.tryParse(archiveValue.text.trim());
          final valid =
              hot != null &&
              hot >= 1 &&
              hot <= 120 &&
              archive != null &&
              archive >= 0 &&
              archive <= 240;
          final policy = valid
              ? '当前填写：前 $hot 个月可在审计中心查询和导出；随后冷归档 $archive 个月；共 ${hot + archive} 个月后永久删除。'
              : '请输入有效月份后，这里会计算在线查询期和最终删除时间。';
          final theme = Theme.of(context);
          return Semantics(
            label: '审计日志留存说明',
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(UtenSpacing.s12),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer.withValues(
                  alpha: 0.35,
                ),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: theme.colorScheme.tertiary.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.auto_delete_outlined,
                    size: 20,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          policy,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '每日北京时间 03:17 分批执行。各客户端的本机回执在下次同步公共设置后，也按总月数清理(同时最多 300 条)。永久删除不可恢复；缩短期限前请先完成合规确认和必要备份。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 单个设置项：label + 数值输入(带单位及框内说明) + 上次修改时间。
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.entry,
    required this.controller,
    required this.dirty,
    required this.onChanged,
    required this.enabled,
  });
  final SystemSettingEntry entry;
  final TextEditingController controller;
  final bool dirty;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updated = DisplayDateTime.beijing(entry.updatedAt);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final numeric =
                  entry.valueType == 'int' || entry.valueType == 'long';
              final decoration = InputDecoration(
                labelText: entry.label,
                suffixText: entry.unit,
                border: const OutlineInputBorder(),
                filled: dirty,
                fillColor: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.35,
                ),
              );
              final field = entry.valueType == 'bool'
                  ? UtenDropdownField(
                      key: ValueKey('system-setting-${entry.key}'),
                      label: entry.label,
                      value: controller.text.toLowerCase(),
                      allowClear: false,
                      searchable: false,
                      enabled: enabled,
                      info: entry.description,
                      // 改动态（原 filled 高亮）由黄框 + 字段内提醒承接。
                      warningMessage: dirty ? '已修改，尚未保存' : null,
                      items: [
                        UtenDropdownItem(
                          value: 'true',
                          label: AppLocalizations.of(
                            context,
                          ).systemSettingEnabled,
                        ),
                        UtenDropdownItem(
                          value: 'false',
                          label: AppLocalizations.of(
                            context,
                          ).systemSettingDisabled,
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        controller.text = value;
                        onChanged();
                      },
                    )
                  : TextFormField(
                      key: ValueKey('system-setting-${entry.key}'),
                      controller: controller,
                      enabled: enabled,
                      keyboardType: numeric
                          ? TextInputType.number
                          : TextInputType.text,
                      decoration: UtenInputDecoration(
                        decoration,
                        info: entry.description,
                      ),
                      maxLines: numeric ? 1 : 2,
                      errorBuilder: utenTextFieldErrorBuilder,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      validator: (value) {
                        if (!dirty) return null;
                        if (!numeric) return null;
                        final parsed = int.tryParse(value?.trim() ?? '');
                        if (parsed == null || parsed < 0) {
                          return AppLocalizations.of(
                            context,
                          ).systemSettingInvalidInteger;
                        }
                        // 取值范围只认服务端登记 (列表接口随项下发)，前端不再另写一份。
                        final min = entry.minValue;
                        final max = entry.maxValue;
                        if ((min != null && parsed < min) ||
                            (max != null && parsed > max)) {
                          return '${AppLocalizations.of(context).systemSettingInvalidValue} (${min ?? 0}–${max ?? ''})';
                        }
                        return null;
                      },
                      onChanged: (_) => onChanged(),
                    );
              if (constraints.maxWidth < 600 || !numeric) return field;
              return Row(
                children: [
                  Expanded(
                    child: Text(entry.label, style: theme.textTheme.bodyLarge),
                  ),
                  SizedBox(width: 280, child: field),
                ],
              );
            },
          ),
          if (updated.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                '上次修改 $updated',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 审计留存调整的风险确认 (缩短期限会在下一次清理中永久删除历史日志)。
/// 密码确认由服务端统一要求再认证、网络层弹统一密码框完成 (ADR-110)。
class _RetentionConfirmDialog extends StatelessWidget {
  const _RetentionConfirmDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded),
      title: const Text('确认审计留存修改'),
      content: Text(
        '本次包含审计留存调整。缩短期限可能在下一次 03:17 清理中永久删除历史日志且不可恢复。'
        '请确认合规与备份后再继续。',
        style: theme.textTheme.bodySmall,
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('继续保存'),
        ),
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
