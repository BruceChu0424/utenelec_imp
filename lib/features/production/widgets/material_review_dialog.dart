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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../models/production_execution_planning.dart';
import '../repositories/production_repository.dart';

enum MaterialReviewDecisionType { useSuggestedPlan, openDetailedPlanning }

class MaterialReviewDecision {
  const MaterialReviewDecision._(
    this.type,
    this.request,
    this.focusMaterialIds,
  );

  const MaterialReviewDecision.useSuggestedPlan(
    ProductionPlanningConfirmRequest request,
  ) : this._(
        MaterialReviewDecisionType.useSuggestedPlan,
        request,
        const <String>[],
      );

  MaterialReviewDecision.openDetailedPlanning([
    Iterable<String> focusMaterialIds = const <String>[],
  ]) : this._(
         MaterialReviewDecisionType.openDetailedPlanning,
         null,
         List<String>.unmodifiable(focusMaterialIds),
       );

  final MaterialReviewDecisionType type;
  final ProductionPlanningConfirmRequest? request;
  final List<String> focusMaterialIds;
}

/// Opens material review and returns the chosen planning path.
Future<MaterialReviewDecision?> showMaterialReviewDialog(
  BuildContext context, {
  required ProductionPlanningPreview preview,
  required String warehouseName,
  required String planBillNo,
}) {
  return showDialog<MaterialReviewDecision>(
    context: context,
    builder: (ctx) => _MaterialReviewDialog(
      preview: preview,
      warehouseName: warehouseName,
      planBillNo: planBillNo,
    ),
  );
}

class _MaterialReviewDialog extends ConsumerStatefulWidget {
  const _MaterialReviewDialog({
    required this.preview,
    required this.warehouseName,
    required this.planBillNo,
  });

  final ProductionPlanningPreview preview;
  final String warehouseName;
  final String planBillNo;

  @override
  ConsumerState<_MaterialReviewDialog> createState() => _MaterialReviewDialogState();
}

class _MaterialReviewDialogState extends ConsumerState<_MaterialReviewDialog> {
  static const double _epsilon = kProductionPlanningQuantityEpsilon;

  late final _Buckets _buckets;
  /// 本次会话内已一键转发登记的货品（避免重开前重复显示"待转发"）。
  final Set<String> _locallyForwarded = <String>{};
  bool _forwarding = false;

