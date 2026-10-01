import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../basic_data/models/goods_issue_method.dart';
import '../../../basic_data/repositories/goods_issue_method_repository.dart';
import 'workshop_material_labels.dart';

/// 首次发到内料仓的用途确认。这里只有预览与本次确认，不单独修改货品；
/// 返回的配置必须与仓库发料放进同一个 fulfil 命令。
class WorkshopMaterialFirstUseCard extends ConsumerStatefulWidget {
  const WorkshopMaterialFirstUseCard({
    super.key,
    required this.goodsId,
    required this.goodsName,
    required this.canConfigure,
    required this.enabled,
    required this.onChanged,
    this.fixedBasis,
    this.expectedVersion,
    this.approvalContext = false,
  });

  final String goodsId;
  final String goodsName;
  final bool canConfigure;
  final bool enabled;
  final ValueChanged<Map<String, dynamic>?> onChanged;
  final String? fixedBasis;
  final int? expectedVersion;
  final bool approvalContext;

  @override
  ConsumerState<WorkshopMaterialFirstUseCard> createState() =>
      _WorkshopMaterialFirstUseCardState();
}

class _WorkshopMaterialFirstUseCardState
    extends ConsumerState<WorkshopMaterialFirstUseCard> {
  String _basis = 'OWN';
  GoodsIssueMethodPreview? _preview;
  bool _loading = true;
  bool _confirmed = false;
  String? _error;
  int _sequence = 0;

  @override
  void initState() {
    super.initState();
    _basis = widget.fixedBasis ?? 'OWN';
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPreview());
  }

  bool get _canConfirm {
    final preview = _preview;
    return widget.enabled &&
        widget.canConfigure &&
        !_loading &&
        preview != null &&
        preview.goodsId == widget.goodsId &&
        preview.matches('PERIODIC', _basis) &&
        preview.version != null &&
        (widget.expectedVersion == null ||
            preview.version == widget.expectedVersion) &&
        preview.massUnit &&
        preview.canSwitch &&
        preview.blockers.isEmpty &&
        !preview.bomRows.any((row) => row.mustFixFirst);
  }

  Future<void> _loadPreview() async {
    if (!mounted) return;
    final sequence = ++_sequence;
    final basis = _basis;
    setState(() {
      _loading = true;
      _preview = null;
      _confirmed = false;
      _error = null;
    });
    widget.onChanged(null);
    try {
      final preview = await ref
          .read(goodsIssueMethodRepositoryProvider)
          .preview(widget.goodsId, target: 'PERIODIC', costBasis: basis);
      if (!mounted || sequence != _sequence) return;
      setState(() {
        if (preview.goodsId != widget.goodsId ||
            !preview.matches('PERIODIC', basis)) {
          _error = '用途预览与当前材料不一致，请重新核对';
        } else {
          _preview = preview;
        }
      });
    } catch (error) {
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _error = error is ApiException ? error.message : '首次用途影响未读到，请重试';
      });
    } finally {
      if (mounted && sequence == _sequence) setState(() => _loading = false);
    }
  }

  void _confirm(bool? value) {
    if (!_canConfirm) return;
    setState(() => _confirmed = value == true);
    widget.onChanged(
      _confirmed
          ? {
              'goodsId': widget.goodsId,
              'expectedVersion': _preview!.version!,
              'periodicCostBasis': _basis,
            }
          : null,
    );
  }

  String _qty(double? value) =>
      value == null ? '未知' : wmQty(value, maxDecimals: 6);

  Widget _details(String title, List<String> details) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: UtenSpacing.s8),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    title: Text(title),
    children: [
      for (final detail in details)
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
          child: Text('· $detail'),
        ),
    ],
  );

  Widget _impact(GoodsIssueMethodPreview preview) {
    final unit = preview.unitName ?? '';
    final changed = preview.bomRows
        .where((row) => row.action != GoodsIssueMethodBomRow.actionKeep)
        .length;
    final blockers = <String>{
      ...preview.blockers,
      if (!preview.massUnit) '该材料基本单位不是重量单位，不能整批发到车间内料仓',
      if (preview.version == null) '没有读到货品版本，请重新核对',
      if (widget.expectedVersion != null &&
          preview.version != widget.expectedVersion)
        '申请后货品版本已变化，请退回重新盘点，不能沿用旧的用途确认',
      if (!preview.canSwitch && preview.blockers.isEmpty) '当前条件不允许切换，请先处理后重新核对',
      if (preview.bomRows.any((row) => row.mustFixFirst))
        '有 BOM 行需要先处理，详情见下方影响清单',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (blockers.isNotEmpty)
          UtenInlineNotice(
            key: ValueKey('wm-first-use-blockers-${widget.goodsId}'),
            level: UtenInlineNoticeLevel.error,
            title: '暂不能按此用途发料，申请继续保留',
            message: blockers.join('\n'),
          ),
        _details('关联 BOM ${preview.bomRows.length} 行，其中 $changed 行将调整', [
          for (final row in preview.bomRows)
            '${[row.productCode, row.productName].whereType<String>().join(' ')}：'
                '${row.actionLabel}'
                '${row.qty == null ? '' : '；当前用量 ${_qty(row.qty)} $unit'}'
                '${row.unitWeightGrams == null ? '' : '；单个重量 ${_qty(row.unitWeightGrams)} 克'}'
                '${row.note == null ? '' : '；${row.note}'}',
        ]),
        if (preview.unclearedDemands.isNotEmpty)
          _details('未清账的按单领料 ${preview.unclearedDemands.length} 项', [
            for (final demand in preview.unclearedDemands)
              '${demand.orderLabel} ${demand.productName ?? ''}：'
                  '${_qty(demand.unclearedQty)} $unit 未清账'
                  '${demand.note == null ? '' : '；${demand.note}'}',
          ]),
        if (preview.binBalances.isNotEmpty)
          _details('现有内料仓余额 ${preview.binBalances.length} 项', [
            for (final balance in preview.binBalances)
              '${balance.warehouseName ?? '内料仓'}：${_qty(balance.qty)} $unit',
          ]),
        if (preview.openPeriods.isNotEmpty)
          _details('尚未结算期间 ${preview.openPeriods.length} 项', [
            for (final period in preview.openPeriods)
              '${period.binName ?? '内料仓'} 第 ${period.periodNo ?? '—'} 期：'
                  '${period.startDate ?? ''} 至 ${period.endDate ?? '尚未截止'}',
          ]),
        if (preview.unsettledTheory.isNotEmpty)
          _details('未结算理论用量 ${preview.unsettledTheory.length} 项', [
            for (final theory in preview.unsettledTheory)
              '${theory.binName ?? '内料仓'}：${theory.productCount} 个产品，'
                  '${_qty(theory.theoryQty)} $unit',
          ]),
        if (preview.inProgressSegments.isNotEmpty)
          _details('涉及在产工单 ${preview.inProgressSegments.length} 张', [
            for (final segment in preview.inProgressSegments)
              [
                segment.segmentCode,
                segment.productCode,
                segment.productName,
              ].whereType<String>().join(' '),
          ]),
        if (preview.activeChoices.isNotEmpty)
          _details('切换后需要重新认料的产品 ${preview.activeChoices.length} 个', [
            for (final choice in preview.activeChoices)
              [
                choice.productCode,
                choice.productName,
              ].whereType<String>().join(' '),
          ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.goodsName} · ${widget.approvalContext ? '盘点审核确认用途' : '首次发料确认用途'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: UtenSpacing.s8),
          UtenDropdownField(
            key: ValueKey('wm-first-use-basis-${widget.goodsId}'),
            label: '这类材料的用途',
            value: _basis,
            enabled:
                widget.enabled &&
                widget.canConfigure &&
                widget.fixedBasis == null,
            allowClear: false,
            items: const [
              UtenDropdownItem(value: 'OWN', label: '主料：按产品用量分摊'),
              UtenDropdownItem(value: 'SHARED', label: '辅料：按主料用量分摊'),
              UtenDropdownItem(value: 'EXPENSE', label: '记车间费用'),
            ],
            onChanged: (value) {
              if (value == null || value == _basis) return;
              _basis = value;
              _loadPreview();
            },
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '${widget.approvalContext ? '本次盘点批准成功' : '本次发料成功'}时会把该货品统一改为整批领料，并同步处理所有使用它的 BOM。'
            '用途影响所有车间和后续任务，请核对下方影响；关闭页面不会修改货品。'
            '${widget.fixedBasis == null ? '' : '用途来自盘点申请，若需改变请退回重新提交。'}',
          ),
          if (!widget.canConfigure)
            const UtenInlineNotice(
              level: UtenInlineNoticeLevel.warning,
              message: '首次用途确认需要货品编辑和 BOM 编辑权限，请有权限的同事在本页办理。申请会继续保留。',
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: UtenSpacing.s8),
              child: LinearProgressIndicator(),
            )
          else if (_error != null)
            UtenInlineNotice(
              level: UtenInlineNoticeLevel.error,
              message: _error!,
            )
          else if (preview != null)
            _impact(preview),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('wm-first-use-refresh-${widget.goodsId}'),
              onPressed: widget.enabled && !_loading ? _loadPreview : null,
              child: const Text('重新核对影响'),
            ),
          ),
          CheckboxListTile(
            key: ValueKey('wm-first-use-confirm-${widget.goodsId}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _confirmed,
            onChanged: _canConfirm ? _confirm : null,
            title: Text(
              '已核对用途及全局 BOM 影响，随本次${widget.approvalContext ? '盘点审核' : '发料'}一起确认',
            ),
          ),
          const Divider(),
        ],
      ),
    );
  }
}
