// 物料需求评审对话框：生产计划「一键生成子计划」的主入口。
//
// 与 execution_segment_planning_sheet（执行段精细编辑抽屉）的区别：
// 本对话框面向业务做"缺料评审 + 一键确认"——按 充足/采购缺料/自制缺料/委外缺料/无BOM
// 五分类展示物料，用户勾选是否生成采购申请，确认后产出 ProductionPlanningConfirmRequest。
// 执行段的车间/班组/日期直接采用预览建议值（不编辑），适合"一键"场景；需要精细编辑时
// 仍可走旧 sheet（详情页保留入口）。
//
// 自制件派生子计划、委外生成委外申请由后端 confirm 事务自动处理（前端只需对采购勾选）。
import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/idempotency_key.dart';
import '../models/production_execution_planning.dart';

/// 打开物料需求评审对话框，返回确认请求；用户取消返回 null。
Future<ProductionPlanningConfirmRequest?> showMaterialReviewDialog(
  BuildContext context, {
  required ProductionPlanningPreview preview,
  required String warehouseName,
  required String planBillNo,
}) {
  return showDialog<ProductionPlanningConfirmRequest>(
    context: context,
    builder: (ctx) => _MaterialReviewDialog(
      preview: preview,
      warehouseName: warehouseName,
      planBillNo: planBillNo,
    ),
  );
}

class _MaterialReviewDialog extends StatefulWidget {
  const _MaterialReviewDialog({
    required this.preview,
    required this.warehouseName,
    required this.planBillNo,
  });

  final ProductionPlanningPreview preview;
  final String warehouseName;
  final String planBillNo;

  @override
  State<_MaterialReviewDialog> createState() => _MaterialReviewDialogState();
}

class _MaterialReviewDialogState extends State<_MaterialReviewDialog> {
  static const double _epsilon = 0.001;

  late final _Buckets _buckets;
  late bool _generatePurchaseRequest;

  @override
  void initState() {
    super.initState();
    _buckets = _classify(widget.preview.materials);
    _generatePurchaseRequest = _buckets.buyShortage.isNotEmpty;
  }

  _Buckets _classify(List<ProductionPlanningMaterial> materials) {
    final sufficient = <ProductionPlanningMaterial>[];
    final buy = <ProductionPlanningMaterial>[];
    final make = <ProductionPlanningMaterial>[];
    final subcontract = <ProductionPlanningMaterial>[];
    final makeNoBom = <ProductionPlanningMaterial>[];
    for (final m in materials) {
      final shortage = m.timelyShortage ?? 0;
      if (shortage <= _epsilon) {
        sufficient.add(m);
        continue;
      }
      // 缺料：按 sourceType + 是否有下层 BOM 分类
      if (m.selfMade) {
        make.add(m); // 有下层 BOM 的自制件 → 后端派生子生产计划
      } else if (m.sourceType == '自制') {
        makeNoBom.add(m); // 自制但未维护下层 BOM → 提示去货品资料维护
      } else if (m.sourceType == '委外') {
        subcontract.add(m);
      } else {
        buy.add(m); // 采购件或来源未填（默认按采购）
      }
    }
    return _Buckets(sufficient, buy, make, subcontract, makeNoBom);
  }

