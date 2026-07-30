// 员工详情页 Hero 后的「待我审核的修改申请」区块。
// 仅当：当前用户有 profile:review && 该员工有 pending 申请 时渲染。
//
// 文档：docs/03-页面/员工详情页.md（§待我审区块）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
import '../../profile/models/profile_change_request.dart';
import '../../profile/providers/profile_change_providers.dart';

class ProfileChangePendingSection extends ConsumerWidget {
  const ProfileChangePendingSection({super.key, required this.employeeId});
  final String employeeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final perms = ref.watch(currentPermissionsProvider);
    if (!perms.contains(Perm.profileReview)) {
      return const SizedBox.shrink();
    }

    final async = ref.watch(
      hrProfileChangesProvider((status: 'pending', page: 1)),
    );
    final items = <HrProfileChangeListItem>[];
    async.whenData((page) {
      items.addAll(page.items.where((i) => i.employeeId == employeeId));
    });
    if (items.isEmpty) return const SizedBox.shrink();

    final preview = items.take(3).toList();
    final more = items.length - preview.length;

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: UtenCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.assignment_late_outlined,
                  color: theme.colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.profilePendingSectionTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    l10n.profilePendingBadge(items.length),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final item in preview) ...[
              _PendingRow(
                employeeName: item.employeeName ?? '—',
                itemCount: item.itemCount,
                submittedAt: item.submittedAt,
                onTap: () =>
                    context.push(RoutePath.hrProfileChangeDetail(item.batchId)),
              ),
              if (item != preview.last) const Divider(height: 1),
            ],
            if (more > 0) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: UtenButton(
                  type: UtenButtonType.ghost,
                  size: UtenButtonSize.small,
                  onPressed: () => context.push(RouteName.hrProfileChanges),
                  child: Text('${l10n.profilePendingSectionViewAll}（$more）'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({
    required this.employeeName,
    required this.itemCount,
    required this.submittedAt,
    required this.onTap,
  });

  final String employeeName;
  final int itemCount;
  final DateTime submittedAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${l10n.profileChangeBatchItems(itemCount)} · $employeeName',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${l10n.profileChangeSubmittedAt}：${_formatTime(submittedAt)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
