// 访客审批详情（HR）：查看 + 批准/拒绝/转接待人确认。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../visitor/models/visitor_application.dart';
import '../../visitor/repositories/visitor_repository.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../visitor/widgets/visitor_status_ui.dart';
import '../providers/visitor_approval_providers.dart';

class VisitorApprovalDetailPage extends ConsumerWidget {
  const VisitorApprovalDetailPage({super.key, required this.applicationId});
  final String applicationId;

  Future<void> _action(WidgetRef ref, String action,
      {String? comment, String? rejectReason}) async {
    try {
      await ref.read(visitorStaffRepositoryProvider).action(applicationId,
          action: action, comment: comment, rejectReason: rejectReason);
      ref.invalidate(visitorApprovalDetailProvider(applicationId));
    } on ApiException catch (e) {
      ref.context.appApiError(e, fallback: AppLocalizations.of(ref.context).commonError);
    } catch (_) {
      ref.context.appError(AppLocalizations.of(ref.context).commonError);
    }
  }

  Future<void> _approve(BuildContext context, WidgetRef ref, AppLocalizations l10n) async {
    final ok = await UtenDialog.show(
      context,
      title: l10n.visitorApprovalApprove,
      content: Text(l10n.visitorApprovalConfirmApprove),
      confirmLabel: l10n.visitorApprovalApprove,
      cancelLabel: l10n.commonCancel,
    );
    if (ok == true) await _action(ref, 'approve');
  }

  Future<void> _reject(BuildContext context, WidgetRef ref, AppLocalizations l10n) async {
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
          actions: [
            UtenButton(type: UtenButtonType.ghost, onPressed: () => Navigator.pop(ctx), child: Text(l10n.commonCancel)),
            UtenButton(
              type: UtenButtonType.danger,
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: Text(l10n.visitorApprovalReject),
            ),
          ],
        );
      },
    );
    if (reason != null) await _action(ref, 'reject', rejectReason: reason.isEmpty ? null : reason);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final detail = ref.watch(visitorApprovalDetailProvider(applicationId));
    return Scaffold(
      appBar: UtenAppBar(title: l10n.visitorApprovalTitle, showBackButton: true),
      body: detail.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(
          message: '$e',
          actionLabel: l10n.commonRetry,
          onAction: () => ref.invalidate(visitorApprovalDetailProvider(applicationId)),
        ),
        data: (d) {
          final app = d.application;
          final canApprove = app.status == VisitorApplicationStatus.pending ||
              app.status == VisitorApplicationStatus.hostReviewing;
          final canForward = app.status == VisitorApplicationStatus.pending;
          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      UtenCard(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            UtenSectionHeader(title: l10n.visitorDetailPurpose, icon: Icons.description_outlined),
                            UtenInfoRow(label: l10n.visitorApplyName, value: app.visitorName, isImportant: true),
                            UtenInfoRow(
                                label: l10n.visitorDetailHost,
                                value: app.hostName ?? app.hostDepartment ?? '—'),
                            UtenInfoRow(
                                label: l10n.visitorDetailVisitTime, value: fmtDateTime(app.plannedVisitAt)),
                            if (app.hasVehicle && app.plateNo != null)
                              UtenInfoRow(label: l10n.securityPlate, value: app.plateNo),
                            UtenInfoRow(label: l10n.visitorDetailAppliedAt, value: fmtDateTime(app.appliedAt)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (canApprove || canForward)
                UtenBottomActionBar(
                  child: Row(
                    children: [
                      if (canForward) ...[
                        Expanded(
                          child: UtenButton(
                            type: UtenButtonType.secondary,
                            onPressed: () => _action(ref, 'forward'),
                            child: Text(l10n.visitorApprovalForward),
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: UtenButton(
                          type: UtenButtonType.danger,
                          onPressed: canApprove ? () => _reject(context, ref, l10n) : null,
                          child: Text(l10n.visitorApprovalReject),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: UtenButton(
                          onPressed: canApprove ? () => _approve(context, ref, l10n) : null,
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
