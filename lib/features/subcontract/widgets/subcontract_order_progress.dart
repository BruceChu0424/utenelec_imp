// 委外订货单「全链路进度」区（V304 · 委外全链路重设计）。
//
// 委外模块只留订货单 + 进度：本区把 财务审批 → 目标件准备/出仓 → 加工回厂/IQC/仓库入库 →
// 退货/损耗 → 委外商处货品台账 → 应付摘要 一次聚合展示；出仓/进仓单号可点击进
// 对应只读详情（数据通用，委外视角不进入仓库作业页面）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../models/subcontract_order_progress.dart';
import '../repositories/subcontract_repository.dart';
import '../models/subcontract_doc.dart';

class SubcontractOrderProgressSection extends ConsumerStatefulWidget {
  const SubcontractOrderProgressSection({super.key, required this.orderId});

  final String orderId;

  @override
  ConsumerState<SubcontractOrderProgressSection> createState() =>
      _SubcontractOrderProgressSectionState();
}

class _SubcontractOrderProgressSectionState
    extends ConsumerState<SubcontractOrderProgressSection> {
  SubcontractOrderProgress? _progress;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await ref
          .read(subcontractRepositoryProvider(SubcontractDocType.order))
          .orderProgress(widget.orderId);
      if (!mounted) return;
      setState(() {
        _progress = p;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '进度加载失败';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '全链路进度',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  tooltip: '刷新进度',
                  onPressed: _loading ? null : _load,
                ),
              ],
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: UtenSpacing.s16),
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              )
            else if (_progress != null)
              _buildContent(theme, _progress!),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, SubcontractOrderProgress p) {
    final permissions = ref.watch(currentPermissionsProvider);
    final canViewPrice =
        (permissions.contains(Perm.subcontractOrderPriceView) ||
            permissions.contains(Perm.financeViewAll)) &&
        !p.priceMasked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _nodeStrip(theme, p),
        const SizedBox(height: UtenSpacing.s12),
        _materialSection(theme, p),
        if (p.receipts.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          _docSection(
            theme,
            title: '成品回厂(进仓单)',
            docs: p.receipts,
            segment: 'receipts',
            trailing: _receiptProgressText,
          ),
        ],
        if (p.returns.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          _docSection(
            theme,
            title: '成品退货单',
            docs: p.returns,
            segment: 'returns',
          ),
        ],
        if (p.wastes.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          _docSection(
            theme,
            title: '损耗单',
            docs: p.wastes,
            segment: 'wastes',
            trailing: (d) => canViewPrice && (d.deductAmount ?? 0) > 0
                ? '建议索赔 ${_fmt(d.deductAmount!)}'
                : null,
          ),
        ],
        if (p.supplierLedger.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          _ledgerSection(theme, p),
        ],
        if (canViewPrice) ...[
          const SizedBox(height: UtenSpacing.s12),
          _apSummary(theme, p),
        ],
      ],
    );
  }

  // 下单后先完成所需内部生产，再交财务，随后实际目标件出仓。
  // 加工回厂 → 品质检验 → 仓库确认入仓 → 结案。品质与入库不得合并推断。
  Widget _nodeStrip(ThemeData theme, SubcontractOrderProgress p) {
    final reversed = p.status == -1;
    final financeDone = p.financeCaseStatus == 'APPROVED' || p.status == 1;
    final preparationLines = p.materialLines
        .where(
          (line) =>
              line.flowMode == 'MAKE_THEN_OUTBOUND' || line.isDraftPreparation,
        )
        .toList(growable: false);
    final preparationDone =
        preparationLines.isNotEmpty &&
        preparationLines.every(
          (line) =>
              line.preparationStatus == 'READY_FOR_FINANCE' ||
              line.preparationStatus == 'READY_OUTBOUND' ||
              line.preparationStatus == 'OUTBOUND_COMPLETE',
        );
    final outboundRelevant =
        p.materialRequired || p.materialLines.isNotEmpty || p.issues.isNotEmpty;
    final outboundDone = p.materialLines.isNotEmpty
        ? p.materialLines.every(
            (line) =>
                line.preparationStatus == 'OUTBOUND_COMPLETE' ||
                (line.remainingQty <= 0 && line.issuedQty > 0),
          )
        : p.issues.any((issue) => issue.status == 1);
    final outboundCurrent = financeDone && outboundRelevant && !outboundDone;
    final receivedTotal = p.receipts
        .where((r) => r.status == 1)
        .fold<double>(0, (a, b) => a + (b.totalQty ?? 0));
    final approvedReceipts = p.receipts
        .where((receipt) => receipt.status == 1)
        .toList(growable: false);
    final receiptsFinalized = p.receipts.every(
      (receipt) => receipt.status != 0,
    );
    final qualityDone =
        receivedTotal > 0 &&
        receiptsFinalized &&
        approvedReceipts.isNotEmpty &&
        approvedReceipts.every((receipt) => receipt.qualityResolved);
    final warehouseStockInDone =
        qualityDone &&
        approvedReceipts.every((receipt) => receipt.warehouseStocked);
    final settled = p.supplierLedger.every((l) => l.supplierEnding <= 0.0001);

    final nodes = <_Node>[
      const _Node('下单', true),
      if (preparationLines.isNotEmpty)
        _Node(
          workflowFieldText(context).subcontractInternalProduction,
          preparationDone,
          current: !reversed && !preparationDone,
        ),
      _Node('财务审批', financeDone),
      if (outboundRelevant)
        _Node('目标件出仓', outboundDone, current: outboundCurrent),
      _Node('加工回厂', receivedTotal > 0),
      _Node('品质检验', qualityDone, current: receivedTotal > 0 && !qualityDone),
      _Node(
        '仓库确认入仓',
        warehouseStockInDone,
        current: qualityDone && !warehouseStockInDone,
      ),
      _Node('结案核销', warehouseStockInDone && settled),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < nodes.length; i++) ...[
            _nodeChip(theme, nodes[i], reversed && i > 0),
            if (i != nodes.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _nodeChip(ThemeData theme, _Node node, bool dimmed) {
    final done = node.done && !dimmed;
    final color = dimmed
        ? theme.colorScheme.onSurfaceVariant
        : done
        ? theme.colorScheme.primary
        : node.current
        ? theme.colorScheme.tertiary
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: done || node.current ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(UtenRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            done
                ? Icons.check_circle_rounded
                : node.current
                ? Icons.timelapse_rounded
                : Icons.radio_button_unchecked,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            node.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: done || node.current ? FontWeight.w700 : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _materialSection(ThemeData theme, SubcontractOrderProgress p) {
    final hasOutboundPlan =
        p.materialRequired || p.materialLines.isNotEmpty || p.issues.isNotEmpty;
    if (!hasOutboundPlan) {
      return _sectionBox(
        theme,
        title: '目标件出仓',
        child: Text(
          '该历史订货尚未形成目标件出仓计划；不能据此认定“无 BOM 无需出仓”。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return _sectionBox(
      theme,
      title: '目标件准备与出仓',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.planStatus == 'CLOSED')
            _hint(
              theme,
              '出仓计划已关闭${p.planCloseReason != null ? '：${p.planCloseReason}' : ''}',
            )
          else if (p.planStatus == 'CANCELED')
            _hint(theme, '出仓计划已随订货红冲取消'),
          if (p.materialLines.isNotEmpty) ...[
            for (var index = 0; index < p.materialLines.length; index++) ...[
              _materialLineCard(theme, p.materialLines[index]),
              if (index != p.materialLines.length - 1)
                const SizedBox(height: UtenSpacing.s8),
            ],
          ],
          if (p.issues.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            _docSection(
              theme,
              title: '目标件出仓单',
              docs: p.issues,
              segment: 'material-issues',
              dense: true,
            ),
          ] else if (p.planStatus == 'OPEN')
            _hint(theme, '未备齐的目标件不会进入仓库；已放行行正在等待生成出仓草稿或仓库拣货'),
        ],
      ),
    );
  }

  Widget _materialLineCard(ThemeData theme, SubcontractMaterialPlanLine line) {
    final target = '${line.goodsCode ?? ''} ${line.goodsName ?? ''}'.trim();
    final legacyParent =
        '${line.parentGoodsCode ?? ''} ${line.parentGoodsName ?? ''}'.trim();
    final blocker = line.blocker?.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: UtenRadius.smAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  target.isEmpty ? '未命名委外目标件' : target,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                _preparationStatusLabel(line.preparationStatus),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            line.isLegacyBomComponent
                ? '历史 BOM 子件发料'
                      '${legacyParent.isEmpty ? '' : ' · 父件 $legacyParent'}'
                : _flowModeLabel(line.flowMode, line.isStockDirectLine),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            children: [
              _quantityFact(theme, '目标量', line.plannedQty, line.unitName),
              if (line.isDraftPreparation) ...[
                _quantityFact(
                  theme,
                  workflowFieldText(context).subcontractPreparedQuantity,
                  line.preparedQty,
                  line.unitName,
                ),
                _quantityFact(
                  theme,
                  workflowFieldText(context).subcontractPreparationShortage,
                  line.remainingQty,
                  line.unitName,
                ),
              ] else ...[
                if (!line.isLegacyBomComponent)
                  _quantityFact(
                    theme,
                    '前置已完成',
                    line.preparedQty,
                    line.unitName,
                  ),
                _quantityFact(
                  theme,
                  '当前可出',
                  line.readyOutboundQty,
                  line.unitName,
                ),
                _quantityFact(theme, '已出仓', line.issuedQty, line.unitName),
                _quantityFact(theme, '订单未出', line.remainingQty, line.unitName),
              ],
            ],
          ),
          if (blocker != null && blocker.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              blocker,
              style: theme.textTheme.bodySmall?.copyWith(
                color: line.isDraftPreparation
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (line.preparationAnalysisId != null &&
              line.allowedActions.contains('OPEN_ANALYSIS'))
            TextButton.icon(
              onPressed: () => context.push(
                RoutePath.productionMaterialAnalysisSummary(
                  line.preparationAnalysisId!,
                ),
              ),
              icon: const Icon(Icons.account_tree_outlined, size: 18),
              label: Text(
                workflowFieldText(context).subcontractOpenPreparation,
              ),
            ),
        ],
      ),
    );
  }

  Widget _quantityFact(
    ThemeData theme,
    String label,
    double value,
    String? unit,
  ) => Text(
    '$label ${_fmt(value)}${unit?.trim().isNotEmpty == true ? ' ${unit!.trim()}' : ''}',
    style: theme.textTheme.bodySmall,
  );

  String _flowModeLabel(String flowMode, [bool stockDirect = false]) =>
      switch (flowMode) {
        'DRAFT_PREPARATION' => workflowFieldText(
          context,
        ).subcontractDraftPreparationHint,
        // 直下单销售式供货：有子层但现货充足拆出的直发行，区别于真无子层件。
        'DIRECT_OUTBOUND' =>
          stockDirect ? '有子层级 · 仓库现货直发（缺口另行走前置自制）' : '无子层级 · 目标件库存放行后直接出仓',
        'MAKE_THEN_OUTBOUND' => '有子层级 · 先自制、FQC 和入仓，可分批出仓',
        // V458：分析来源的有子层级件在下单前已完成前置自制并通知委外。
        'PREPARED_OUTBOUND' => '前置自制已先行完成 · 批准即出仓',
        'LEGACY_BOM_COMPONENT' => '历史 BOM 子件发料',
        _ => '准备路线待确认',
      };

  String _preparationStatusLabel(String status) => switch (status) {
    'WAITING_PLAN' => workflowFieldText(context).subcontractWaitingPlan,
    'READY_FOR_FINANCE' => workflowFieldText(
      context,
    ).subcontractReadyForFinance,
    'ACTION_REQUIRED' => '待计划员开始物料分析',
    'IN_PREPARATION' || 'WAITING_PREPARATION' => '前置自制中',
    'WAITING_FQC' => '等待品质检查',
    'WAITING_INBOUND' => '等待自制件入仓',
    'READY_OUTBOUND' || 'LEGACY_READY' => '已备齐，等待仓库出仓',
    'OUTBOUND_COMPLETE' => '目标件已出仓',
    'CANCELLED' => '已取消',
    _ => '状态待确认',
  };

  Widget _docSection(
    ThemeData theme, {
    required String title,
    required List<SubcontractProgressDoc> docs,
    required String segment,
    String? Function(SubcontractProgressDoc)? trailing,
    bool dense = false,
  }) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!dense)
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        if (dense)
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: UtenSpacing.s4),
        for (final d in docs)
          InkWell(
            borderRadius: BorderRadius.circular(UtenRadius.md),
            onTap: () =>
                context.push(RoutePath.subcontractDocDetail(segment, d.id)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
              child: Row(
                children: [
                  Icon(
                    switch (d.status) {
                      1 => Icons.check_circle_outline,
                      0 => Icons.pending_actions_outlined,
                      _ => Icons.undo_rounded,
                    },
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      '${d.billNo ?? '—'} · ${_fmt(d.totalQty ?? 0)}'
                      '${d.billDate != null ? ' · ${d.billDate}' : ''}'
                      '${d.approverName != null ? ' · ${d.approverName}' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (trailing?.call(d) != null)
                    Flexible(
                      flex: 2,
                      child: Text(
                        trailing!(d)!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    Text(
                      switch (d.status) {
                        1 => '已审核',
                        0 => '草稿',
                        _ => '已红冲',
                      },
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
    return dense ? body : _sectionBox(theme, child: body);
  }

  Widget _ledgerSection(ThemeData theme, SubcontractOrderProgress p) {
    return _sectionBox(
      theme,
      title: '委外商处货品台账(守恒)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Table(
            columnWidths: const {
              0: FlexColumnWidth(3),
              1: FlexColumnWidth(2),
              2: FlexColumnWidth(2),
              3: FlexColumnWidth(2),
              4: FlexColumnWidth(2),
              5: FlexColumnWidth(2),
            },
            children: [
              _tableHead(theme, const ['货品', '发出', '已加工/消费', '已退', '损耗', '结存']),
              for (final l in p.supplierLedger)
                TableRow(
                  children: [
                    _cell(
                      theme,
                      '${l.goodsCode ?? ''} ${l.goodsName ?? ''}'.trim(),
                      sub: l.unitName,
                    ),
                    _cell(theme, _fmt(l.atSupplierQty)),
                    _cell(theme, _fmt(l.consumedQty)),
                    _cell(theme, _fmt(l.returnedQty)),
                    _cell(theme, _fmt(l.wastedQty)),
                    _cell(theme, _fmt(l.supplierEnding), strong: true),
                  ],
                ),
            ],
          ),
          if (p.supplierLedger.any((l) => l.supplierEnding > 0.0001))
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Text(
                '新流按目标件追踪发出、加工回厂、退回、损耗与结存；'
                '历史 BOM 子件发料单仍按子件守恒解释。'
                '未清结存必须由真实退回或损耗单核销，不能因回厂入仓自动抹平。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _apSummary(ThemeData theme, SubcontractOrderProgress p) {
    return _sectionBox(
      theme,
      title: '应付摘要',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv(theme, '已立加工费应付(本币)', p.apPostedTotal.toStringAsFixed(2)),
          if (p.wasteDeductTotal > 0)
            _kv(theme, '损耗建议索赔(不计入应付)', p.wasteDeductTotal.toStringAsFixed(2)),
        ],
      ),
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s4),
      child: Row(
        children: [
          Text(
            '$label：',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionBox(ThemeData theme, {String? title, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(UtenRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Text(
                title,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }

  Widget _hint(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );

  TableRow _tableHead(ThemeData theme, List<String> labels) => TableRow(
    children: [
      for (final l in labels)
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
          child: Text(
            l,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ],
  );

  Widget _cell(
    ThemeData theme,
    String text, {
    String? sub,
    bool strong = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s4, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text.isEmpty ? '—' : text,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: strong ? FontWeight.w700 : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (sub != null && sub.isNotEmpty)
            Text(
              sub,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  String? _iqcText(String? iqcStatus) =>
      switch (iqcStatus?.trim().toUpperCase()) {
        'RESOLVED' => '质检已结案',
        'PENDING' => '待品质检验',
        'PARTIAL' => '质检部分完成',
        _ => null,
      };

  String _receiptProgressText(SubcontractProgressDoc receipt) {
    final status = switch (receipt.warehouseStockInStatus
        ?.trim()
        .toUpperCase()) {
      'WAITING_QUALITY' => '等待品质检验',
      'PENDING_STOCK_IN' => '合格待仓库入库',
      'PARTIAL_STOCK_IN' => '仓库部分入库',
      'STOCKED' => '仓库已确认入仓',
      'REVERSED' => '入库已撤销',
      _ => '仓库入库状态待回传',
    };
    final quantities = <String>[
      if (receipt.iqcPassedBaseQty != null)
        '合格 ${_fmt(receipt.iqcPassedBaseQty!)}',
      if (receipt.warehouseStockedBaseQty != null)
        '已入库 ${_fmt(receipt.warehouseStockedBaseQty!)}',
      if (receipt.pendingStockInBaseQty != null)
        '待入库 ${_fmt(receipt.pendingStockInBaseQty!)}',
    ];
    return [?_iqcText(receipt.iqcStatus), status, ...quantities].join(' · ');
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

class _Node {
  const _Node(this.label, this.done, {this.current = false});
  final String label;
  final bool done;
  final bool current;
}
