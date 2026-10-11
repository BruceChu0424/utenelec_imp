// 货品「BOM 学习记录」(ADR-129)：父件累计 + 逐组件设计/真实使用数量。
//
// 真实使用数量 = 已完工且核清余料的生产累计净耗料 ÷ 用到该物料的累计产量，
// 全部由服务端学习累计与视图算好，本面板只展示、不重算：
// - 头部：累计实际产量 / 有效生产批次 / 累计不良；没有自动建立学习组件时
//   说明原因(原因只影响自动建组件，真实使用数量照常累计)；
// - 表格：组装信息里的组件在前，其后是 BOM 外实际用过的料、人工删除后不再
//   自动加入的料(物料格带标记)；
// - 不良：日报登记的不良数只作记录，产量与真实使用数量都只算良品；不良数、
//   实产单耗(净耗 ÷ (良品+不良))与不良率由服务端一并给出，只作说明；
// - 「从现在起重新学习」(服务端按权限下发 canRelearn)：把当前累计记为基线，
//   之后只用新数据，新数据出来前计算按设计使用数量；重学接口直接返回新的
//   学习记录，面板就地换上，并通知组装信息页签重读。
//
// [bomActualUsageTip] 与组装信息表格「真实使用数量」悬停说明共用。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_table_cell_action.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../models/goods_bom_item.dart';
import '../repositories/goods_bom_repository.dart';
import 'master_data_table_view.dart';
import 'goods_bom_material_evidence.dart';

final goodsBomLearningProvider = FutureProvider.autoDispose
    .family<GoodsBomLearningSummary, String>(
      (ref, id) => ref.watch(goodsBomRepositoryProvider).learning(id),
    );

/// 打开「BOM 学习记录」；每重学成功一次调一次 [onRelearned](调用方据此重读
/// 自己展示的真实使用数量)。
Future<void> showGoodsBomLearning(
  BuildContext context,
  String goodsId, {
  VoidCallback? onRelearned,
  bool showMaterialEvidence = false,
}) => showUtenAdaptivePanel<void>(
  context: context,
  // 设计/真实/实产单耗与累计、不良列一屏放下(基准画布 1920)，不用横向滚动。
  drawerWidth: 1700,
  builder: (_) => GoodsBomLearningPanel(
    goodsId: goodsId,
    onRelearned: onRelearned,
    showMaterialEvidence: showMaterialEvidence,
  ),
);

/// 数量带单位展示(不知道单位时只给数)：悬停说明与面板头部共用。
String _qtyWithUnit(double value, String? unit) => unit == null || unit.isEmpty
    ? formatBomQty(value)
    : '${formatBomQty(value)} $unit';

/// 「真实使用数量」悬停说明：计算按哪个数、依据几批已完工生产、累计多少；
/// 有真实值且日报登记过不良时，再补一句按实产(良品+不良)算的用量和不良率。
///
/// [netUnit] 是组件单位(净耗料/平均用量)，[outputUnit] 是父件单位(产量)；
/// 不知道时省略单位。[inBom]=false 是 BOM 外的料：没有边、不参与计算，
/// 只说明累计情况或为什么没有可用数据。多句用换行分隔，三种语言通用。
String bomActualUsageTip(
  AppLocalizations l10n,
  BomActualUsage usage, {
  String? netUnit,
  String? outputUnit,
  bool inBom = true,
}) {
  final average = usage.perUnitQty;
  final perProduced = usage.perProducedQty;
  final defectRate = usage.defectRate;
  final relearnedAt = usage.relearnedAt;
  final reason = bomDesignReasonText(l10n, usage.status?.code);
  return [
    if (usage.status == BomActualStatus.actual) ...[
      l10n.bomActualTipActual(
        usage.sampleCount,
        _qtyWithUnit(usage.netQty, netUnit),
        _qtyWithUnit(usage.outputQty, outputUnit),
      ),
      // 日报登记了不良：产量只算良品，另说一句连不良一起算的用量和不良率。
      if (usage.defectQty > 0 && perProduced != null && defectRate != null)
        l10n.bomActualTipDefect(
          _qtyWithUnit(usage.defectQty, outputUnit),
          _qtyWithUnit(perProduced, netUnit),
          formatBomDefectRate(defectRate),
        ),
      if (usage.usesActual) l10n.bomActualTipUsed,
    ] else
      inBom ? l10n.bomUsesDesignBecause(reason) : reason,
    // 格里显示的不是每件平均时(按包装的边是每包用量，整包/固定批次没有
    // 真实值)补一句每件平均，免得和累计净耗/产量对不上。
    if (average != null && average != usage.qty)
      l10n.bomActualTipAverage(_qtyWithUnit(average, netUnit)),
    if (relearnedAt != null)
      l10n.bomRelearnedSince(ChinaDateTime.formatDate(relearnedAt)),
  ].join('\n');
}

