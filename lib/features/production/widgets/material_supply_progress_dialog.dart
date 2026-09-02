import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../models/production_material_analysis.dart';
import '../repositories/production_repository.dart';

// 物料供给全链路进度弹窗（适老化大字号纵向时间线）。
// 数据全部来自服务端只读链回溯，前端不在本地推算任何一步；打开拉取一次，失败可重试。
/// 物料供给全链路进度弹窗（适老化大字号纵向时间线）。
///
/// 数据全部来自服务端只读链回溯（行动→申请→订货→审批→预计到货→收货→
/// 质检→库存），前端不在本地推算任何一步；打开时拉取一次，失败可重试。
class MaterialSupplyProgressDialog extends ConsumerStatefulWidget {
  const MaterialSupplyProgressDialog({
    super.key,
    required this.analysisId,
    required this.material,
    required this.canViewProductionPlans,
  });

  final String analysisId;
  final ProductionMaterialAnalysisMaterial material;
  final bool canViewProductionPlans;

  @override
  ConsumerState<MaterialSupplyProgressDialog> createState() =>
      _MaterialSupplyProgressDialogState();
}

class _MaterialSupplyProgressDialogState
    extends ConsumerState<MaterialSupplyProgressDialog> {
  MaterialSupplyProgress? _progress;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final progress = await ref
          .read(productionPlanRepositoryProvider)
          .materialSupplyProgress(
            widget.analysisId,
            widget.material.materialLineId,
          );
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionErrorMessage(error, fallback: '进度加载失败，请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goodsLabel =
        widget.material.goodsName ?? widget.material.goodsCode ?? '当前物料';
    final dialogTitle = switch (_progress?.route) {
      'MAKE' => '自制生产流程',
      'SUBCONTRACT' => '委外准备与加工进度',
      _ => '供给全链路进度',
    };
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dialogTitle),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            goodsLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: UtenSpacing.s40),
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : _error != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: UtenSpacing.s12),
                  UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.refresh_rounded,
                    onPressed: _load,
                    child: const Text('重试'),
                  ),
                ],
              )
            : _buildTimeline(theme, _progress!),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildTimeline(ThemeData theme, MaterialSupplyProgress progress) {
    if (progress.steps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Text('该物料还没有已下达的供给任务'),
      );
    }
    // 快递式追踪：最新进展在最上面（后端按业务顺序返回，这里倒序展示）。
    final steps = progress.steps.reversed.toList();
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < steps.length; i++)
            _ProgressStepTile(
              step: steps[i],
              isLast: i == steps.length - 1,
              onOpenDocument: _documentAction(steps[i]),
            ),
        ],
      ),
    );
  }

  VoidCallback? _documentAction(MaterialSupplyProgressStep step) {
    final documentId = step.documentId?.trim();
    if (documentId == null || documentId.isEmpty) return null;
    final permissions = ref.read(currentPermissionsProvider);
    final documentType = step.documentType?.trim().toUpperCase();
    Object? extra;
    final destination = switch (documentType) {
      'PRODUCTION_PLAN' when widget.canViewProductionPlans =>
        RoutePath.productionPlanDetail(documentId),
      'PRODUCTION_MATERIAL_ANALYSIS'
          when permissions.contains(Perm.productionMaterialAnalysisView) =>
        RouteName.productionMaterialAnalysis,
      'SUBCONTRACT_ORDER'
          when permissions.contains(Perm.subcontractOrderView) =>
        RoutePath.subcontractDocDetail('orders', documentId),
      'SUBCONTRACT_OUTBOUND_PLAN'
          when permissions.contains(Perm.subcontractOutboundView) =>
        RouteName.warehouseSubcontractOutboundEdit(documentId),
      'SUBCONTRACT_MATERIAL_ISSUE'
          when permissions.contains(Perm.subcontractMaterialIssueView) =>
        RoutePath.subcontractDocDetail('material-issues', documentId),
      'SUBCONTRACT_RECEIPT'
          when (step.receiptType?.trim().isNotEmpty == true ||
                  step.key == 'QUALITY') &&
              permissions.contains(Perm.procurementInspectionView) =>
        RouteName.warehouseInspectionDetail(
          step.receiptType?.trim().isNotEmpty == true
              ? step.receiptType!.trim().toUpperCase()
              : 'SUBCONTRACT',
          documentId,
        ),
      'SUBCONTRACT_RECEIPT'
          when permissions.contains(Perm.subcontractReceiptView) =>
        RoutePath.subcontractDocDetail('receipts', documentId),
      // A standalone inspection UUID has no safe Flutter route. The backend
      // projects IQC through SUBCONTRACT_RECEIPT + receiptType instead.
      'PROCUREMENT_INSPECTION' => null,
      _ => null,
    };
    if (destination == null) return null;
    if (documentType == 'PRODUCTION_MATERIAL_ANALYSIS') {
      extra = ProductionMaterialAnalysisSeed(analysisId: documentId);
    }
    return () {
      final router = GoRouter.of(context);
      Navigator.of(context).pop();
      router.push(destination, extra: extra);
    };
  }
}

/// 进度时间线中的一步：左侧状态圆点 + 连接线，右侧步骤名、状态、单号与时间。
class _ProgressStepTile extends StatelessWidget {
  const _ProgressStepTile({
    required this.step,
    required this.isLast,
    this.onOpenDocument,
  });

  final MaterialSupplyProgressStep step;
  final bool isLast;
  final VoidCallback? onOpenDocument;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (dotColor, icon) = switch (step.state) {
      'DONE' => (UtenColors.deepGreen, Icons.check_rounded),
      'CURRENT' => (theme.colorScheme.tertiary, Icons.more_horiz_rounded),
      'REJECTED' => (theme.colorScheme.error, Icons.close_rounded),
      _ => (theme.colorScheme.outlineVariant, Icons.circle_outlined),
    };
    final stateLabel = switch (step.state) {
      'DONE' => '已完成',
      'CURRENT' => '进行中',
      'REJECTED' => '被驳回',
      _ => '未开始',
    };
    final Color? textColor = switch (step.state) {
      'DONE' => null,
      'CURRENT' => theme.colorScheme.tertiary,
      'REJECTED' => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: step.state == 'WAITING'
                        ? Colors.transparent
                        : dotColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: dotColor, width: 2),
                  ),
                  child: Icon(
                    icon,
                    size: 14,
                    color: step.state == 'WAITING'
                        ? theme.colorScheme.onSurfaceVariant
                        : Colors.white,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: step.isDone
                          ? UtenColors.deepGreen.withValues(alpha: 0.4)
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: isLast ? 0 : UtenSpacing.s16,
                top: 2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          step.label,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: textColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        stateLabel,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: step.state == 'WAITING'
                              ? theme.colorScheme.onSurfaceVariant
                              : dotColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  if (step.detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      step.detail!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (step.docNo != null) ...[
                    const SizedBox(height: 2),
                    if (onOpenDocument != null)
                      TextButton.icon(
                        key: ValueKey('supply-progress-document-${step.key}'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 44),
                          padding: const EdgeInsets.symmetric(
                            horizontal: UtenSpacing.s4,
                          ),
                        ),
                        onPressed: onOpenDocument,
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: Text(step.docNo!),
                      )
                    else
                      Text(
                        step.docNo!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                  if (step.at != null || step.operatorName != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      [
                        // 快递式追踪：每步带责任人（提交人/采购人/审批人/收货人…）。
                        if (step.operatorName != null)
                          '负责人：${step.operatorName}',
                        if (step.at != null)
                          ChinaDateTime.formatIsoInstant(step.at),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
