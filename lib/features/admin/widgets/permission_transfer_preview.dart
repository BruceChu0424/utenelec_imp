import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/uten_tokens.dart';
import '../models/permission_configuration.dart';
import '../providers/admin_providers.dart';

/// Shared review surface for file import and copying an employee's effective
/// permissions. Sensitive additions require independent, explicit selections.
class PermissionTransferPreviewDetails extends ConsumerWidget {
  const PermissionTransferPreviewDetails({
    super.key,
    required this.preview,
    required this.confirmations,
    required this.onConfirmationChanged,
    this.enabled = true,
  });
  final PermissionTransferPreview preview;
  final Set<String> confirmations;
  final void Function(String key, bool selected) onConfirmationChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog =
        ref.watch(permissionCatalogProvider).valueOrNull ?? const [];
    final names = {
      for (final group in catalog)
        for (final permission in group.permissions)
          permission.code: '${group.category} · ${permission.name}',
    };
    String label(Object? code) => names[code] ?? code.toString();
    final error = Theme.of(context).colorScheme.error;
    final changes = preview.changes
        .where(
          (change) =>
              (change['added'] as List? ?? const []).isNotEmpty ||
              (change['removed'] as List? ?? const []).isNotEmpty,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          changes.isEmpty
              ? (preview.canApply ? '所选配置已一致，无需调整' : '请先处理下方提示')
              : '本次有 ${changes.length} 组权限调整',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        for (final issue in preview.issues)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Text(issue, style: TextStyle(color: error)),
          ),
        for (final note in preview.notes)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Text(note),
          ),
        if (preview.pinnedBaselineAdditions.isNotEmpty)
          Text(
            '保留目标系统必须具备的基础权限：${preview.pinnedBaselineAdditions.map(label).join('、')}',
          ),
        for (final change in changes)
          ExpansionTile(
            key: ValueKey((
              'transfer-change',
              change['kind'],
              change['sourceKey'],
              change['label'],
            )),
            tilePadding: EdgeInsets.zero,
            title: Text(change['label'] as String? ?? '权限调整'),
            subtitle: Text(
              '新增 ${(change['added'] as List? ?? []).length} 项 · 收回 ${(change['removed'] as List? ?? []).length} 项',
            ),
            children: [
              for (final code in change['added'] as List? ?? const [])
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add, size: 18),
                  title: Text(label(code)),
                ),
              for (final code in change['removed'] as List? ?? const [])
                ListTile(
                  dense: true,
                  leading: Icon(Icons.remove, size: 18, color: error),
                  title: Text(label(code)),
                ),
            ],
          ),
        if (preview.sensitiveAdditions.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '以下敏感权限需要逐项确认',
            style: TextStyle(color: error, fontWeight: FontWeight.w700),
          ),
          for (final item in preview.sensitiveAdditions)
            CheckboxListTile(
              key: ValueKey('confirm-sensitive-${item['key']}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                '${item['targetLabel']} · ${item['label'] ?? label(item['permissionCode'])}',
              ),
              value: confirmations.contains(item['key']),
              onChanged: enabled
                  ? (value) => onConfirmationChanged(
                      item['key'] as String,
                      value == true,
                    )
                  : null,
            ),
        ],
      ],
    );
  }
}
