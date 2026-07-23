// 单条 diff 行：字段标签 + Before + After。
// 私有 widget（在 profile / hr_profile 各被使用 ≥1 次前，不升级到 components/）。

import 'package:flutter/material.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../models/profile_change_request.dart';

class ProfileChangeDiffRow extends StatelessWidget {
  const ProfileChangeDiffRow({
    super.key,
    required this.item,
    this.showStatusBadge = false,
  });

  final ProfileChangeItem item;
  final bool showStatusBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _labelOf(l10n, item.fieldCode, item.fieldLabel),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (showStatusBadge) _statusBadge(theme, l10n),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _ValueBox(
                  label: l10n.profileChangeBefore,
                  value: item.oldValue,
                  muted: true,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ValueBox(
                  label: l10n.profileChangeAfter,
                  value: item.newValue,
                  muted: false,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(ThemeData theme, AppLocalizations l10n) {
    final (text, color) = switch (item.status) {
      ProfileChangeStatus.pending => (l10n.profileChangeStatusPending, theme.colorScheme.tertiary),
      ProfileChangeStatus.applied => (l10n.profileChangeStatusApplied, theme.colorScheme.primary),
      ProfileChangeStatus.approved => (l10n.profileChangeStatusApproved, theme.colorScheme.primary),
      ProfileChangeStatus.rejected => (l10n.profileChangeStatusRejected, theme.colorScheme.error),
      ProfileChangeStatus.cancelled => (l10n.profileChangeStatusCancelled, theme.colorScheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

class _ValueBox extends StatelessWidget {
  const _ValueBox({required this.label, required this.value, required this.muted});
  final String label;
  final String? value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: muted
            ? theme.colorScheme.surfaceContainer
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: muted
              ? theme.colorScheme.outlineVariant
              : theme.colorScheme.primary.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value?.isNotEmpty == true ? value! : '—',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: muted
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurface,
              fontWeight: muted ? FontWeight.normal : FontWeight.w600,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 字段标签映射。优先用 [fieldLabel]（后端 i18n 快照），否则用 i18n key 查。
String _labelOf(AppLocalizations l10n, String code, String label) {
  // i18n 优先级：1) fieldLabel 是后端 i18n 标签；2) 备用本地 lookup
  if (label.isNotEmpty && !_looksLikeKey(label)) return label;
  switch (code) {
    case 'fullName':
      return l10n.profileChangeFieldFullName;
    case 'hujiAddress':
      return l10n.profileFieldHujiAddress;
    case 'phone':
      return l10n.profileChangeFieldPhone;
  }
  if (code.startsWith('emergencyContact.')) {
    final tail = code.substring('emergencyContact.'.length);
    final dot = tail.indexOf('.');
    final sub = dot > 0 ? tail.substring(dot + 1) : tail;
    return switch (sub) {
      'name' => l10n.profileChangeFieldEmergencyName,
      'phone' => l10n.profileChangeFieldEmergencyPhone,
      'relationship' => l10n.profileChangeFieldEmergencyRelationship,
      _ => code,
    };
  }
  return label.isNotEmpty ? label : code;
}

bool _looksLikeKey(String s) {
  // 字段标签一般是显示名（中文/英文），如果只有英文+数字+下划线，认为是 i18n key
  return RegExp(r'^[a-z][a-zA-Z0-9]+$').hasMatch(s);
}