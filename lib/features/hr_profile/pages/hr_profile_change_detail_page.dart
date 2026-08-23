// HR 个人修改审批详情（/hr/profile-changes/:id）
// 详情页全断点套 UtenContentContainer.narrow（maxWidth 1120）。
// 文档：docs/03-页面/我的页.md（§HR 端：员工修改审批 — 详情）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../profile/models/profile_change_request.dart';
import '../../profile/providers/profile_change_providers.dart';
import '../../profile/repositories/profile_change_repository.dart';
import '../../profile/widgets/profile_change_diff_row.dart';
import '../../../shared/auth/pending_review_provider.dart';

class HrProfileChangeDetailPage extends ConsumerStatefulWidget {
  const HrProfileChangeDetailPage({super.key, required this.batchId});
  final String batchId;

  @override
  ConsumerState<HrProfileChangeDetailPage> createState() =>
      _HrProfileChangeDetailPageState();
}

class _HrProfileChangeDetailPageState
    extends ConsumerState<HrProfileChangeDetailPage> {
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(hrProfileChangeDetailProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(hrProfileChangeDetailProvider(widget.batchId));

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.profileChangeDiffTitle,
        showBackButton: true,
      ),
      body: async.when(
        data: (batch) => _buildBody(context, l10n, batch),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => UtenEmpty.error(
          message: e is ApiException ? e.message : l10n.commonError,
          actionLabel: l10n.commonRetry,
          onAction: () => ref.invalidate(hrProfileChangeDetailProvider),
        ),
      ),
      bottomNavigationBar: async.maybeWhen(
        data: (batch) => batch.status == ProfileChangeStatus.pending
            ? UtenBottomActionBar(
                child: Row(
                  children: [
                    Expanded(
                      child: UtenButton(
                        type: UtenButtonType.danger,
                        isExpanded: true,
                        isLoading: _acting,
                        onPressed: _acting
                            ? null
                            : () => _onReject(context, l10n),
                        child: Text(l10n.profileChangeReviewReject),
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      flex: 2,
                      child: UtenButton(
                        isExpanded: true,
                        isLoading: _acting,
                        onPressed: _acting
                            ? null
                            : () => _onApprove(context, l10n),
                        child: Text(l10n.profileChangeReviewApprove),
                      ),
                    ),
                  ],
                ),
              )
            : null,
        orElse: () => null,
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    ProfileChangeBatch batch,
  ) {
    final theme = Theme.of(context);
    // 详情页全断点窄版收敛（1120），避免宽屏 diff 行被拉得过长
    return UtenContentContainer.narrow(
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        children: [
          // 员工摘要卡
          UtenCard(
            child: Row(
              children: [
                UtenUserAvatar(name: batch.employeeName, size: 44),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        batch.employeeName ?? '—',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        batch.employeeCode ?? '—',
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
          const SizedBox(height: UtenSpacing.s12),

          // 提交信息
          UtenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l10n.profileChangeSubmittedAt}：${_formatTime(batch.submittedAt)}',
                  style: theme.textTheme.bodySmall,
                ),
                if (batch.submittedByName != null) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '${l10n.profileChangeReviewer}：${batch.submittedByName!}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (batch.reviewedAt != null) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '${l10n.profileChangeReviewer}：${batch.reviewedByName ?? '—'} · ${_formatTime(batch.reviewedAt!)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (batch.reviewComment != null &&
                    batch.reviewComment!.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Container(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainer,
                      borderRadius: UtenRadius.mdAll,
                    ),
                    child: Text(
                      '${l10n.profileChangeReviewComment}：${batch.reviewComment!}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),

          // 字段 diff 列表
          UtenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
                  child: Text(
                    l10n.profileChangeDiffTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Divider(height: 1),
                for (int i = 0; i < batch.items.length; i++) ...[
                  ProfileChangeDiffRow(
                    item: batch.items[i],
                    showStatusBadge: true,
                  ),
                  if (i < batch.items.length - 1) const Divider(height: 1),
                ],
              ],
            ),
          ),
          const SizedBox(height: 80), // 底部固定操作栏留白
        ],
      ),
    );
  }

  Future<void> _onApprove(BuildContext context, AppLocalizations l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.profileChangeApproveDialogTitle),
        content: Text(l10n.profileChangeApproveDialogBody),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.profileChangeCancel2),
          ),
          UtenButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.profileChangeConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    setState(() => _acting = true);
    try {
      await ref
          .read(profileChangeRepositoryProvider)
          .review(widget.batchId, 'approve', null);
      if (!context.mounted) return;
      ref.invalidate(hrProfileChangesProvider);
      ref.invalidate(hrProfileChangeDetailProvider);
      ref.read(pendingReviewCountProvider.notifier).refresh();
      context.appSuccess(l10n.profileChangeApproveSuccess);
      context.pop();
    } on ApiException catch (e) {
      if (!context.mounted) return;
      context.appApiError(e);
    } catch (_) {
      if (!context.mounted) return;
      context.appError(l10n.profileChangeSubmitFailed);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _onReject(BuildContext context, AppLocalizations l10n) async {
    final ctrl = TextEditingController();
    final reason = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.profileChangeRejectDialogTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.profileChangeRejectReasonHint,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: UtenSpacing.s12),
              UtenInput(
                label: l10n.profileChangeReviewComment,
                controller: ctrl,
                maxLines: 3,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return l10n.profileChangeRejectReasonRequired;
                  }
                  return null;
                },
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.profileChangeCancel2),
            ),
            UtenButton(
              type: UtenButtonType.danger,
              onPressed: () {
                if (ctrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, ctrl.text.trim());
              },
              child: Text(l10n.profileChangeReviewReject),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (reason == null || reason.isEmpty) return;
    if (!context.mounted) return;
    setState(() => _acting = true);
    try {
      await ref
          .read(profileChangeRepositoryProvider)
          .review(widget.batchId, 'reject', reason);
      if (!context.mounted) return;
      ref.invalidate(hrProfileChangesProvider);
      ref.invalidate(hrProfileChangeDetailProvider);
      ref.read(pendingReviewCountProvider.notifier).refresh();
      context.appSuccess(l10n.profileChangeRejectSuccess);
      context.pop();
    } on ApiException catch (e) {
      if (!context.mounted) return;
      context.appApiError(e);
    } catch (_) {
      if (!context.mounted) return;
      context.appError(l10n.profileChangeSubmitFailed);
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