/// 没有自动建立学习组件的原因(人话，不外露内部代码)。
String _blockedText(AppLocalizations l10n, String code) => switch (code) {
  'OUTPUT_IDENTITY_CHANGED' => l10n.bomLearningBlockedOutputIdentity,
  'MATERIAL_IDENTITY_CHANGED' => l10n.bomLearningBlockedMaterialIdentity,
  'MATERIAL_COLOR_OR_UNIT_CONFLICT' => l10n.bomLearningBlockedColorConflict,
  'BOM_QUANTITY_PRECISION' => l10n.bomLearningBlockedPrecision,
  'BOM_CYCLE' => l10n.bomLearningBlockedCycle,
  _ => l10n.bomLearningBlockedOther,
};

class GoodsBomLearningPanel extends ConsumerStatefulWidget {
  const GoodsBomLearningPanel({
    super.key,
    required this.goodsId,
    this.onRelearned,
    this.showMaterialEvidence = false,
  });

  final String goodsId;

  /// 重学成功后通知调用方(组装信息页签据此重读真实使用数量)。
  final VoidCallback? onRelearned;
  final bool showMaterialEvidence;

  @override
  ConsumerState<GoodsBomLearningPanel> createState() =>
      _GoodsBomLearningPanelState();
}

class _GoodsBomLearningPanelState extends ConsumerState<GoodsBomLearningPanel> {
  /// 正在重新学习的组件(防连点重复提交)。
  String? _relearning;

  /// 重学接口返回的最新学习记录：有就优先展示，不再多读一次。
  GoodsBomLearningSummary? _latest;
  bool? _showEvidence;

