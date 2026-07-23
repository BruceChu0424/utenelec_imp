// HR 个人修改审批队列（/hr/profile-changes）
// 文档：docs/03-页面/我的页.md（§HR 端：员工修改审批）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../profile/models/profile_change_request.dart';
import '../../profile/providers/profile_change_providers.dart';
import '../../../shared/auth/pending_review_provider.dart';

class HrProfileChangesListPage extends ConsumerStatefulWidget {
  const HrProfileChangesListPage({super.key});

  @override
  ConsumerState<HrProfileChangesListPage> createState() =>
      _HrProfileChangesListPageState();
}

class _HrProfileChangesListPageState
    extends ConsumerState<HrProfileChangesListPage> {
  String? _status; // null = 默认待审
  final List<UtenSegment<String?>> _segments = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(hrProfileChangesProvider);
      ref.read(pendingReviewCountProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    _segments
      ..clear()
      ..addAll([
        UtenSegment(value: null, label: l10n.profileChangeFilterPending),
        UtenSegment(
          value: 'applied',
          label: l10n.profileChangeFilterApplied,
        ),
        UtenSegment(
          value: 'rejected',
          label: l10n.profileChangeFilterRejected,
        ),
      ]);

    final async = ref.watch(hrProfileChangesProvider(_status));

    return Scaffold(
      appBar: UtenAppBar(title: l10n.profileChangeHrQueueTitle),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: UtenSegmentedFilter<String?>(
              segments: _segments,
              selected: _status,
              onChanged: (v) => setState(() => _status = v),
            ),
          ),
          Expanded(child: _buildBody(l10n, async)),
        ],
      ),
    );
  }

  Widget _buildBody(
    AppLocalizations l10n,
    AsyncValue<ProfileChangePage<HrProfileChangeListItem>> async,
  ) {
    return async.when(
      data: (page) {
        if (page.items.isEmpty) {
          return UtenEmpty(
            icon: Icons.inbox_outlined,
            message: l10n.profileChangeHrQueueEmpty,
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(hrProfileChangesProvider);
            ref.read(pendingReviewCountProvider.notifier).refresh();
            await ref.read(hrProfileChangesProvider(_status).future);
          },
          child: UtenResponsiveGrid(
            itemCount: page.items.length,
            itemBuilder: (context, index, width) {
              final item = page.items[index];
              return _HrBatchCard(
                item: item,
                onTap: () => context.push(
                  RoutePath.hrProfileChangeDetail(item.batchId),
                ),
              );
            },
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => UtenEmpty.error(
        message: e is ApiException ? e.message : e.toString(),
        actionLabel: l10n.commonRetry,
        onAction: () => ref.invalidate(hrProfileChangesProvider),
      ),
    );
  }
}

class _HrBatchCard extends StatelessWidget {
  const _HrBatchCard({required this.item, required this.onTap});
  final HrProfileChangeListItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (statusText, statusColor) = _statusStyle(l10n, theme, item.status);
    return UtenCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UtenUserAvatar(name: item.employeeName, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.employeeName ?? '—',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${item.employeeCode ?? '—'} · ${item.departmentName ?? ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            l10n.profileChangeBatchItems(item.itemCount) +
                ' · ' +
                item.fieldCodes.take(3).join('、') +
                (item.fieldCodes.length > 3 ? '…' : ''),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            _formatTime(item.submittedAt),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Spacer(),
              UtenButton(
                type: UtenButtonType.primary,
                size: UtenButtonSize.small,
                icon: Icons.check_circle_outline,
                onPressed: onTap,
                child: Text(l10n.profileChangeReviewApprove),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

(String, Color) _statusStyle(AppLocalizations l10n, ThemeData theme, ProfileChangeStatus s) {
  switch (s) {
    case ProfileChangeStatus.pending:
      return (l10n.profileChangeStatusPending, theme.colorScheme.tertiary);
    case ProfileChangeStatus.applied:
      return (l10n.profileChangeStatusApplied, theme.colorScheme.primary);
    case ProfileChangeStatus.approved:
      return (l10n.profileChangeStatusApproved, theme.colorScheme.primary);
    case ProfileChangeStatus.rejected:
      return (l10n.profileChangeStatusRejected, theme.colorScheme.error);
    case ProfileChangeStatus.cancelled:
      return (l10n.profileChangeStatusCancelled, theme.colorScheme.onSurfaceVariant);
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}