  @override
  void initState() {
    super.initState();
    _buckets = _classify(buildProductionDirectReviewMaterials(widget.preview));
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

  /// 当前已转发（仍在等待研发维护）的货品集合 = 预览返回的 + 本次会话本地登记的。
  Set<String> get _forwardedGoods =>
      <String>{...widget.preview.forwardedGoodsIds, ..._locallyForwarded};

  /// 当前仍需转发给研发的 BOM 缺失货品（自制组件 makeNoBom + 成品 noBom，去掉已转发的）。
  List<String> get _pendingForwardGoods {
    final all = <String>{
      for (final m in _buckets.makeNoBom) m.goodsId,
      ...widget.preview.noBomGoodsIds,
    };
    final forwarded = _forwardedGoods;
    return all.where((g) => !forwarded.contains(g)).toList()..sort();
  }

  /// 一键转发全部缺失 BOM 给工程研发部（自制组件 + 成品）。组件无 order_item，来源填计划单。
  Future<void> _forwardBomGaps() async {
    final goods = _pendingForwardGoods;
    if (goods.isEmpty || _forwarding) return;
    setState(() => _forwarding = true);
    try {
      final result = await ref.read(productionPlanRepositoryProvider).forwardToRdBatch(
            [for (final g in goods) (goodsId: g, orderItemId: null)],
            sourcePlanId: widget.preview.planId,
            sourcePlanNo: widget.planBillNo,
          );
      final created = (result['created'] as num?)?.toInt() ?? 0;
      final reused = (result['reused'] as num?)?.toInt() ?? 0;
      setState(() => _locallyForwarded.addAll(goods));
      if (mounted) {
        context.appSuccess(
          created > 0
              ? '已转发 $created 项给工程研发部${reused > 0 ? '（另 $reused 项已在等待）' : ''}，等待维护'
              : '已登记等待工程研发部维护',
        );
      }
    } catch (_) {
      if (mounted) context.appWarning('转发失败，请重试');
    } finally {
      if (mounted) setState(() => _forwarding = false);
    }
  }

  void _confirm() {
    final preview = widget.preview;
    if (preview.hasBlockingBomGaps) return;
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
    final generatePurchaseRequest = _buckets.buyShortage.isNotEmpty;
    final canonical = [
      preview.planId,
      preview.warehouseId,
      preview.fingerprint,
      generatePurchaseRequest,
      for (final seg in segments)
        [
          seg.clientSegmentKey,
          seg.sourcePlanItemId,
          seg.requestedStatus,
          seg.deferUntilManualRelease,
          seg.plannedQty,
          seg.workshopDepartmentId,
          seg.teamDepartmentId,
          seg.responsibleEmployeeId,
          seg.planBeginDate,
          seg.planEndDate,
          seg.bomFingerprint,
        ].join('|'),
    ].join('::');
    Navigator.of(context).pop(
      MaterialReviewDecision.useSuggestedPlan(
        ProductionPlanningConfirmRequest(
          warehouseId: preview.warehouseId,
          idempotencyKey: businessIdempotencyKey(
            'production-planning',
            '$canonical::ATTEMPT::${const Uuid().v4()}',
          ),
          previewFingerprint: preview.fingerprint,
          generatePurchaseRequest: generatePurchaseRequest,
          routes: buildProductionMaterialSupplyRoutes(
            preview.executionSegments,
          ),
          segments: segments,
        ),
      ),
    );
  }

  void _openDetailedPlanning([
    Iterable<ProductionPlanningMaterial> materials =
        const <ProductionPlanningMaterial>[],
  ]) {
    Navigator.of(context).pop(
      MaterialReviewDecision.openDetailedPlanning(
        materials.map((material) => material.goodsId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noBomCount = widget.preview.noBomPlanItemIds.length;
    final hasBlockingBomGaps = widget.preview.hasBlockingBomGaps;
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
                  hint: (m) => '需 ${_q(m.gross)} · 缺 ${_q(m.timelyShortage)}',
                  trailing: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.check_box_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(
                      '自动生成采购申请（必需）',
                      style: theme.textTheme.bodyMedium,
                    ),
                    subtitle: const Text('采购缺口必须形成可跟进的供给单据，此项不可取消。'),
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
                  hint: (m) => '需 ${_q(m.gross)} · 缺 ${_q(m.timelyShortage)}',
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
                  hint: (m) => '需 ${_q(m.gross)} · 缺 ${_q(m.timelyShortage)}',
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
                  note: _buckets.makeNoBom
                          .every((m) => _forwardedGoods.contains(m.goodsId))
                      ? '已通知工程研发部维护，等待完成后即可派生子计划。'
                      : '这些自制件未维护组成 BOM，无法派生子计划。可一键转发工程研发部维护。',
                ),
              if (noBomCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s8),
                  child: _notice(
                    theme,
                    color: theme.colorScheme.error,
                    icon: Icons.report_problem_outlined,
                    text: widget.preview.noBomGoodsIds
                            .every((g) => _forwardedGoods.contains(g))
                        ? '另有 $noBomCount 个成品未维护 BOM，已通知工程研发部维护，等待完成后即可排产。'
                        : '另有 $noBomCount 个成品未维护 BOM。可一键转发工程研发部维护，'
                            '维护完成前不能保存预排草案或正式下达。',
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
        if (_pendingForwardGoods.isNotEmpty)
          OutlinedButton.icon(
            onPressed: _forwarding ? null : _forwardBomGaps,
            icon: _forwarding
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.forward_to_inbox_outlined, size: 18),
            label: const Text('一键转发研发'),
          ),
        OutlinedButton.icon(
          onPressed: () => _openDetailedPlanning(),
          icon: const Icon(Icons.table_view_outlined, size: 18),
          label: const Text('详细排产'),
        ),
        FilledButton.icon(
          onPressed: hasBlockingBomGaps ? null : _confirm,
          icon: const Icon(Icons.auto_awesome_outlined, size: 18),
          label: Text(hasBlockingBomGaps
              ? (_pendingForwardGoods.isEmpty ? '等待研发维护 BOM' : '请先补齐 BOM')
              : '采用建议方案'),
        ),
      ],
    );
  }

  Widget _infoBanner(ThemeData theme) {
    final hasBlockingBomGaps = widget.preview.hasBlockingBomGaps;
    final hasShortage =
        _buckets.buyShortage.isNotEmpty ||
        _buckets.makeShortage.isNotEmpty ||
        _buckets.subcontractShortage.isNotEmpty ||
        _buckets.makeNoBom.isNotEmpty;
    final text = hasBlockingBomGaps
        ? '存在成品或本层自制组件未维护 BOM。为保证完整覆盖，补齐前只能查看详情，不能保存或下达方案。'
        : hasShortage
        ? '系统已按目标仓库存、在途与 BOM 形成建议方案。可直接采用，也可进入详细排产调整数量、车间、班组与日期。'
        : '所有本层物料库存充足。可直接采用建议方案，也可进入详细排产复核车间、班组与日期。';
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: _notice(
        theme,
        color: hasBlockingBomGaps
            ? theme.colorScheme.error
            : theme.colorScheme.primary,
        icon: hasBlockingBomGaps
            ? Icons.report_problem_outlined
            : Icons.info_outline_rounded,
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
      child: DecoratedBox(
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
                  Expanded(
                    child: Text(
                      '$title（$count）',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _openDetailedPlanning(materials),
                    icon: const Icon(Icons.visibility_outlined, size: 16),
                    label: const Text('查看对应详情'),
                  ),
                ],
              ),
            ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  note,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
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
    ThemeData theme,
    ProductionPlanningMaterial m,
    String hint,
  ) {
    final label = [
      m.goodsCode,
      m.goodsName,
      m.spec,
    ].where((s) => s != null && s.isNotEmpty).join(' ');
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
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: '  $hint', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _notice(
    ThemeData theme, {
    required Color color,
    required IconData icon,
    required String text,
  }) {
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
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  static String _q(double? v) => formatProductionPlanningQuantity(v ?? 0);
}

class _Buckets {
  final List<ProductionPlanningMaterial> sufficient;
  final List<ProductionPlanningMaterial> buyShortage;
  final List<ProductionPlanningMaterial> makeShortage;
  final List<ProductionPlanningMaterial> subcontractShortage;
  final List<ProductionPlanningMaterial> makeNoBom;

  _Buckets(
    this.sufficient,
    this.buyShortage,
    this.makeShortage,
    this.subcontractShortage,
    this.makeNoBom,
  );
}
