// 访客审批详情（HR）：查看 + 批准/拒绝/转接待人确认。
//
// 响应式：详情页走窄收敛——compact 自套 UtenContentContainer.narrow
//（medium+ 外壳已收敛，不叠加 gutter）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../visitor/models/visitor_application.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../visitor/widgets/visitor_status_ui.dart';
import '../providers/visitor_approval_providers.dart';
import '../../../shared/badges/badge_registry.dart';

class VisitorApprovalDetailPage extends ConsumerStatefulWidget {
  const VisitorApprovalDetailPage({super.key, required this.applicationId});
  final String applicationId;

  @override
  ConsumerState<VisitorApprovalDetailPage> createState() =>
      _VisitorApprovalDetailPageState();
}

class _VisitorApprovalDetailPageState
    extends ConsumerState<VisitorApprovalDetailPage> {
  /// 审批动作网络段的全屏忙碌标题。此前确认弹窗一关网络就裸跑：按钮无转圈、
  /// 可连点，「转接待人」甚至没有确认框——点了像没反应（2026-10-18 修复）。
  String? _busyTitle;

  Future<void> _action(
    String action, {
    String? comment,
    String? rejectReason,
  }) async {
    if (_busyTitle != null) return;
    final l10n = AppLocalizations.of(context);
    final busyTitle = switch (action) {
      'approve' => l10n.visitorApprovalApprove,
      'reject' => l10n.visitorApprovalReject,
      _ => l10n.visitorApprovalForward,
    };
    setState(() => _busyTitle = busyTitle);
    try {
      await ref
          .read(visitorStaffRepositoryProvider)
          .action(
            widget.applicationId,
            action: action,
            comment: comment,
            rejectReason: rejectReason,
          );
      if (!mounted) return;
      ref.invalidate(visitorApprovalDetailProvider(widget.applicationId));
      // 审批动作改变列表状态：审批列表可能保活在其它分支/栈下，
      // 不失效的话返回后仍显示「待审批」老状态。
      ref.invalidate(visitorApprovalListProvider);
      ref.invalidate(myAsHostProvider);
      // 状态桶计数（facets）随动作变化，一并失效。
      ref.invalidate(visitorApprovalFacetsProvider);
      // 审批动作改变待办数，立即刷新徽章
      refreshBadges(ref);
      context.appSuccess(switch (action) {
        'approve' => l10n.visitorApprovalDoneApprove,
        'reject' => l10n.visitorApprovalDoneReject,
        'forward' => l10n.visitorApprovalDoneForward,
        _ => l10n.visitorApprovalDoneFallback,
      });
    } on ApiException catch (e) {
      if (mounted) {
        context.appApiError(
          e,
          fallback: AppLocalizations.of(context).commonError,
        );
      }
    } catch (_) {
      if (mounted) {
        context.appError(AppLocalizations.of(context).commonError);
      }
    } finally {
      if (mounted) setState(() => _busyTitle = null);
    }
  }

  Future<void> _approve() async {
    final l10n = AppLocalizations.of(context);
    final ok = await UtenDialog.show(
      context,
      title: l10n.visitorApprovalApprove,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenReviewerResponsibilityNotice(
            actionLabel: l10n.visitorApprovalApproveNoticeLabel,
            description: l10n.visitorApprovalApproveNoticeDesc,
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(l10n.visitorApprovalConfirmApprove),
        ],
      ),
      confirmLabel: l10n.visitorApprovalApprove,
      cancelLabel: l10n.commonCancel,
    );
    if (ok == true && mounted) {
      await _action('approve');
    }
  }

  Future<void> _reject() async {
    final l10n = AppLocalizations.of(context);
    final ctl = TextEditingController();
    late final String? reason;
    try {
      reason = await UtenDialog.showAndWaitForExit<String>(
        context,
        builder: (ctx) {
          return UtenAlertDialog(
            title: Text(l10n.visitorApprovalReject),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UtenReviewerResponsibilityNotice(
                    actionLabel: l10n.visitorApprovalRejectNoticeLabel,
                    description: l10n.visitorApprovalRejectNoticeDesc,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  UtenInput(
                    controller: ctl,
                    label: l10n.visitorApprovalRejectReasonHint,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              UtenButton(
                type: UtenButtonType.ghost,
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.commonCancel),
              ),
              UtenButton(
                type: UtenButtonType.danger,
                onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
                child: Text(l10n.visitorApprovalReject),
              ),
            ],
          );
        },
      );
    } finally {
      ctl.dispose();
    }
    if (reason != null && mounted) {
      await _action('reject', rejectReason: reason.isEmpty ? null : reason);
    }
  }

  Future<void> _forward() async {
    final l10n = AppLocalizations.of(context);
    final ok = await UtenDialog.show(
      context,
      title: l10n.visitorApprovalForward,
      content: const Text('将转给本次来访的接待人确认；转出后由接待人继续办理。'), // TODO(l10n): 补 arb
      confirmLabel: l10n.visitorApprovalForward,
      cancelLabel: l10n.commonCancel,
    );
    if (ok == true && mounted) {
      await _action('forward');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final detail = ref.watch(
      visitorApprovalDetailProvider(widget.applicationId),
    );
    final busy = _busyTitle != null;
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.visitorApprovalTitle,
        showBackButton: true,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          detail.when(
            loading: () => const UtenSkeletonList(itemCount: 4),
            error: (e, _) => UtenEmpty.error(
              message: '$e',
              actionLabel: l10n.commonRetry,
              onAction: () => ref.invalidate(
                visitorApprovalDetailProvider(widget.applicationId),
              ),
            ),
            data: (d) {
              final app = d.application;
              final isCompact = context.breakpoint.isCompact;
              Widget content = SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  isCompact ? 0 : UtenSpacing.s16,
                  UtenSpacing.s16,
                  isCompact ? 0 : UtenSpacing.s16,
                  // 底部留出右下悬浮操作组的高度，末段内容可滚出按钮区。
                  UtenFloatingActionGroup.scrollClearance,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    UtenDetailSummaryCard(
                      key: ValueKey('visitor-approval-summary-${app.id}'),
                      heading: Text(app.visitPurpose),
                      status: UtenStatusBadge(
                        label: visitorStatusLabel(app.status, l10n),
                        type: visitorBadgeType(app.status),
                        icon: visitorStatusIcon(app.status),
                      ),
                      facts: [
                        UtenSummaryField(
                          label: l10n.visitorApplyName,
                          value: app.visitorName,
                          emphasis: true,
                        ),
                        UtenSummaryField(
                          label: l10n.visitorDetailHost,
                          value: app.hostName ?? app.hostDepartment,
                        ),
                        UtenSummaryField(
                          label: l10n.visitorDetailVisitTime,
                          value: fmtDateTime(app.plannedVisitAt),
                        ),
                        if (app.hasVehicle && app.plateNo != null)
                          UtenSummaryField(
                            label: l10n.securityPlate,
                            value: app.plateNo,
                          ),
                      ],
                      details: [
                        UtenSummaryField(
                          label: l10n.visitorDetailAppliedAt,
                          value: fmtDateTime(app.appliedAt),
                        ),
                      ],
                      notices: [
                        if (app.rejectReason != null &&
                            app.rejectReason!.isNotEmpty)
                          UtenSummaryField(
                            label: l10n.visitorDetailRejectReason,
                            value: app.rejectReason,
                            danger: true,
                          ),
                      ],
                    ),
                  ],
                ),
              );
              // compact 自套窄收敛；selectable:false——访客待办计数轮询与拖选并发有
              // CME 风险（准则 §3.4，用户口径：轮询页不包）。
              if (isCompact) {
                content = UtenContentContainer.narrow(
                  selectable: false,
                  child: content,
                );
              }
              return content;
            },
          ),
          if (busy) UtenBusyOverlay(title: _busyTitle!),
        ],
      ),
      // 2026-09-14 UI 统一口径：吸底操作条改右下悬浮组（大小/高度/禁用态全站统一）。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: busy
          ? null
          : detail.maybeWhen(
              data: (d) {
                final canApprove =
                    d.application.status == VisitorApplicationStatus.pending ||
                    d.application.status ==
                        VisitorApplicationStatus.hostReviewing;
                final canForward =
                    d.application.status == VisitorApplicationStatus.pending;
                if (!canApprove && !canForward) return null;
                return UtenFloatingActionGroup(
                  children: [
                    if (canForward)
                      UtenButton(
                        type: UtenButtonType.secondary,
                        size: UtenButtonSize.large,
                        onPressed: _forward,
                        child: Text(
                          AppLocalizations.of(context).visitorApprovalForward,
                        ),
                      ),
                    UtenButton(
                      type: UtenButtonType.danger,
                      size: UtenButtonSize.large,
                      onPressed: canApprove ? _reject : null,
                      child: Text(
                        AppLocalizations.of(context).visitorApprovalReject,
                      ),
                    ),
                    UtenButton(
                      size: UtenButtonSize.large,
                      onPressed: canApprove ? _approve : null,
                      child: Text(
                        AppLocalizations.of(context).visitorApprovalApprove,
                      ),
                    ),
                  ],
                );
              },
              orElse: () => null,
            ),
    );
  }
}
