// 访客预约详情：状态 + 信息 + 已批准显示二维码凭证 + 审批轨迹。
//
// 响应式：访客流程不经主外壳，全断点自套 UtenContentContainer.narrow
//（详情页宜窄，宽屏居中不拉宽，水平 gutter 由容器提供）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/scale.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/visitor_application.dart';
import '../providers/visitor_providers.dart';
import '../widgets/visitor_qr_widget.dart';
import '../widgets/visitor_status_ui.dart';

class VisitorApplicationDetailPage extends ConsumerWidget {
  const VisitorApplicationDetailPage({super.key, required this.applicationId});
  final String applicationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final detail = ref.watch(visitorApplicationDetailProvider(applicationId));

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.visitorDetailTitle,
        showBackButton: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(visitorApplicationDetailProvider(applicationId)),
          ),
        ],
      ),
      body: detail.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(
          message: '$e',
          actionLabel: l10n.commonRetry,
          onAction: () => ref.invalidate(visitorApplicationDetailProvider(applicationId)),
        ),
        data: (d) {
          final app = d.application;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            // 详情窄收敛（全断点）：水平 gutter 由容器提供
            child: UtenContentContainer.narrow(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusCard(app: app),
                  const SizedBox(height: UtenSpacing.s16),
                  if (app.status == VisitorApplicationStatus.approved &&
                      app.qrToken != null && app.qrToken!.isNotEmpty) ...[
                    UtenCard(
                      padding: const EdgeInsets.all(UtenSpacing.s20),
                      child: Column(
                        children: [
                          UtenSectionHeader(title: l10n.visitorDetailQr, icon: Icons.qr_code_2_rounded),
                          const SizedBox(height: UtenSpacing.s16),
                          Center(child: VisitorQrWidget(token: app.qrToken!)),
                          const SizedBox(height: UtenSpacing.s12),
                          Text(l10n.visitorDetailQrHint,
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center),
                          const SizedBox(height: UtenSpacing.s16),
                          Text(l10n.visitorPasscodeLabel,
                              style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(height: UtenSpacing.s4),
                          Text(app.passcode ?? '',
                              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 6,
                                  fontFeatures: const [FontFeature.tabularFigures()])),
                        ],
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                  ],
                  UtenCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        UtenSectionHeader(title: l10n.visitorDetailPurpose, icon: Icons.description_outlined),
                        UtenInfoRow(label: l10n.visitorApplyName, value: app.visitorName),
                        UtenInfoRow(
                            label: l10n.visitorDetailHost,
                            value: app.hostName ?? app.hostDepartment ?? '—'),
                        UtenInfoRow(
                            label: l10n.visitorDetailVisitTime, value: fmtDateTime(app.plannedVisitAt)),
                        if (app.hasVehicle && app.plateNo != null)
                          UtenInfoRow(label: l10n.securityPlate, value: app.plateNo),
                        UtenInfoRow(label: l10n.visitorDetailAppliedAt, value: fmtDateTime(app.appliedAt)),
                        if (app.approvedAt != null)
                          UtenInfoRow(
                              label: l10n.visitorDetailApprovedAt, value: fmtDateTime(app.approvedAt!)),
                        if (app.rejectReason != null && app.rejectReason!.isNotEmpty)
                          UtenInfoRow(label: l10n.visitorDetailRejectReason, value: app.rejectReason),
                      ],
                    ),
                  ),
                  if (d.steps.isNotEmpty) ...[
                    const SizedBox(height: UtenSpacing.s16),
                    UtenCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          UtenSectionHeader(title: l10n.visitorDetailTimeline, icon: Icons.timeline_rounded),
                          const SizedBox(height: UtenSpacing.s12),
                          for (final s in d.steps) _StepRow(step: s),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: UtenSpacing.s24),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.app});
  final VisitorApplication app;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: visitorStatusColor(app.status).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(visitorStatusIcon(app.status), color: visitorStatusColor(app.status), size: context.scaled(28)),
          ),
          const SizedBox(width: UtenSpacing.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: visitorStatusLabel(app.status, l10n),
                  type: visitorBadgeType(app.status),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(app.visitPurpose,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});
  final VisitorApprovalStep step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_actionIcon(step.action), size: 18, color: UtenColors.teal600),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.actorName, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                if (step.comment != null && step.comment!.isNotEmpty)
                  Text(step.comment!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                Text(fmtDateTime(step.actedAt),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _actionIcon(String action) => switch (action) {
        'submit' => Icons.send_rounded,
        'forward' => Icons.forward_to_inbox_rounded,
        'hostConfirm' => Icons.how_to_reg_rounded,
        'hostReject' => Icons.person_off_rounded,
        'approve' => Icons.check_circle_rounded,
        'reject' => Icons.cancel_rounded,
        'checkIn' => Icons.login_rounded,
        _ => Icons.circle_outlined,
      };
}
