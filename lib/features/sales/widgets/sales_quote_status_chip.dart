// 报价单状态展示(ADR-134)：分桶 → 文案 / 徽章语义色，核价记录时间线。
//
// 颜色口径(适老化基线 13 §状态可见)：草稿中性灰、待财务核价黄(在财务手上)、财务退回红
// (要本人改)、已核价绿、作废灰。文字全部走 arb，列表、详情、财务核价页共用这一份。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_progress_timeline.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/progress_timeline_event.dart';
import '../models/sales_doc.dart';
import 'sales_quote_revision_comparison.dart';

/// 分桶文案。
String salesQuoteStageLabel(AppLocalizations l10n, String? stage) =>
    switch (stage) {
      SalesQuoteStage.draft => l10n.salesQuoteStatusDraft,
      SalesQuoteStage.financeRejected => l10n.salesQuoteStatusReturned,
      SalesQuoteStage.pendingFinance => l10n.salesQuoteStatusPendingFinance,
      SalesQuoteStage.awaitingCustomer => l10n.salesQuoteAwaitingCustomer,
      SalesQuoteStage.awaitingConversion => l10n.salesQuoteAwaitingConversion,
      SalesQuoteStage.approved => l10n.salesQuoteStatusConfirmed,
      SalesQuoteStage.reversed => l10n.salesQuoteStatusReversed,
      _ => '—',
    };

/// 分桶徽章语义色。
UtenStatusBadgeType salesQuoteStageBadgeType(String? stage) => switch (stage) {
  SalesQuoteStage.financeRejected => UtenStatusBadgeType.danger,
  SalesQuoteStage.pendingFinance => UtenStatusBadgeType.warning,
  SalesQuoteStage.approved => UtenStatusBadgeType.success,
  _ => UtenStatusBadgeType.neutral,
};

/// 分桶图标(颜色之外的第二重区分，色弱也能读)。
IconData salesQuoteStageIcon(String? stage) => switch (stage) {
  SalesQuoteStage.financeRejected => Icons.undo_rounded,
  SalesQuoteStage.pendingFinance => Icons.hourglass_top_rounded,
  SalesQuoteStage.approved => Icons.verified_rounded,
  SalesQuoteStage.reversed => Icons.block_rounded,
  _ => Icons.edit_note_rounded,
};

/// 报价状态文案：已核价且已转订货单时说「已转订货单」，否则按分桶。
String salesQuoteStatusText(
  AppLocalizations l10n, {
  required String? stage,
  bool converted = false,
  bool customerAccepted = false,
}) => stage == SalesQuoteStage.approved && converted
    ? l10n.salesQuoteStatusConverted
    : stage == SalesQuoteStage.approved
    ? customerAccepted
          ? l10n.salesQuoteAwaitingConversion
          : l10n.salesQuoteAwaitingCustomer
    : salesQuoteStageLabel(l10n, stage);

/// 报价状态徽章(列表状态列 / 详情表头)。
class SalesQuoteStatusChip extends StatelessWidget {
  const SalesQuoteStatusChip({
    super.key,
    required this.stage,
    this.converted = false,
    this.customerAccepted = false,
    this.size = UtenStatusBadgeSize.medium,
  });

  final String? stage;
  final bool converted;
  final bool customerAccepted;
  final UtenStatusBadgeSize size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return UtenStatusBadge(
      label: salesQuoteStatusText(
        l10n,
        stage: stage,
        converted: converted,
        customerAccepted: customerAccepted,
      ),
      type: salesQuoteStageBadgeType(stage),
      icon: salesQuoteStageIcon(stage),
      size: size,
    );
  }
}

/// 核价记录动作文案；未知动作码用服务端 actionLabel，再没有才说「其它记录」。
String salesQuoteRevisionActionLabel(
  AppLocalizations l10n,
  String action, {
  String? serverLabel,
}) => switch (action) {
  SalesQuoteRevisionAction.submit => l10n.salesQuoteStatusRevisionSubmit,
  SalesQuoteRevisionAction.withdraw => l10n.salesQuoteStatusRevisionWithdraw,
  SalesQuoteRevisionAction.financeEdit =>
    l10n.salesQuoteStatusRevisionFinanceEdit,
  SalesQuoteRevisionAction.returnToSales => l10n.salesQuoteStatusRevisionReturn,
  SalesQuoteRevisionAction.confirm => l10n.salesQuoteStatusRevisionConfirm,
  SalesQuoteRevisionAction.reopen => l10n.salesQuoteStatusRevisionReopen,
  SalesQuoteRevisionAction.financeReopen =>
    l10n.salesQuoteStatusRevisionFinanceReopen,
  _ => serverLabel ?? l10n.salesQuoteStatusRevisionOther,
};

/// 核价记录 → 快递式时间线事件(最新在最上；退回标红)。
List<ProgressTimelineEvent> salesQuoteRevisionEvents(
  AppLocalizations l10n,
  List<SalesQuoteRevision> revisions,
) {
  final sorted = [...revisions]
    ..sort((a, b) {
      final at = DateTime.tryParse(a.createdAt ?? '');
      final bt = DateTime.tryParse(b.createdAt ?? '');
      if (at != null && bt != null && at != bt) return bt.compareTo(at);
      return (b.revision ?? 0).compareTo(a.revision ?? 0);
    });
  return [
    for (var i = 0; i < sorted.length; i++)
      ProgressTimelineEvent(
        seq: sorted.length - i,
        code: sorted[i].action,
        title: salesQuoteRevisionActionLabel(
          l10n,
          sorted[i].action,
          serverLabel: sorted[i].actionLabel,
        ),
        operatorLabel: l10n.salesQuoteStatusRevisionOperator,
        operatorName: sorted[i].actorName,
        occurredAt: sorted[i].createdAt,
        state: sorted[i].action == SalesQuoteRevisionAction.returnToSales
            ? 'REJECTED'
            : 'DONE',
        detail: [
          if (sorted[i].revision != null)
            l10n.salesQuoteStatusRevisionVersion(sorted[i].revision!),
          ?sorted[i].reason,
          ?sorted[i].summary,
        ].join(' · '),
      ),
  ];
}

/// 核价记录卡(销售报价详情与财务核价页共用)。
class SalesQuoteRevisionTimeline extends StatelessWidget {
  const SalesQuoteRevisionTimeline({
    super.key,
    required this.revisions,
    this.title,
  });

  final List<SalesQuoteRevision> revisions;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      key: const Key('sales-quote-revision-timeline'),
      child: ExpansionTile(
        initiallyExpanded:
            revisions.length <= 3 ||
            revisions.where((r) => r.snapshot != null).length >= 2,
        leading: Icon(Icons.history_rounded, color: theme.colorScheme.primary),
        title: Text(
          '${title ?? l10n.salesQuoteStatusTimelineTitle} (${revisions.length})',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          UtenSpacing.s12,
          0,
          UtenSpacing.s12,
          UtenSpacing.s12,
        ),
        children: [
          SalesQuoteRevisionComparison(revisions: revisions),
          UtenProgressTimeline(
            events: salesQuoteRevisionEvents(l10n, revisions),
            emptyText: l10n.salesQuoteStatusTimelineEmpty,
          ),
        ],
      ),
    );
  }
}
