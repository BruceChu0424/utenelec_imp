// HR 个人修改审批队列（/hr/profile-changes）
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。
// 文档：docs/03-页面/我的页.md（§HR 端：员工修改审批）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_paged_grid.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
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
  int _page = 1; // 当前页（服务端真分页）
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
        UtenSegment(value: 'applied', label: l10n.profileChangeFilterApplied),
        UtenSegment(value: 'rejected', label: l10n.profileChangeFilterRejected),
      ]);

    final async = ref.watch(
      hrProfileChangesProvider((status: _status, page: _page)),
    );

    Widget body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          child: UtenSegmentedFilter<String?>(
            segments: _segments,
            selected: _status,
            onChanged: (v) => setState(() {
              _status = v;
              _page = 1; // 换筛选回到第 1 页
            }),
          ),
        ),
        Expanded(child: _buildBody(l10n, async)),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.profileChangeHrQueueTitle,
        showBackButton: true,
      ),
      body: body,
    );
  }

  Widget _buildBody(
    AppLocalizations l10n,
    AsyncValue<ProfileChangePage<HrProfileChangeListItem>> async,
  ) {
    return async.when(
      data: (page) {
        if (page.items.isEmpty) {
          return UtenEmpty(message: l10n.profileChangeHrQueueEmpty);
        }
        return Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(hrProfileChangesProvider);
                  ref.read(pendingReviewCountProvider.notifier).refresh();
                  await ref.read(
                    hrProfileChangesProvider((
                      status: _status,
                      page: _page,
                    )).future,
                  );
                },
                // 服务端按页拉取：当页 items 铺进网格，外层 SingleChildScrollView
                // 让当页可竖向滚动（修原先 Wrap 不可滚、卡片多会溢出的问题）。
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
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
                ),
              ),
            ),
            if (page.totalPages > 1)
              UtenGridPager(
                currentPage: page.page,
                totalPages: page.totalPages,
                totalItems: page.total,
                onPrev: page.page > 1
                    ? () => setState(() => _page = page.page - 1)
                    : null,
                onNext: page.page < page.totalPages
                    ? () => setState(() => _page = page.page + 1)
                    : null,
              ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => UtenEmpty.error(
        message: e is ApiException ? e.message : l10n.commonError,
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
    final (statusText, statusType) = _statusStyle(l10n, item.status);
    return UtenCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UtenUserAvatar(name: item.employeeName, size: 36),
              const SizedBox(width: UtenSpacing.s12),
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
              UtenStatusBadge(
                label: statusText,
                type: statusType,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '${l10n.profileChangeBatchItems(item.itemCount)} · ${item.fieldCodes.take(3).join('、')}${item.fieldCodes.length > 3 ? '…' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            _formatTime(item.submittedAt),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          Row(
            children: [
              const Spacer(),
              UtenButton(
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

/// 批次状态 → 文案 + 语义徽章类型。
(String, UtenStatusBadgeType) _statusStyle(
  AppLocalizations l10n,
  ProfileChangeStatus s,
) {
  switch (s) {
    case ProfileChangeStatus.pending:
      return (l10n.profileChangeStatusPending, UtenStatusBadgeType.warning);
    case ProfileChangeStatus.applied:
      return (l10n.profileChangeStatusApplied, UtenStatusBadgeType.success);
    case ProfileChangeStatus.approved:
      return (l10n.profileChangeStatusApproved, UtenStatusBadgeType.success);
    case ProfileChangeStatus.rejected:
      return (l10n.profileChangeStatusRejected, UtenStatusBadgeType.danger);
    case ProfileChangeStatus.cancelled:
      return (l10n.profileChangeStatusCancelled, UtenStatusBadgeType.neutral);
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
