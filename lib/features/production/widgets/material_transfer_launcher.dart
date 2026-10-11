import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_material_analysis.dart';
import '../repositories/production_repository.dart';

/// 「物料 / 调拨」的简化选择器（2026-10-10 口径收窄：调拨只针对**其他计划暂用**
/// 的部分——别人已入库占用的现货、别人专属的在途；公共库存与公共在途不参与
/// 调拨，它们已计入「可用数量（公共口径）」，下单时由服务端按 ADR-099 自动
/// 认领）。这里只露出两个调入入口（带可调来源数量）和完整详情入口，仓库与
/// 供给明细等长内容留在完整详情里。每个按钮打开的子弹窗自带返回键，返回后
/// 这里会刷新数量。手动「采用公共在途」保留在物料行右键菜单（显式动作）。
Future<void> showMaterialTransferLauncher({
  required BuildContext context,
  required ProductionPlanRepository repository,
  required ProductionMaterialAnalysisView analysis,
  required ProductionMaterialAnalysisMaterial material,
  required String Function(double?) qtyText,
  required bool spotEnabled,
  required bool futureEnabled,
  required Future<void> Function() onSpotReceive,
  required Future<void> Function() onFutureReceive,
  required Future<void> Function() onOpenFullDetails,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _MaterialTransferLauncherDialog(
      repository: repository,
      analysis: analysis,
      material: material,
      qtyText: qtyText,
      spotEnabled: spotEnabled,
      futureEnabled: futureEnabled,
      onSpotReceive: onSpotReceive,
      onFutureReceive: onFutureReceive,
      onOpenFullDetails: onOpenFullDetails,
    ),
  );
}

class _MaterialTransferLauncherDialog extends StatefulWidget {
  const _MaterialTransferLauncherDialog({
    required this.repository,
    required this.analysis,
    required this.material,
    required this.qtyText,
    required this.spotEnabled,
    required this.futureEnabled,
    required this.onSpotReceive,
    required this.onFutureReceive,
    required this.onOpenFullDetails,
  });

  final ProductionPlanRepository repository;
  final ProductionMaterialAnalysisView analysis;
  final ProductionMaterialAnalysisMaterial material;
  final String Function(double?) qtyText;
  final bool spotEnabled;
  final bool futureEnabled;
  final Future<void> Function() onSpotReceive;
  final Future<void> Function() onFutureReceive;
  final Future<void> Function() onOpenFullDetails;

  @override
  State<_MaterialTransferLauncherDialog> createState() =>
      _MaterialTransferLauncherDialogState();
}

class _MaterialTransferLauncherDialogState
    extends State<_MaterialTransferLauncherDialog> {
  int? _spotCount;
  int? _futureCount;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshCounts());
  }

  Future<void> _refreshCounts() async {
    final futures = <Future<void>>[
      if (widget.spotEnabled)
        widget.repository
            .materialCrossReallocationSources(
              targetAnalysisId: widget.analysis.analysisId,
              targetMaterialLineId: widget.material.materialLineId,
              size: 1,
            )
            .then((page) {
              if (mounted) setState(() => _spotCount = page.total);
            })
            .catchError((_) {
              if (mounted) setState(() => _spotCount = null);
            }),
      if (widget.futureEnabled)
        widget.repository
            .materialFutureTransferSources(
              targetAnalysisId: widget.analysis.analysisId,
              targetMaterialId: widget.material.materialLineId,
            )
            .then((page) {
              if (mounted) setState(() => _futureCount = page.items.length);
            })
            .catchError((_) {
              if (mounted) setState(() => _futureCount = null);
            }),
    ];
    await Future.wait(futures);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_refreshCounts());
    }
  }

  String _countLabel(int? count) => count == null ? '' : '（$count 个来源）';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final material = widget.material;
    final compact = context.breakpoint.isCompact;
    final needQty = material.shortageQty > 0
        ? '缺口 ${widget.qtyText(material.shortageQty)}'
        : material.additionalSupplyRecommendedQty > 0
        ? '待补 ${widget.qtyText(material.additionalSupplyRecommendedQty)}'
        : null;
    return AlertDialog(
      key: const Key('material-transfer-launcher'),
      title: Text('物料调拨：${material.goodsName ?? material.goodsCode ?? '物料'}'),
      content: SizedBox(
        width: compact ? double.infinity : 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 注意：这里不挂 UtenBusyOverlay——_busy 包的是「打开调拨滑窗并等它
            // 关闭」，遮罩会盖住整个滑窗；真正的网络段在滑窗内部（跨批复用
            // _submitting / 未来调拨弹窗各自已挂）。
            if (needQty != null)
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                child: Text(
                  '本计划$needQty${material.unitName?.trim().isNotEmpty == true ? ' ${material.unitName!.trim()}' : ''}，选择调入方式：',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            UtenButton(
              key: const Key('transfer-launcher-spot'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              isExpanded: true,
              // 数量为 0 时置灰不可点；数量未知（加载中/查询失败）时仍可进入弹窗重试。
              onPressed: widget.spotEnabled && !_busy && _spotCount != 0
                  ? () => _run(widget.onSpotReceive)
                  : null,
              child: Text(
                '从其他计划已入库中调入${widget.spotEnabled ? _countLabel(_spotCount) : '（0 个来源）'}',
                textAlign: TextAlign.left,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenButton(
              key: const Key('transfer-launcher-future'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              isExpanded: true,
              onPressed: widget.futureEnabled && !_busy && _futureCount != 0
                  ? () => _run(widget.onFutureReceive)
                  : null,
              child: Text(
                '从其他计划未入库中调入${widget.futureEnabled ? _countLabel(_futureCount) : '（0 个来源）'}',
                textAlign: TextAlign.left,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            const Divider(height: UtenSpacing.s24),
            UtenButton(
              key: const Key('transfer-launcher-full-details'),
              size: UtenButtonSize.large,
              type: UtenButtonType.ghost,
              isExpanded: true,
              onPressed: _busy ? null : () => _run(widget.onOpenFullDetails),
              child: const Text('查看完整物料详情（供给明细 / 记录 / 进度）'),
            ),
          ],
        ),
      ),
      actions: [
        UtenButton(
          key: const Key('transfer-launcher-close'),
          size: UtenButtonSize.large,
          type: UtenButtonType.ghost,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
