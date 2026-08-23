// 委外订货单「全链路进度」区（V304 · 委外全链路重设计）。
//
// 委外模块只留订货单 + 进度：本区把 财务审批 → 材料出仓（仓库）→ 成品回厂/IQC →
// 退货/损耗 → 供应商处材料台账 → 应付摘要 一次聚合展示；出仓/进仓单号可点击进
// 对应只读详情（数据通用，委外视角不进入仓库作业页面）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
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
            title: '成品回厂（进仓单）',
            docs: p.receipts,
            segment: 'receipts',
            trailing: (d) => _iqcText(d.iqcStatus),
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
            trailing: (d) => (d.deductAmount ?? 0) > 0
                ? '建议索赔 ${_fmt(d.deductAmount!)}'
                : null,
          ),
        ],
        if (p.supplierLedger.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          _ledgerSection(theme, p),
        ],
        const SizedBox(height: UtenSpacing.s12),
        _apSummary(theme, p),
      ],
    );
  }

  // 节点条：下单 → 财务审批 → 材料出仓 → 成品回厂 → 结案核销。
  Widget _nodeStrip(ThemeData theme, SubcontractOrderProgress p) {
    final reversed = p.status == -1;
    final financeDone = p.financeCaseStatus == 'APPROVED' || p.status == 1;
    final issuedTotal = p.materialLines.fold<double>(
      0,
      (a, b) => a + b.issuedQty,
    );
    final plannedTotal = p.materialLines.fold<double>(
      0,
      (a, b) => a + b.plannedQty,
    );
    final outboundDone =
        !p.materialRequired ||
        (plannedTotal > 0 &&
            issuedTotal >= plannedTotal - 0.0001 &&
            p.planStatus != 'OPEN');
    final outboundCurrent =
        financeDone && p.materialRequired && !outboundDone; // 出仓进行中
    final receivedTotal = p.receipts
        .where((r) => r.status == 1)
        .fold<double>(0, (a, b) => a + (b.totalQty ?? 0));
    final inboundDone =
        receivedTotal > 0 &&
        p.receipts.every((r) => r.status != 0) &&
        p.receipts.any((r) => r.status == 1 && r.iqcStatus == 'RESOLVED');
    final settled = p.supplierLedger.every((l) => l.supplierEnding <= 0.0001);

    final nodes = <_Node>[
      const _Node('下单', true),
      _Node('财务审批', financeDone),
      if (p.materialRequired)
        _Node('材料出仓', outboundDone, current: outboundCurrent),
      _Node('成品回厂', inboundDone),
      _Node('结案核销', inboundDone && settled),
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
    if (!p.materialRequired) {
      return _sectionBox(
        theme,
        title: '材料出仓',
        child: Text(
          '该订货无需发料（委外商自备料或未配置 BOM）',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return _sectionBox(
      theme,
      title: '材料出仓（仓库执行）',
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
          if (p.materialLines.isNotEmpty)
            Table(
              columnWidths: const {
                0: FlexColumnWidth(3),
                1: FlexColumnWidth(2),
                2: FlexColumnWidth(2),
                3: FlexColumnWidth(2),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                _tableHead(theme, const ['材料（父件）', '计划量', '已出仓', '待出仓']),
                for (final l in p.materialLines)
                  TableRow(
                    children: [
                      _cell(
                        theme,
                        '${l.goodsCode ?? ''} ${l.goodsName ?? ''}'.trim(),
                        sub:
                            '父件 ${'${l.parentGoodsCode ?? ''} ${l.parentGoodsName ?? ''}'.trim()}'
                            '${l.unitName != null ? ' · ${l.unitName}' : ''}',
                      ),
                      _cell(theme, _fmt(l.plannedQty)),
                      _cell(theme, _fmt(l.issuedQty)),
                      _cell(theme, _fmt(l.remainingQty)),
                    ],
                  ),
              ],
            ),
          if (p.issues.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            _docSection(
              theme,
              title: '出仓单',
              docs: p.issues,
              segment: 'material-issues',
              dense: true,
            ),
          ] else if (p.planStatus == 'OPEN')
            _hint(theme, '出仓草稿生成中或待仓库拣货'),
        ],
      ),
    );
  }

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
                    Text(
                      trailing!(d)!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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
      title: '委外商处材料台账（守恒）',
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
              _tableHead(theme, const ['材料', '发出', '已消费', '已退', '损耗', '结存']),
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
                '结存处理方式：委外商退回余料（仓库开材料退货单）或按损耗核销'
                '（损耗单可填建议索赔金额；该金额仅供后续财务责任决定参考，'
                '不会自动扣款或冲应付）。',
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
          _kv(theme, '已立加工费应付（本币）', p.apPostedTotal.toStringAsFixed(2)),
          if (p.wasteDeductTotal > 0)
            _kv(theme, '损耗建议索赔（不计入应付）', p.wasteDeductTotal.toStringAsFixed(2)),
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

  String? _iqcText(String? iqcStatus) => switch (iqcStatus) {
    'RESOLVED' => '质检已结案',
    'PENDING' => '待品质检验',
    'PARTIAL' => '质检部分完成',
    _ => null,
  };

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

class _Node {
  const _Node(this.label, this.done, {this.current = false});
  final String label;
  final bool done;
  final bool current;
}
