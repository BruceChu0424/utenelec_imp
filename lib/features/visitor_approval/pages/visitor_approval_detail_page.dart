// 访客审批详情（HR）：查看 + 批准/拒绝/转接待人确认。
//
// 响应式：详情页走窄收敛——compact 自套 UtenContentContainer.narrow
//（medium+ 外壳已收敛，不叠加 gutter）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
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
import '../providers/visitor_notice_bridge.dart';
import '../providers/visitor_pending_count_provider.dart';

class VisitorApprovalDetailPage extends ConsumerWidget {
  const VisitorApprovalDetailPage({super.key, required this.applicationId});
  final String applicationId;

  Future<void> _action(
    BuildContext context,
    WidgetRef ref,
    String action, {
    String? comment,
    String? rejectReason,
  }) async {
    try {
      final app = await ref
          .read(visitorStaffRepositoryProvider)
          .action(
            applicationId,
            action: action,
            comment: comment,
            rejectReason: rejectReason,
          );
      if (!context.mounted) return;
      ref.invalidate(visitorApprovalDetailProvider(applicationId));
      // 审批动作改变待办数，立即刷新徽章
      ref.read(visitorPendingCountProvider.notifier).refresh();
      // 审批事件 → 工作通知：通过/驳回/转接待自动生成 Notice 并弹到达提醒
      await notifyVisitorApprovalOutcome(
        context,
        ref,
        app: app,
        action: action,
        rejectReason: rejectReason,
      );
    } on ApiException catch (e) {
      if (context.mounted) {
        context.appApiError(
          e,
          fallback: AppLocalizations.of(context).commonError,
        );
      }
    } catch (_) {
      if (context.mounted) {
        context.appError(AppLocalizations.of(context).commonError);
      }
    }
  }

  Future<void> _approve(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final ok = await UtenDialog.show(
      context,
      title: l10n.visitorApprovalApprove,
      content: Text(l10n.visitorApprovalConfirmApprove),
      confirmLabel: l10n.visitorApprovalApprove,
      cancelLabel: l10n.commonCancel,
    );
    if (ok == true && context.mounted) {
      await _action(context, ref, 'approve');
    }
  }

  Future<void> _reject(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctl = TextEditingController();
        return AlertDialog(
          title: Text(l10n.visitorApprovalReject),
          content: UtenInput(
            controller: ctl,
            label: l10n.visitorApprovalRejectReasonHint,
            maxLines: 2,
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
    if (reason != null && context.mounted) {
      await _action(
        context,
        ref,
        'reject',
        rejectReason: reason.isEmpty ? null : reason,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final detail = ref.watch(visitorApprovalDetailProvider(applicationId));
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.visitorApprovalTitle,
        showBackButton: true,
      ),
      body: detail.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(
          message: '$e',
          actionLabel: l10n.commonRetry,
          onAction: () =>
              ref.invalidate(visitorApprovalDetailProvider(applicationId)),
        ),
        data: (d) {
          final app = d.application;
          final canApprove =
              app.status == VisitorApplicationStatus.pending ||
              app.status == VisitorApplicationStatus.hostReviewing;
          final canForward = app.status == VisitorApplicationStatus.pending;
          final isCompact = context.breakpoint.isCompact;
          Widget content = SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isCompact ? 0 : UtenSpacing.s16,
              vertical: UtenSpacing.s16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      UtenSectionHeader(
                        title: l10n.visitorDetailPurpose,
                        icon: Icons.description_outlined,
                      ),
                      UtenInfoRow(
                        label: l10n.visitorApplyName,
                        value: app.visitorName,
                        isImportant: true,
                      ),
                      UtenInfoRow(
                        label: l10n.visitorDetailHost,
                        value: app.hostName ?? app.hostDepartment ?? '—',
                      ),
                      UtenInfoRow(
                        label: l10n.visitorDetailVisitTime,
                        value: fmtDateTime(app.plannedVisitAt),
                      ),
                      if (app.hasVehicle && app.plateNo != null)
                        UtenInfoRow(
                          label: l10n.securityPlate,
                          value: app.plateNo,
                        ),
                      UtenInfoRow(
                        label: l10n.visitorDetailAppliedAt,
                        value: fmtDateTime(app.appliedAt),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
          if (isCompact) content = UtenContentContainer.narrow(child: content);
          return Column(
            children: [
              Expanded(child: content),
              if (canApprove || canForward)
                UtenBottomActionBar(
                  child: Row(
                    children: [
                      if (canForward) ...[
                        Expanded(
                          child: UtenButton(
                            type: UtenButtonType.secondary,
                            onPressed: () => _action(context, ref, 'forward'),
                            child: Text(l10n.visitorApprovalForward),
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                      ],
                      Expanded(
                        child: UtenButton(
                          type: UtenButtonType.danger,
                          onPressed: canApprove
                              ? () => _reject(context, ref, l10n)
                              : null,
                          child: Text(l10n.visitorApprovalReject),
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenButton(
                          onPressed: canApprove
                              ? () => _approve(context, ref, l10n)
                              : null,
                          child: Text(l10n.visitorApprovalApprove),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
