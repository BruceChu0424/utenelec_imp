import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../warehouse/materialbin/models/workshop_material_models.dart';
import '../../warehouse/materialbin/widgets/workshop_material_labels.dart';
import '../../warehouse/materialbin/widgets/workshop_material_request_dialog.dart';
import '../models/workshop_task_stock_readiness.dart';
import '../repositories/workshop_material_choice_repository.dart';

/// 工单详情中的内料仓提示与整批补料入口。足量、缺料、无法估算时均可补料；
/// 数量只用于提示，不转成按单领料需求，也不限制开工或申请数量。
class WorkshopTaskMaterialBinPanel extends ConsumerStatefulWidget {
  const WorkshopTaskMaterialBinPanel({super.key, required this.segmentId});

  final String segmentId;

  @override
  ConsumerState<WorkshopTaskMaterialBinPanel> createState() =>
      _WorkshopTaskMaterialBinPanelState();
}

class _WorkshopTaskMaterialBinPanelState
    extends ConsumerState<WorkshopTaskMaterialBinPanel> {
  WorkshopTaskStockReadiness? _data;
  String? _error;
  bool _loading = true;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref
          .read(workshopMaterialChoiceRepositoryProvider)
          .stockReadiness(widget.segmentId);
      if (mounted) setState(() => _data = data);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is ApiException ? error.message : '内料仓库存提示未读到，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _request() async {
    final data = _data;
    if (data == null || !data.canRequest || _requesting) return;
    setState(() => _requesting = true);
    try {
      final submitted = await showWorkshopMaterialRequestSheet(
        context,
        kind: 'ISSUE',
        workshopId: data.workshopDepartmentId,
        workshopName: data.workshopName,
        initialMaterialKeys: {
          for (final row in data.rows) wmMaterialKey(row.goodsId, row.colorId),
        },
        positionByKey: {
          for (final row in data.rows)
            if (row.bookQty != null && row.estimatedRemainingQty != null)
              wmMaterialKey(row.goodsId, row.colorId): WmPositionRow(
                goodsId: row.goodsId,
                colorId: row.colorId,
                bookQty: row.bookQty!,
                estimatedRemainingQty: row.estimatedRemainingQty!,
              ),
        },
      );
      if (!mounted || submitted != true) return;
      refreshBadges(ref);
      await _load();
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  String _qty(double? value, String? unit) {
    if (value == null) return '暂不能估算';
    final suffix = unit == null || unit.isEmpty ? '' : ' $unit';
    if (value != 0 && value.abs() < 0.000001) {
      return '${value < 0 ? '负值，绝对值小于' : '小于'}0.000001$suffix';
    }
    return '${wmQty(value, maxDecimals: 6)}$suffix';
  }

  Widget _row(WorkshopTaskStockRow row) {
    final unknown =
        row.estimateIncomplete ||
        !const {'ESTIMATED_ENOUGH', 'ESTIMATED_SHORT'}.contains(row.status) ||
        row.requiredQty == null ||
        row.estimatedRemainingQty == null;
    final short = !unknown && row.status == 'ESTIMATED_SHORT';
    final label = unknown
        ? '暂不能判断是否足够'
        : short
        ? '预计不足 ${_qty(row.shortageQty, row.unitName)}'
        : '预计足够';
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey(
        'workshop-stock-${wmMaterialKey(row.goodsId, row.colorId)}',
      ),
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row.label, style: theme.textTheme.titleSmall),
          const SizedBox(height: UtenSpacing.s4),
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            children: [
              Text('内料仓估计还剩：${_qty(row.estimatedRemainingQty, row.unitName)}'),
              Text('本任务预计还需：${_qty(row.requiredQty, row.unitName)}'),
            ],
          ),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: short ? theme.colorScheme.error : null,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (row.reason?.isNotEmpty == true) Text(row.reason!),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Column(
      key: const Key('workshop-task-material-bin'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Text('车间内料仓', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: UtenSpacing.s8),
        if (_loading)
          const LinearProgressIndicator()
        else if (_error != null) ...[
          Text(_error!),
          TextButton(onPressed: _load, child: const Text('重试库存提示')),
        ] else if (data != null) ...[
          if (data.rows.isEmpty) const Text('当前用料尚未确定，暂不能判断库存是否足够'),
          for (final row in data.rows) _row(row),
          if (data.reason?.isNotEmpty == true) Text(data.reason!),
          const Text(
            '库存为按报工估算的车间共用余量，实存以现场盘点为准。'
            '可以提前整批补料；本提示不要求每张工单先去仓库领料。',
          ),
        ],
        if (data?.canRequest == true) ...[
          const SizedBox(height: UtenSpacing.s8),
          UtenButton(
            key: const Key('workshop-task-request-bin-material'),
            type: UtenButtonType.secondary,
            icon: Icons.add_rounded,
            onPressed: _requesting || _loading ? null : _request,
            child: const Text('新建补料申请'),
          ),
        ],
      ],
    );
  }
}