  void _confirm() {
    final preview = widget.preview;
    // segments 直接采用预览建议值（不编辑），天然满足"合计=计划量"与"READY 齐套"约束。
    final segments = [
      for (final seg in preview.executionSegments)
        ProductionExecutionSegmentConfirm(
          clientSegmentKey: seg.clientSegmentKey,
          sourcePlanItemId: seg.sourcePlanItemId,
          requestedStatus: seg.suggestedStatus,
          plannedQty: seg.plannedQty,
          workshopDepartmentId: seg.workshopDepartmentId,
          teamDepartmentId: seg.teamDepartmentId,
          responsibleEmployeeId: seg.responsibleEmployeeId,
          planBeginDate: seg.planBeginDate,
          planEndDate: seg.planEndDate,
          bomFingerprint: seg.bomFingerprint,
        ),
    ];
    // routes：缺料物料按 goodsId|colorId 去重（与 execution_segment_planning_sheet 同口径）
    final routeMap = <String, ProductionMaterialRoute>{};
    for (final seg in preview.executionSegments) {
      for (final mat in seg.materials) {
        if (mat.shortageQty <= _epsilon) continue;
        final key = '${mat.goodsId}|${mat.colorId ?? ''}';
        routeMap.putIfAbsent(
          key,
          () => ProductionMaterialRoute(
            goodsId: mat.goodsId,
            colorId: mat.colorId,
            supplyRoute: mat.supplyRoute,
          ),
        );
      }
    }
    final canonical = [
      preview.planId,
      preview.warehouseId,
      preview.fingerprint,
      _generatePurchaseRequest,
      for (final seg in segments)
        [
          seg.clientSegmentKey,
          seg.sourcePlanItemId,
          seg.requestedStatus,
          seg.plannedQty,
          seg.workshopDepartmentId,
          seg.teamDepartmentId,
          seg.responsibleEmployeeId,
          seg.planBeginDate,
          seg.planEndDate,
          seg.bomFingerprint,
        ].join('|'),
    ].join('::');
    Navigator.of(context).pop(ProductionPlanningConfirmRequest(
      warehouseId: preview.warehouseId,
      idempotencyKey: businessIdempotencyKey('production-planning', canonical),
      previewFingerprint: preview.fingerprint,
      generatePurchaseRequest:
          _buckets.buyShortage.isNotEmpty && _generatePurchaseRequest,
      routes: routeMap.values.toList(),
      segments: segments,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noBomCount = widget.preview.noBomPlanItemIds.length;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.account_tree_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('物料需求评审', style: theme.textTheme.titleMedium),
                Text(
                  '计划 ${widget.planBillNo} · 发料仓 ${widget.warehouseName}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _infoBanner(theme),
              if (_buckets.sufficient.isNotEmpty)
                _category(
                  theme,
                  icon: Icons.check_circle_outline_rounded,
                  color: Colors.green,
                  title: '库存充足，可立即生产',
                  count: _buckets.sufficient.length,
                  materials: _buckets.sufficient,
                  hint: (m) => '需 ${_q(m.gross)} · 库存 ${_q(m.bookStock)}',
                ),
              if (_buckets.buyShortage.isNotEmpty)
                _category(
                  theme,
                  icon: Icons.shopping_cart_outlined,
                  color: Colors.orange.shade700,
                  title: '采购缺料',
                  count: _buckets.buyShortage.length,
                  materials: _buckets.buyShortage,
                  hint: (m) =>
                      '需 ${_q(m.gross)} · 缺 ${_q(m.timelyShortage)}',
                  trailing: CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _generatePurchaseRequest,
                    onChanged: (v) => setState(
                        () => _generatePurchaseRequest = v ?? false),
                    title: Text('生成采购申请',
                        style: theme.textTheme.bodyMedium),
                  ),
                ),
              if (_buckets.makeShortage.isNotEmpty)
                _category(
                  theme,
                  icon: Icons.precision_manufacturing_outlined,
                  color: Colors.blue.shade700,
                  title: '自制缺料（将派生子生产计划）',
                  count: _buckets.makeShortage.length,
                  materials: _buckets.makeShortage,
                  hint: (m) =>
                      '需 ${_q(m.gross)} · 缺 ${_q(m.timelyShortage)}',
                  note: '确认后系统自动生成自制件子计划，进入子计划可继续展开下层。',
                ),
              if (_buckets.subcontractShortage.isNotEmpty)
                _category(
                  theme,
                  icon: Icons.local_shipping_outlined,
                  color: Colors.purple.shade700,
                  title: '委外缺料（将生成委外申请）',
                  count: _buckets.subcontractShortage.length,
                  materials: _buckets.subcontractShortage,
                  hint: (m) =>
                      '需 ${_q(m.gross)} · 缺 ${_q(m.timelyShortage)}',
                ),
              if (_buckets.makeNoBom.isNotEmpty)
                _category(
                  theme,
                  icon: Icons.warning_amber_rounded,
                  color: theme.colorScheme.error,
                  title: '自制件但未维护下层 BOM',
                  count: _buckets.makeNoBom.length,
                  materials: _buckets.makeNoBom,
                  hint: (m) => '需 ${_q(m.gross)}',
                  note: '这些自制件未维护组成 BOM，无法派生子计划，请先到货品资料维护。',
                ),
              if (noBomCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s8),
                  child: _notice(
                    theme,
                    color: theme.colorScheme.error,
                    icon: Icons.report_problem_outlined,
                    text: '另有 $noBomCount 个成品未维护 BOM，未参与本次排产，'
                        '请到货品资料为它们维护组成 BOM 后再生成。',
                  ),
                ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _confirm,
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('确认生成'),
        ),
      ],
    );
  }

  Widget _infoBanner(ThemeData theme) {
    final hasShortage = _buckets.buyShortage.isNotEmpty ||
        _buckets.makeShortage.isNotEmpty ||
        _buckets.subcontractShortage.isNotEmpty;
    final text = hasShortage
        ? '系统已按目标仓库存、在途与 BOM 计算缺口。勾选要生成的供给单据后点击「确认生成」，'
            '执行分段、锁料、领料单将在同一事务内提交。'
        : '所有物料库存充足，可直接生产。点击「确认生成」即可建立执行子计划。';
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: _notice(
        theme,
        color: theme.colorScheme.primary,
        icon: Icons.info_outline_rounded,
        text: text,
      ),
    );
  }

  Widget _category(
    ThemeData theme, {
    required IconData icon,
    required Color color,
    required String title,
    required int count,
    required List<ProductionPlanningMaterial> materials,
    required String Function(ProductionPlanningMaterial) hint,
    Widget? trailing,
    String? note,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 6),
                  Text('$title（$count）',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: color, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(note,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: color)),
              ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: trailing,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  for (final m in materials) _materialChip(theme, m, hint(m)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _materialChip(
      ThemeData theme, ProductionPlanningMaterial m, String hint) {
    final label = [m.goodsCode, m.goodsName, m.spec]
        .where((s) => s != null && s.isNotEmpty)
        .join(' ');
    return Chip(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      label: Text.rich(
        TextSpan(
          style: theme.textTheme.bodySmall,
          children: [
            TextSpan(
                text: label.isEmpty ? m.goodsId : label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            TextSpan(text: '  $hint', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _notice(ThemeData theme,
      {required Color color, required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  static String _q(double? v) {
    final n = v ?? 0;
    if (n == n.roundToDouble()) return n.toStringAsFixed(0);
    return n.toStringAsFixed(2);
  }
}

class _Buckets {
  final List<ProductionPlanningMaterial> sufficient;
  final List<ProductionPlanningMaterial> buyShortage;
  final List<ProductionPlanningMaterial> makeShortage;
  final List<ProductionPlanningMaterial> subcontractShortage;
  final List<ProductionPlanningMaterial> makeNoBom;

  _Buckets(this.sufficient, this.buyShortage, this.makeShortage,
      this.subcontractShortage, this.makeNoBom);
}
