// 委外订货单「全链路进度」区(ADR-143 §4.6)。
//
// 每条订货明细 = 一个委外任务，一条时间线：下单 → 财务审批 → 领料发外(已领 x/Q) →
// 加工回厂 → 品质检验 → 仓库确认入仓 → 结案核销。节点状态与说明全部由服务端算好，
// 这里只显示。物料段与委外任务详情的物料表同列(每套用量 / 需求 / 已发外 / 待仓库发 /
// 仓库可用 / 本次可领 / 还缺 / 供应来源 / 状态)。其后是领料出仓单、回厂进仓单(品质与
// 入仓状态)、退货单、损耗单、委外商处物料台账与应付摘要；单号可点进只读详情(委外视角
// 不进入仓库作业页面)。金额是否可见只看服务端的 priceMasked。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/platform_tables/platform_table_binding.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/subcontract_doc.dart';
import '../models/subcontract_draw.dart';
import '../models/subcontract_order_progress.dart';
import '../repositories/subcontract_repository.dart';
import 'subcontract_draw_status.dart';

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
    final canViewPrice = !p.priceMasked;
    final closeReason = (p.planCloseReason ?? '').trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (p.planStatus == 'CLOSED')
          _hint(theme, '领料计划已关闭${closeReason.isEmpty ? '' : '：$closeReason'}')
        else if (p.planStatus == 'CANCELED')
          _hint(theme, '订货单已红冲，领料计划已取消'),
        if (p.items.isEmpty)
          _hint(theme, '订货单还没有明细')
        else
          for (var index = 0; index < p.items.length; index++) ...[
            if (index > 0) const SizedBox(height: UtenSpacing.s12),
            _itemSection(theme, p.items[index]),
          ],
        if (p.issues.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          _docSection(
            theme,
            title: '领料出仓单',
            docs: p.issues,
            segment: 'material-issues',
            // 一张出仓单含多种物料，单位各不相同，不显示合计数量。
            showQty: false,
            statusLabel: (d) => switch (d.status) {
              1 => '已发出',
              0 => '待仓库发料',
              _ => '已红冲',
            },
          ),
        ],
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
                ? '建议索赔 ${d.deductAmount!.toStringAsFixed(2)}'
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

  /// 一个委外任务：委外件身份 + 时间线 + 直属物料表。
  Widget _itemSection(ThemeData theme, SubcontractItemProgress item) {
    final identity = [
      if (item.goodsCode.isNotEmpty) item.goodsCode,
      if (item.colorName.isNotEmpty) item.colorName,
    ].join(' · ');
    return Container(
      key: ValueKey('subcontract-progress-item-${item.orderItemId}'),
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                item.goodsName.isEmpty ? '委外件' : item.goodsName,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (identity.isNotEmpty)
                Text(
                  identity,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              Text(
                '订货 ${_qty(item.orderQty, item.unitName)}',
                style: theme.textTheme.bodySmall,
              ),
              if (item.bomMissing) _bomMissingTag(theme),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          _timelineStrip(theme, item),
          if (item.materials.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '直属物料 · 已备 ${item.readyKindCount}/${item.materialKindCount} 种',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            _materialTable(item),
          ],
        ],
      ),
    );
  }

  Widget _bomMissingTag(ThemeData theme) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s8,
      vertical: 2,
    ),
    decoration: BoxDecoration(
      color: theme.colorScheme.error.withValues(alpha: 0.10),
      borderRadius: UtenRadius.smAll,
      border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.5)),
    ),
    child: Text(
      '缺 BOM',
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.error,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  /// 下单 → 财务审批 → 领料发外 → 加工回厂 → 品质检验 → 仓库确认入仓 → 结案核销。
  Widget _timelineStrip(ThemeData theme, SubcontractItemProgress item) {
    final nodes = item.timeline;
    if (nodes.isEmpty) return _hint(theme, '进度暂未生成');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < nodes.length; i++) ...[
            _nodeChip(theme, item, nodes[i]),
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

  Widget _nodeChip(
    ThemeData theme,
    SubcontractItemProgress item,
    SubcontractProgressNode node,
  ) {
    final (color, icon) = switch (node.state) {
      SubcontractProgressNodeState.done => (
        theme.colorScheme.primary,
        Icons.check_circle_rounded,
      ),
      SubcontractProgressNodeState.active => (
        theme.colorScheme.tertiary,
        Icons.timelapse_rounded,
      ),
      SubcontractProgressNodeState.pending => (
        theme.colorScheme.onSurfaceVariant,
        Icons.radio_button_unchecked,
      ),
      SubcontractProgressNodeState.skipped => (
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        Icons.remove_circle_outline,
      ),
    };
    final emphasized =
        node.state == SubcontractProgressNodeState.done ||
        node.state == SubcontractProgressNodeState.active;
    final detail = node.detail?.trim();
    return Container(
      key: ValueKey(
        'subcontract-progress-node-${item.orderItemId}-${node.key}',
      ),
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: emphasized ? 0.12 : 0.06),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
              Text(
                node.label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: emphasized ? FontWeight.w700 : null,
                  decoration: node.state == SubcontractProgressNodeState.skipped
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
            ],
          ),
          if (detail != null && detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                detail,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 与委外任务详情物料表同列；数量都是服务端算好的结果。
  Widget _materialTable(SubcontractItemProgress item) =>
      MasterDataTableView<SubcontractDrawMaterial>(
        key: ValueKey('subcontract-progress-materials-${item.orderItemId}'),
        tableKey: 'subcontract.order.progress.materials',
        embedded: true,
        showFullscreenToggle: false,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        columns: [
          MasterColumnDef(
            key: 'state',
            label: '状态',
            width: 72,
            value: subcontractDrawMaterialStateLabel,
            // 状态整格底色（ADR-169）：共用 subcontractDrawMaterialCellColor，
            // 与领料任务详情物料表同口径（可领绿/已备紫/待仓库发料青/缺料红/
            // 已发齐·已结束领料灰）。
            cellColor: (context, row) => subcontractDrawMaterialCellColor(row),
          ),
          MasterColumnDef(
            key: 'goodsName',
            label: '物料名称',
            width: 180,
            value: (row) => _label(row.goodsName),
          ),
          MasterColumnDef(
            key: 'goodsCode',
            label: '编号',
            width: 130,
            value: (row) => _label(row.goodsCode),
          ),
          MasterColumnDef(
            key: 'colorName',
            label: '颜色',
            width: 90,
            value: (row) => _label(row.colorName),
          ),
          MasterColumnDef(
            key: 'unitName',
            label: '单位',
            width: 70,
            value: (row) => _label(row.unitName),
          ),
          _qtyColumn('perUnitQty', '每套用量', (row) => row.perUnitQty),
          _qtyColumn('requiredQty', '需求', (row) => row.requiredQty),
          _qtyColumn('sentQty', '已发外', (row) => row.sentQty),
          _qtyColumn('pendingQty', '待仓库发', (row) => row.pendingQty),
          _qtyColumn('availableQty', '仓库可用', (row) => row.availableQty),
          _qtyColumn('drawableQty', '本次可领', (row) => row.drawableQty),
          _qtyColumn('shortQty', '还缺', (row) => row.shortQty),
          const MasterColumnDef(
            key: 'supplySources',
            label: '供应来源',
            width: 240,
            value: subcontractDrawSupplyText,
          ),
        ],
        items: item.materials,
        emptyMessage: '本任务没有需要领的物料',
      );

  MasterColumnDef<SubcontractDrawMaterial> _qtyColumn(
    String key,
    String label,
    double Function(SubcontractDrawMaterial row) qty,
  ) => MasterColumnDef(
    key: key,
    label: label,
    width: 96,
    type: 'number',
    value: (row) => subcontractDrawQty(qty(row)),
  );

  Widget _docSection(
    ThemeData theme, {
    required String title,
    required List<SubcontractProgressDoc> docs,
    required String segment,
    String? Function(SubcontractProgressDoc)? trailing,
    String Function(SubcontractProgressDoc)? statusLabel,
    bool showQty = true,
  }) {
    return _sectionBox(
      theme,
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                        [
                          d.billNo ?? '—',
                          if ((d.warehouseName ?? '').trim().isNotEmpty)
                            d.warehouseName!.trim(),
                          if (showQty) subcontractDrawQty(d.totalQty ?? 0),
                          if (d.billDate != null) d.billDate!,
                          if (d.approverName != null) d.approverName!,
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (trailing?.call(d) case final text?)
                      Flexible(
                        flex: 2,
                        child: Text(
                          text,
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
                        (statusLabel ?? _docStatusText)(d),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _docStatusText(SubcontractProgressDoc doc) =>
      switch (doc.status) {
        1 => '已审核',
        0 => '草稿',
        _ => '已红冲',
      };

  Widget _ledgerSection(ThemeData theme, SubcontractOrderProgress p) {
    return _sectionBox(
      theme,
      title: '委外商处物料台账(守恒)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MasterDataTableView<SubcontractSupplierLedgerLine>(
            tableKey: 'subcontract.order.supplierLedger',
            embedded: true,
            platformBinding: PlatformTableBinding(
              tableKey: 'subcontract.order.supplierLedger',
              scope: 'view_subcontract',
              recordIdOf: (_) => null,
              factValuesOf: (row) => {
                'atSupplierQty': row.atSupplierQty.toString(),
                'consumedQty': row.consumedQty.toString(),
                'returnedQty': row.returnedQty.toString(),
                'wastedQty': row.wastedQty.toString(),
                'supplierEnding': row.supplierEnding.toString(),
              },
            ),
            columns: [
              MasterColumnDef(
                key: 'goodsName',
                label: '物料名称',
                width: 180,
                value: (row) => row.goodsName,
              ),
              MasterColumnDef(
                key: 'goodsCode',
                label: '编号',
                width: 130,
                value: (row) => row.goodsCode,
              ),
              MasterColumnDef(
                key: 'colorName',
                label: '颜色',
                width: 90,
                value: (row) => row.colorName,
              ),
              MasterColumnDef(
                key: 'unitName',
                label: '单位',
                width: 80,
                value: (row) => row.unitName,
              ),
              MasterColumnDef(
                key: 'atSupplierQty',
                label: '发出',
                width: 120,
                type: 'number',
                value: (row) => subcontractDrawQty(row.atSupplierQty),
              ),
              MasterColumnDef(
                key: 'consumedQty',
                label: '回厂核销',
                width: 140,
                type: 'number',
                value: (row) => subcontractDrawQty(row.consumedQty),
              ),
              MasterColumnDef(
                key: 'returnedQty',
                label: '已退',
                width: 110,
                type: 'number',
                value: (row) => subcontractDrawQty(row.returnedQty),
              ),
              MasterColumnDef(
                key: 'wastedQty',
                label: '损耗',
                width: 110,
                type: 'number',
                value: (row) => subcontractDrawQty(row.wastedQty),
              ),
              MasterColumnDef(
                key: 'supplierEnding',
                label: '结存',
                width: 120,
                type: 'number',
                value: (row) => subcontractDrawQty(row.supplierEnding),
                cellBuilder: (_, row) => Text(
                  subcontractDrawQty(row.supplierEnding),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
            items: p.supplierLedger,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
          ),
          if (p.supplierLedger.any((l) => l.supplierEnding > 0.0001))
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Text(
                '委外商处物料逐种按发出、回厂核销、退回、损耗守恒；'
                '未清结存要由退料单或损耗单核销，回厂入仓不会自动抹平。',
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

  String? _iqcText(String? iqcStatus) =>
      switch (iqcStatus?.trim().toUpperCase()) {
        'RESOLVED' => '质检已结案',
        'PENDING' => '待品质检验',
        'PARTIAL' => '质检部分完成',
        _ => null,
      };

  /// 进仓单的品质与入仓状态。仓库入库状态缺失或不认识时显示「待回传」，
  /// 不从质检结案推断已入仓。
  String _receiptProgressText(SubcontractProgressDoc receipt) {
    final status = switch (receipt.warehouseStockInStatus
        ?.trim()
        .toUpperCase()) {
      'WAITING_QUALITY' => '等待品质检验',
      'PENDING_STOCK_IN' => '合格待仓库入库',
      'PARTIAL_STOCK_IN' => '仓库部分入库',
      'STOCKED' => '仓库已确认入仓',
      'NO_QUALIFIED_STOCK' => '无合格品入库',
      'REVERSED' => '入库已撤销',
      _ => '仓库入库状态待回传',
    };
    final quantities = <String>[
      if (receipt.iqcPassedBaseQty != null)
        '合格 ${subcontractDrawQty(receipt.iqcPassedBaseQty!)}',
      if (receipt.warehouseStockedBaseQty != null)
        '已入库 ${subcontractDrawQty(receipt.warehouseStockedBaseQty!)}',
      if (receipt.pendingStockInBaseQty != null)
        '待入库 ${subcontractDrawQty(receipt.pendingStockInBaseQty!)}',
    ];
    return [?_iqcText(receipt.iqcStatus), status, ...quantities].join(' · ');
  }

  static String _qty(double value, String unit) {
    final trimmed = unit.trim();
    return '${subcontractDrawQty(value)}${trimmed.isEmpty ? '' : ' $trimmed'}';
  }

  static String _label(String? value) =>
      value?.trim().isNotEmpty == true ? value!.trim() : '—';
}
