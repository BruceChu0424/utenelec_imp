// HR 个人修改审批详情（/hr/profile-changes/:id）
// 详情页全断点套默认 UtenContentContainer（正文随可用宽度铺满）。
// 文档：docs/03-页面/我的页.md（§HR 端：员工修改审批 — 详情）

import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_batch_reject_dialog.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../profile/models/profile_change_request.dart';
import '../../profile/providers/profile_change_providers.dart';
import '../../profile/repositories/profile_change_repository.dart';
import '../../profile/widgets/profile_change_diff_row.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';

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
  bool _confirming = false;
  int _actionEpoch = 0;
  ModalRoute<dynamic>? _reviewDialogRoute;

  @override
  void initState() {
    super.initState();
    ref.listenManual(authenticatedScopeProvider, (previous, next) {
      if (previous != next) _invalidateReviewIntent();
    });
    ref.listenManual(apiBaseUrlProvider, (previous, next) {
      if (previous != next) _invalidateReviewIntent();
    });
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (previous != next) _invalidateReviewIntent();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(hrProfileChangeDetailProvider);
    });
  }

  @override
  void didUpdateWidget(covariant HrProfileChangeDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.batchId != widget.batchId) _invalidateReviewIntent();
  }

  void _invalidateReviewIntent() {
    _actionEpoch++;
    _acting = false;
    _confirming = false;
    final route = _reviewDialogRoute;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
      if (mounted) setState(() {});
    });
  }

  Widget _reviewDialog(BuildContext context, Widget child, int epoch) {
    _reviewDialogRoute = ModalRoute.of(context);
    if (epoch != _actionEpoch) {
      final route = _reviewDialogRoute;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route?.isActive == true) route!.navigator?.removeRoute(route);
      });
      return const SizedBox.shrink();
    }
    return child;
  }

  Future<
    ({
      String batchId,
      int epoch,
      ProfileChangeRepository repository,
      AuthenticatedRequestScope scope,
    })
  >
  _captureReviewIntent() async {
    final batchId = widget.batchId;
    final epoch = ++_actionEpoch;
    final owner = ref.read(authenticatedScopeProvider);
    final repository = ref.read(profileChangeRepositoryProvider);
    final baseUrl = ref.read(apiBaseUrlProvider);
    bool current() =>
        mounted &&
        epoch == _actionEpoch &&
        widget.batchId == batchId &&
        owner != null &&
        !owner.readOnly &&
        ref.read(authenticatedScopeProvider) == owner &&
        ref.read(apiBaseUrlProvider) == baseUrl &&
        locationAllowedFor(
          ref.read(currentPermissionsProvider),
          ref.read(isSuperAdminProvider),
          RouteName.hrProfileChanges,
        ) &&
        ref.read(hrProfileChangeDetailProvider(batchId)).valueOrNull?.status ==
            ProfileChangeStatus.pending;
    final scope = await ref
        .read(apiClientProvider)
        .captureRequestScope(isCurrent: current);
    return (
      batchId: batchId,
      epoch: epoch,
      repository: repository,
      scope: scope,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(hrProfileChangeDetailProvider(widget.batchId));

    return Scaffold(
      appBar: const UtenAppBar(title: '员工信息修改', showBackButton: true),
      body: async.when(
        data: (batch) => _buildBody(context, l10n, batch),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => UtenEmpty.error(
          message: e is ApiException ? e.message : l10n.commonError,
          actionLabel: l10n.commonRetry,
          onAction: () => ref.invalidate(hrProfileChangeDetailProvider),
        ),
      ),
      // 2026-09-14 UI 统一口径：吸底操作条改右下悬浮组（大小/高度/禁用态全站统一）。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: async.maybeWhen(
        data: (batch) => batch.status == ProfileChangeStatus.pending
            ? UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    type: UtenButtonType.danger,
                    size: UtenButtonSize.large,
                    isLoading: _acting,
                    onPressed: _acting || _confirming
                        ? null
                        : () => _onReject(context, l10n),
                    child: Text(l10n.profileChangeReviewReject),
                  ),
                  UtenButton(
                    size: UtenButtonSize.large,
                    isLoading: _acting,
                    onPressed: _acting || _confirming
                        ? null
                        : () => _onApprove(context, l10n),
                    child: Text(l10n.profileChangeReviewApprove),
                  ),
                ],
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
    // 默认容器不设固定最大宽度，详情正文随导航收起和窗口加宽扩展。
    return UtenContentContainer(
      child: ListView(
        // 底部留出右下悬浮操作组的高度，末段内容可滚出按钮区。
        padding: const EdgeInsets.fromLTRB(
          0,
          UtenSpacing.s16,
          0,
          UtenFloatingActionGroup.scrollClearance,
        ),
        children: [
          // 员工与提交信息合为摘要；待审字段差异保持独立常显。
          UtenDetailSummaryCard(
            key: ValueKey('hr-profile-summary-${batch.batchId}'),
            heading: Row(
              children: [
                UtenUserAvatar(name: batch.employeeName, size: 44),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(child: Text(batch.employeeName ?? '—')),
              ],
            ),
            status: UtenStatusBadge(
              label: switch (batch.status) {
                ProfileChangeStatus.pending => l10n.profileChangeStatusPending,
                ProfileChangeStatus.applied => l10n.profileChangeStatusApplied,
                ProfileChangeStatus.approved =>
                  l10n.profileChangeStatusApproved,
                ProfileChangeStatus.rejected =>
                  l10n.profileChangeStatusRejected,
                ProfileChangeStatus.cancelled =>
                  l10n.profileChangeStatusCancelled,
              },
              type: profileChangeStatusBadgeType(batch.status),
            ),
            facts: [
              UtenSummaryField(label: '员工工号', value: batch.employeeCode),
              UtenSummaryField(
                label: l10n.profileChangeSubmittedAt,
                value: _formatTime(batch.submittedAt),
              ),
              if (batch.submittedByName != null)
                UtenSummaryField(label: '提交人', value: batch.submittedByName),
            ],
            details: [
              if (batch.reviewedAt != null)
                UtenSummaryField(
                  label: l10n.profileChangeReviewer,
                  value:
                      '${batch.reviewedByName ?? '—'} · ${_formatTime(batch.reviewedAt!)}',
                ),
            ],
            notices: [
              if (batch.reviewComment != null &&
                  batch.reviewComment!.isNotEmpty)
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
    if (_acting || _confirming) return;
    setState(() => _confirming = true);
    final actionEpoch = _actionEpoch + 1;
    try {
      final intent = await _captureReviewIntent();
      if (!context.mounted || !intent.scope.isCurrent) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => _reviewDialog(
          ctx,
          UtenAlertDialog(
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
          intent.epoch,
        ),
      );
      if (ok != true) return;
      if (!context.mounted || !intent.scope.isCurrent) return;
      setState(() {
        _confirming = false;
        _acting = true;
      });
      await intent.scope.run(
        () => intent.repository.review(intent.batchId, 'approve', null),
      );
      if (!context.mounted || !intent.scope.isCurrent) return;
      ref.invalidate(hrProfileChangesProvider);
      ref.invalidate(hrProfileEmployeePendingProvider);
      ref.invalidate(hrProfileChangeQueueProvider);
      ref.invalidate(hrProfileChangeFacetsProvider);
      ref.invalidate(myProfileChangesProvider);
      ref.invalidate(myProfileChangeDetailProvider(intent.batchId));
      ref.invalidate(myEmployeeProfileProvider);
      ref.invalidate(hrProfileChangeDetailProvider);
      refreshBadges(ref);
      context.appSuccess(l10n.profileChangeApproveSuccess);
      // 审批后回队列：pop 优先（员工档案 pending 区 push 进来时回档案）；
      // 队列列表入口是 go（栈内无可 pop 项），裸 pop 会抛 GoError 被下面 catch
      // 吞掉，成功操作反而弹「失败」——backTo 的栈空兜底归位变更队列。
      backTo(context, defaultPath: RouteName.hrProfileChanges);
    } on ApiException catch (e) {
      if (!context.mounted || actionEpoch != _actionEpoch) return;
      context.appApiError(e);
    } catch (_) {
      if (!context.mounted || actionEpoch != _actionEpoch) return;
      context.appError(l10n.profileChangeSubmitFailed);
    } finally {
      if (mounted && actionEpoch == _actionEpoch) {
        setState(() {
          _acting = false;
          _confirming = false;
        });
      }
    }
  }

  Future<void> _onReject(BuildContext context, AppLocalizations l10n) async {
    if (_acting || _confirming) return;
    setState(() => _confirming = true);
    final actionEpoch = _actionEpoch + 1;
    try {
      final intent = await _captureReviewIntent();
      if (!context.mounted || !intent.scope.isCurrent) return;
      final reason = await showDialog<String>(
        context: context,
        builder: (ctx) => _reviewDialog(
          ctx,
          UtenBatchRejectDialog(
            count: 1,
            actionLabel: '信息变更审核',
            subjectLabel: '修改申请',
            title: l10n.profileChangeRejectDialogTitle,
            description: l10n.profileChangeRejectReasonHint,
            confirmLabel: l10n.profileChangeReviewReject,
          ),
          intent.epoch,
        ),
      );
      if (reason == null || reason.isEmpty) return;
      if (!context.mounted || !intent.scope.isCurrent) return;
      setState(() {
        _confirming = false;
        _acting = true;
      });
      await intent.scope.run(
        () => intent.repository.review(intent.batchId, 'reject', reason),
      );
      if (!context.mounted || !intent.scope.isCurrent) return;
      ref.invalidate(hrProfileChangesProvider);
      ref.invalidate(hrProfileEmployeePendingProvider);
      ref.invalidate(hrProfileChangeQueueProvider);
      ref.invalidate(hrProfileChangeFacetsProvider);
      ref.invalidate(myProfileChangesProvider);
      ref.invalidate(myProfileChangeDetailProvider(intent.batchId));
      ref.invalidate(hrProfileChangeDetailProvider);
      refreshBadges(ref);
      context.appSuccess(l10n.profileChangeRejectSuccess);
      backTo(context, defaultPath: RouteName.hrProfileChanges);
    } on ApiException catch (e) {
      if (!context.mounted || actionEpoch != _actionEpoch) return;
      context.appApiError(e);
    } catch (_) {
      if (!context.mounted || actionEpoch != _actionEpoch) return;
      context.appError(l10n.profileChangeSubmitFailed);
    } finally {
      if (mounted && actionEpoch == _actionEpoch) {
        setState(() {
          _acting = false;
          _confirming = false;
        });
      }
    }
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
