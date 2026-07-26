// MyProfileChangesPage - 员工自查：我的修改申请
// 文档：docs/03-页面/我的页.md（§我的修改申请）
//
// 顶部 UtenSegmentedFilter（全部 / 待审 / 已通过 / 已驳回 / 已生效）
// 主区 UtenResponsiveGrid 卡片列表（每张 = 一批）
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/profile_change_request.dart';
import '../providers/profile_change_providers.dart';
import '../repositories/profile_change_repository.dart';
import '../widgets/profile_change_diff_row.dart';

class MyProfileChangesPage extends ConsumerStatefulWidget {
  const MyProfileChangesPage({super.key});

  @override
  ConsumerState<MyProfileChangesPage> createState() =>
      _MyProfileChangesPageState();
}

class _MyProfileChangesPageState extends ConsumerState<MyProfileChangesPage> {
  String? _status; // null = 全部
  final List<UtenSegment<String?>> _segments = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(myProfileChangesProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    _segments
      ..clear()
      ..addAll([
        UtenSegment(value: null, label: l10n.profileChangeFilterAll),
        UtenSegment(value: 'pending', label: l10n.profileChangeFilterPending),
        UtenSegment(value: 'applied', label: l10n.profileChangeFilterApplied),
        UtenSegment(value: 'rejected', label: l10n.profileChangeFilterRejected),
      ]);

    final async = ref.watch(myProfileChangesProvider(_status));

    Widget body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          child: UtenSegmentedFilter<String?>(
            segments: _segments,
            selected: _status,
            onChanged: (v) => setState(() => _status = v),
          ),
        ),
        Expanded(child: _buildBody(context, l10n, async)),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.profileChangeListTitle,
        // go 进入（非 push），栈被替换；返回显式回"我的"页
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.profile),
        ),
      ),
      body: body,
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    AsyncValue<ProfileChangePage<MyProfileChangeListItem>> async,
  ) {
    return async.when(
      data: (page) {
        if (page.items.isEmpty) {
          return UtenEmpty(
            icon: Icons.assignment_outlined,
            message: l10n.profileChangeListEmpty,
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(myProfileChangesProvider);
            await ref.read(myProfileChangesProvider(_status).future);
          },
          child: UtenResponsiveGrid(
            itemCount: page.items.length,
            itemBuilder: (context, index, width) {
              final item = page.items[index];
              return _MyBatchCard(item: item);
            },
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => UtenEmpty.error(
        message: e is ApiException ? e.message : e.toString(),
        actionLabel: l10n.commonRetry,
        onAction: () => ref.invalidate(myProfileChangesProvider),
      ),
    );
  }
}

class _MyBatchCard extends ConsumerWidget {
  const _MyBatchCard({required this.item});
  final MyProfileChangeListItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (statusText, statusType) = _statusStyle(l10n, item.status);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.profileChangeBatchItems(item.itemCount),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              UtenStatusBadge(
                label: statusText,
                type: statusType,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            item.fieldLabels.take(3).join('、') +
                (item.fieldLabels.length > 3 ? '…' : ''),
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
          if (item.reviewComment != null && item.reviewComment!.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Container(
              padding: const EdgeInsets.all(UtenSpacing.s8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: UtenRadius.smAll,
              ),
              child: Text(
                item.reviewComment!,
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          Row(
            children: [
              if (item.status == ProfileChangeStatus.pending)
                Expanded(
                  child: UtenButton(
                    type: UtenButtonType.ghost,
                    size: UtenButtonSize.small,
                    onPressed: () => _cancel(context, ref, item.batchId),
                    child: Text(l10n.profileChangeCancel),
                  ),
                ),
              if (item.status == ProfileChangeStatus.pending)
                const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: UtenButton(
                  type: UtenButtonType.primary,
                  size: UtenButtonSize.small,
                  onPressed: () => _openDetail(context, item.batchId),
                  child: Text(l10n.profileChangeDiffTitle),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openDetail(BuildContext context, String batchId) {
    showDialog<void>(
      context: context,
      builder: (_) => _MyBatchDetailDialog(batchId: batchId),
    );
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    String batchId,
  ) async {
    final l10n = AppLocalizations.of(context);
    try {
      await ref.read(profileChangeRepositoryProvider).cancel(batchId);
      if (!context.mounted) return;
      ref.invalidate(myProfileChangesProvider);
      context.appSuccess(l10n.profileChangeCancelledByMe);
    } on ApiException catch (e) {
      if (!context.mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!context.mounted) return;
      context.appError(l10n.profileChangeSubmitFailed);
    }
  }
}

/// 详情弹窗（按 batchId 拉一次）。
class _MyBatchDetailDialog extends ConsumerWidget {
  const _MyBatchDetailDialog({required this.batchId});
  final String batchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(myProfileChangeDetailProvider(batchId));
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.profileChangeDiffTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Flexible(
                child: async.when(
                  data: (batch) => SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final item in batch.items)
                          ProfileChangeDiffRow(
                            item: item,
                            showStatusBadge: true,
                          ),
                      ],
                    ),
                  ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) =>
                      Text(e is ApiException ? e.message : e.toString()),
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Align(
                alignment: Alignment.centerRight,
                child: UtenButton(
                  type: UtenButtonType.ghost,
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.profileChangeCancel2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
