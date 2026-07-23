// 访客审批列表(HR)：待审批 / 已批准 / 已拒绝。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../visitor/models/visitor_application.dart';
import '../../visitor/widgets/visitor_status_ui.dart';
import '../providers/visitor_approval_providers.dart';

enum ApprovalTab { pending, approved, rejected }

class VisitorApprovalListPage extends ConsumerStatefulWidget {
  const VisitorApprovalListPage({super.key});

  @override
  ConsumerState<VisitorApprovalListPage> createState() => _VisitorApprovalListPageState();
}

class _VisitorApprovalListPageState extends ConsumerState<VisitorApprovalListPage> {
  ApprovalTab _tab = ApprovalTab.pending;

  String? get _status => switch (_tab) {
        ApprovalTab.pending => null,
        ApprovalTab.approved => 'approved',
        ApprovalTab.rejected => 'rejected',
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final list = ref.watch(visitorApprovalListProvider(_status));
    return Scaffold(
      appBar: UtenAppBar(title: l10n.visitorApprovalTitle, showBackButton: true),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: UtenSegmentedFilter<ApprovalTab>(
              selected: _tab,
              onChanged: (v) => setState(() => _tab = v),
              segments: [
                UtenSegment(value: ApprovalTab.pending, label: l10n.visitorApprovalPending),
                UtenSegment(value: ApprovalTab.approved, label: l10n.visitorFilterApproved),
                UtenSegment(value: ApprovalTab.rejected, label: l10n.visitorFilterRejected),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(visitorApprovalListProvider(_status)),
              child: list.when(
                loading: () => const UtenSkeletonList(itemCount: 6),
                error: (e, _) => UtenEmpty.error(
                  message: '$e',
                  actionLabel: l10n.commonRetry,
                  onAction: () => ref.invalidate(visitorApprovalListProvider(_status)),
                ),
                data: (items) {
                  if (items.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 80),
                        UtenEmpty(icon: Icons.checklist_outlined, message: l10n.visitorApprovalEmpty),
                      ],
                    );
                  }
                  return SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    child: UtenResponsiveGrid(
                      itemCount: items.length,
                      itemBuilder: (context, i, _) => _ApprovalCard(
                        app: items[i],
                        onTap: () => context.go('/visitor-approval/${items[i].id}'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.app, required this.onTap});
  final VisitorApplication app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return UtenCard(
      onTap: onTap,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(app.visitorName,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              UtenStatusBadge(
                label: visitorStatusLabel(app.status, l10n),
                type: visitorBadgeType(app.status),
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(app.visitPurpose,
              style: theme.textTheme.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Text(
            '${l10n.visitorDetailHost}: ${app.hostName ?? '—'} · ${fmtDateTime(app.plannedVisitAt)}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