  @override
  void didUpdateWidget(covariant GoodsBomLearningPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.goodsId != widget.goodsId) {
      _latest = null;
      _showEvidence = null;
    }
  }

  void _refresh() {
    setState(() => _latest = null);
    ref.invalidate(goodsBomLearningProvider(widget.goodsId));
    widget.onRelearned?.call();
  }

  Future<void> _relearn(GoodsBomLearningComponent row) async {
    final l10n = AppLocalizations.of(context);
    final name = row.componentName ?? row.componentCode ?? '';
    final ok = await UtenDialog.show(
      context,
      title: l10n.bomLearningRelearn,
      content: Text(l10n.bomLearningRelearnConfirm(name)),
      confirmLabel: l10n.commonConfirm,
      cancelLabel: l10n.commonCancel,
    );
    if (ok != true || !mounted) return;
    setState(() => _relearning = row.componentGoodsId);
    try {
      final latest = await context.guardAction(
        () => ref
            .read(goodsBomRepositoryProvider)
            .relearn(widget.goodsId, row.componentGoodsId),
        success: l10n.bomLearningRelearnDone,
        errorFallback: l10n.bomLearningRelearnFailed,
      );
      if (latest != null) {
        widget.onRelearned?.call();
        if (mounted) setState(() => _latest = latest);
      }
    } finally {
      if (mounted) setState(() => _relearning = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final result = ref.watch(goodsBomLearningProvider(widget.goodsId));
    final latest = _latest;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.bomLearningTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  key: const Key('bom-learning-refresh'),
                  tooltip: l10n.commonRefresh,
                  onPressed: _relearning == null ? _refresh : null,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(l10n.bomLearningHelp),
            const SizedBox(height: UtenSpacing.s16),
            Expanded(
              child: latest != null
                  ? _content(context, l10n, latest)
                  : result.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (error, _) => Column(
                        children: [
                          Text(
                            error is ApiException
                                ? error.message
                                : l10n.bomLearningLoadFailed,
                          ),
                          UtenButton(
                            onPressed: () => ref.invalidate(
                              goodsBomLearningProvider(widget.goodsId),
                            ),
                            child: Text(l10n.commonRetry),
                          ),
                        ],
                      ),
                      data: (summary) => _content(context, l10n, summary),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    AppLocalizations l10n,
    GoodsBomLearningSummary summary,
  ) {
    final profile = summary.profile;
    // 组装信息里的组件在前，其后 BOM 外实际用过的料、已删除不再自动加入的料；
    // 组内保持服务端顺序。
    int group(GoodsBomLearningComponent row) => row.released
        ? 2
        : row.inBom
        ? 0
        : 1;
    final rows = [
      for (var g = 0; g < 3; g++)
        ...summary.components.where((row) => group(row) == g),
    ];
    final blocked = profile?.blockedReason;
    final outputUnit = profile?.outputUnitName;
    final showEvidence =
        _showEvidence ??
        (widget.showMaterialEvidence ||
            (summary.components.isEmpty &&
                summary.materialEvidence.isNotEmpty));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            UtenButton(
              key: const Key('bom-learning-usage-tab'),
              onPressed: () => setState(() => _showEvidence = false),
              child: const Text('用量学习'),
            ),
            UtenButton(
              key: const Key('bom-learning-evidence-tab'),
              onPressed: () => setState(() => _showEvidence = true),
              child: Text('选料与结构 (${summary.materialEvidence.length})'),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (showEvidence)
          Expanded(
            child: GoodsBomMaterialEvidenceTable(
              rows: summary.materialEvidence,
            ),
          )
        else ...[
          if (profile == null)
            Text(l10n.bomLearningInactive)
          else
            Text(
              '${l10n.bomLearningOutput}: '
              '${_qtyWithUnit(profile.totalOutputQty, outputUnit)} · '
              '${l10n.bomLearningSamples}: ${profile.sampleCount} · '
              '${l10n.bomLearningTotalDefect}: '
              '${_qtyWithUnit(profile.totalDefectQty, outputUnit)}',
            ),
          if (blocked != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            UtenInlineNotice(
              level: UtenInlineNoticeLevel.warning,
              message: l10n.bomLearningPaused(_blockedText(l10n, blocked)),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          Expanded(
            child: MasterDataTableView<GoodsBomLearningComponent>(
              tableKey:
                  'features.basic_data.widgets.goods_bom_learning_panel.GoodsBomLearningPanelState._content.1',
              items: rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              emptyMessage: l10n.bomLearningEmpty,
              columns: _columns(
                l10n,
                outputUnit: outputUnit,
                canRelearn: summary.canRelearn,
              ),
            ),
          ),
        ],
      ],
    );
  }

  List<MasterColumnDef<GoodsBomLearningComponent>> _columns(
    AppLocalizations l10n, {
    required String? outputUnit,
    required bool canRelearn,
  }) {
    /// 服务端没给的数(没有可用数据等)显示「—」；单位内联（2026-10-10 口径）。
    String qtyOrDash(double? value, String? unit) => value == null
        ? '—'
        : formatQtyWithUnit(value, unit, maxDecimals: 6);

    /// 服务端已按状态给好：BOM 外/已删除的料是每个父件的平均用量，
    /// 没有可用数据(含父件单位变了)为空。
    String actualText(GoodsBomLearningComponent row) =>
        qtyOrDash(row.actual.qty, row.unitName);

    /// 这段累计里没有产出时服务端给空。
    String defectRateText(GoodsBomLearningComponent row) {
      final rate = row.actual.defectRate;
      return rate == null ? '—' : formatBomDefectRate(rate);
    }

    String basisText(GoodsBomLearningComponent row) => !row.inBom
        ? '—'
        : row.actual.usesActual
        ? l10n.bomActualQty
        : l10n.bomDesignQty;

    Widget withTip(GoodsBomLearningComponent row, String text) => Tooltip(
      message: bomActualUsageTip(
        l10n,
        row.actual,
        netUnit: row.unitName,
        outputUnit: outputUnit,
        inBom: row.inBom,
      ),
      child: Text(text),
    );

    // 2026-09-29 用户口径：名称列只放名称；学习状态徽章从名称格副行独立成列，
    // 并按「格内胶囊改整格底色」口径走 cellColor（无状态行不铺色）。
    String? learnStateText(GoodsBomLearningComponent row) => row.released
        ? l10n.bomLearningReleased
        : !row.inBom
        ? l10n.bomLearningOutsideBom
        : row.systemLearned
        ? l10n.bomLearnedEdge
        : null;

    // 档位（ADR-169 锚定）：已删除不再自动加入=灰（中性终态）/ BOM 外实际
    // 用过的料=橙（实际耗用未被 BOM 覆盖的注意态，待计划员判定收编——不是
    // 等待外部，原黄档语义不符）/ 系统学习=品红（来源分类强调，非语义状态，
    // 与组装信息表「学习来源」列同色）。
    UtenStatusBadgeType? learnStateType(GoodsBomLearningComponent row) =>
        row.released
        ? UtenStatusBadgeType.neutral
        : !row.inBom
        ? UtenStatusBadgeType.orange
        : row.systemLearned
        ? UtenStatusBadgeType.fuchsia
        : null;

    return [
      MasterColumnDef(
        key: 'learnState',
        label: '状态',
        width: 72,
        value: (row) => learnStateText(row) ?? '—',
        cellColor: (context, row) {
          final type = learnStateType(row);
          return type == null ? null : utenStatusBadgeCellColor(type);
        },
      ),
      MasterColumnDef(
        key: 'material',
        label: l10n.bomLearningMaterial,
        width: 190,
        value: (row) => row.componentName ?? row.componentCode,
      ),
      MasterColumnDef(
        key: 'code',
        label: l10n.materialDiscoveryCode,
        width: 90,
        value: (row) => row.componentCode,
      ),
      // 2026-10-10「数量+单位」全站口径：独立「单位」列退役，组件单位内联进
      // 用量列；产量两列（曝光产量/不良数）是父件口径，内联父件单位 outputUnit。
      MasterColumnDef(
        key: 'designQty',
        label: l10n.bomDesignQty,
        width: 135,
        type: 'number',
        value: (row) => qtyOrDash(row.designQty, row.unitName),
      ),
      MasterColumnDef(
        key: 'actualQty',
        label: l10n.bomActualQty,
        width: 135,
        type: 'number',
        value: actualText,
        cellBuilder: (context, row) => withTip(row, actualText(row)),
      ),
      MasterColumnDef(
        key: 'perProducedQty',
        label: l10n.bomLearningPerProduced,
        width: 135,
        type: 'number',
        // 按实产(良品+不良)的用量，与真实使用数量同一口径；没有真实值为空。
        value: (row) => qtyOrDash(row.actual.perProducedQty, row.unitName),
      ),
      MasterColumnDef(
        key: 'netQty',
        label: l10n.bomLearningNet,
        width: 135,
        type: 'number',
        value: (row) =>
            formatQtyWithUnit(row.actual.netQty, row.unitName, maxDecimals: 6),
      ),
      MasterColumnDef(
        key: 'exposureOutputQty',
        label: l10n.bomLearningExposure,
        width: 125,
        type: 'number',
        value: (row) => formatQtyWithUnit(
          row.actual.outputQty,
          outputUnit,
          maxDecimals: 6,
        ),
      ),
      MasterColumnDef(
        key: 'defectQty',
        label: l10n.bomLearningDefect,
        width: 115,
        type: 'number',
        value: (row) => formatQtyWithUnit(
          row.actual.defectQty,
          outputUnit,
          maxDecimals: 6,
        ),
      ),
      MasterColumnDef(
        key: 'defectRate',
        label: l10n.bomLearningDefectRate,
        width: 76,
        type: 'number',
        value: defectRateText,
      ),
      MasterColumnDef(
        key: 'sampleCount',
        label: l10n.bomLearningSampleCount,
        width: 76,
        type: 'number',
        value: (row) => '${row.actual.sampleCount}',
      ),
      MasterColumnDef(
        key: 'usageBasis',
        label: l10n.bomLearningBasis,
        width: 100,
        value: basisText,
        // BOM 外的料不参与计算(「—」)，说明挂在真实使用数量格上即可。
        cellBuilder: (context, row) =>
            row.inBom ? withTip(row, basisText(row)) : Text(basisText(row)),
      ),
      // 重新学习只对已有累计记录的组件有意义(没有记录就没有可记的基线)。
      if (canRelearn)
        MasterColumnDef(
          key: 'relearn',
          label: l10n.bomLearningAction,
          width: 150,
          value: (row) =>
              row.actual.updatedAt == null ? null : l10n.bomLearningRelearn,
          cellBuilder: (context, row) => row.actual.updatedAt == null
              ? const SizedBox.shrink()
              : UtenTableCellAction(
                  key: ValueKey('goods-bom-relearn-${row.componentGoodsId}'),
                  label: l10n.bomLearningRelearn,
                  onPressed: _relearning == null ? () => _relearn(row) : null,
                ),
        ),
    ];
  }
}
