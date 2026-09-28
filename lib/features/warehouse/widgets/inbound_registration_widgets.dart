// 入库登记共用界面件(2026-09-27 用户口径：产成品入库与采购/委外入库 UI、逻辑、表格、
// 格式一致，能公用的都公用)。两类任务中心的多选路线按钮、两类批量/单张登记页的提交
// 按钮、确认弹窗要点、批量校验汇总句式、明细表共用列(货品 / 编号 / 颜色 / 单位 /
// 数量 / 入库仓库 / 库位号)与库位建议提示条都从这里取，改一处两边同步。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../models/inbound_registration_line.dart';
import 'warehouse_autofill_text_field.dart';

/// 入库登记数量的唯一显示口径(最多 4 位小数，去尾零)。
String inboundQty(num value) => procurementQty(value);

/// 入库仓库显示名：主仓 / 子仓全称优先(两类登记页一致)。
String? inboundWarehouseLabel(MasterNameService names, String? id) {
  if (id == null || id.isEmpty) return null;
  return warehouseFullLabel(names.warehouseHierarchy, id) ??
      names.warehouse(id);
}

/// 批量校验提示：把同一类违规的**全部**行汇总成一句话。
///
/// 条目多时只列前 8 条再折成「等 N 行」——刷屏的提示和只报第一行一样没法用。
/// [unit] 供报工单、货品这类非行维度的汇总复用同一句式。
String inboundRowIssueMessage(
  List<String> rowLabels,
  String issue, {
  required String action,
  String unit = '行',
}) {
  const shownMax = 8;
  final shown = rowLabels.take(shownMax).join('、');
  final more = rowLabels.length > shownMax ? '等 ${rowLabels.length} $unit' : '';
  return '以下 ${rowLabels.length} $unit$issue，$action：$shown$more';
}

/// 任务中心多选的两颗路线按钮(「先入库后质检(N)」「先质检后入库(N)」并排)。
///
/// 点哪颗就把路线带进批量登记页，批量页只显示那一条路线的提交按钮。
/// 「先入库后质检」只对持有独立权限的账号显示(服务端同样兜底)。
List<Widget> inboundRouteBatchButtons(
  BuildContext context, {
  required int count,
  required bool canStockInFirst,
  required ValueChanged<InboundRoute> onSelected,
  required String emptyWarning,
  bool busy = false,
  Map<InboundRoute, String> extraHints = const {},
}) {
  Widget button(InboundRoute route) {
    final extra = extraHints[route];
    return Tooltip(
      message: count == 0
          ? '$emptyWarning：${route.hint}'
          : '${route.hint}${extra == null ? '' : '；$extra'}',
      child: UtenButton(
        key: route.batchKey,
        size: UtenButtonSize.large,
        // 「点了就往下走一步」的主路线红底白字；另一条路线常规样式。
        type: route.isStockInFirst
            ? UtenButtonType.primary
            : UtenButtonType.danger,
        icon: route.icon,
        isLoading: busy,
        onPressed: busy || count == 0 ? null : () => onSelected(route),
        onDisabledTap: count == 0
            ? () => context.appWarning(emptyWarning)
            : null,
        child: Text(count == 0 ? route.label : '${route.label}($count)'),
      ),
    );
  }

  return [
    if (canStockInFirst) button(InboundRoute.stockInFirst),
    button(InboundRoute.inspectFirst),
  ];
}

/// 登记页的路线提交按钮(批量页只放进页时选定的那一颗；单张页两颗并排)。
class InboundRouteSubmitButton extends StatelessWidget {
  const InboundRouteSubmitButton({
    super.key,
    required this.route,
    required this.onPressed,
    this.onDisabledTap,
    this.isLoading = false,
    this.tooltip,
  });

  final InboundRoute route;
  final VoidCallback? onPressed;
  final VoidCallback? onDisabledTap;
  final bool isLoading;

  /// 覆盖默认的路线说明(登记页按来源补充细节时用)。
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip ?? route.hint,
    child: UtenButton(
      key: route.submitKey,
      // 「点了就往下走一步」的主动作统一红底白字(全站口径)。
      type: UtenButtonType.danger,
      size: UtenButtonSize.large,
      isLoading: isLoading,
      icon: route.icon,
      onPressed: onPressed,
      onDisabledTap: onDisabledTap,
      child: Text(route.label),
    ),
  );
}

/// 确认弹窗正文：一行一个要点(· 前缀)，比整段连排短一半以上。
/// [extra] 是只在特定条件下才追加的那一条(如跨仓预定提示)，用警示色区分。
class InboundConfirmPoints extends StatelessWidget {
  const InboundConfirmPoints(this.points, {super.key, this.extra});

  final List<String> points;
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget line(String text, {Color? color}) => Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Text(
        '· $text',
        style: theme.textTheme.bodyMedium?.copyWith(color: color),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final point in points) line(point),
        if (extra != null) line(extra!, color: theme.colorScheme.error),
      ],
    );
  }
}

/// 明细表上方的说明行：来源单据张数 + 勾选口径(两类批量页同一句式)。
class InboundGridIntro extends StatelessWidget {
  const InboundGridIntro({
    super.key,
    required this.sourceSummary,
    required this.submitLabel,
  });

  /// 如「来自 3 张订货单」「来自 2 张报工单(其中 1 张已登记，只读)」。
  final String sourceSummary;

  /// 右下提交按钮名(批量页 = 所选路线；单张页 = 两条路线并列)。
  final String submitLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(sourceSummary, style: style),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          '明细默认全选：右下「$submitLabel」只提交勾选的行，未勾选的行不登记、'
          '不写库存，仍留在任务中心待登记(可重新勾回)；本次不收的也可点行末 ⊖ '
          '移出本次登记(可勾选多行后右键批量移出)。勾选多行后在任意一行改仓库或写库位，'
          '会一起写到全部勾选行。',
          style: style,
        ),
      ],
    );
  }
}

/// 库位建议加载中 / 失败提示条(失败可重试，不拦提交——库位可直接手填)。
class InboundPlaceSuggestionStatus extends StatelessWidget {
  const InboundPlaceSuggestionStatus({
    super.key,
    required this.loader,
    required this.onRetry,
  });

  final InboundPlaceSuggestionLoader loader;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: loader,
    builder: (context, _) {
      final loading = loader.loading;
      final error = loader.error;
      if (!loading && error == null) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final foreground = loading
          ? theme.colorScheme.onSecondaryContainer
          : theme.colorScheme.onErrorContainer;
      return Padding(
        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
        child: Card(
          key: const Key('inbound-place-suggestion-status'),
          margin: EdgeInsets.zero,
          color: loading
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Row(
              children: [
                if (loading)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(Icons.error_outline_rounded, color: foreground),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    loading ? '正在读取所选仓库的默认库位，完成前暂不能提交。' : error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
                if (!loading) ...[
                  const SizedBox(width: UtenSpacing.s8),
                  UtenButton(
                    type: UtenButtonType.tonal,
                    onPressed: onRetry,
                    child: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 明细表下方合计条：数量严格按单位分组(不同单位绝不相加)；仓库不看价格故无金额。
Widget inboundTotalsBar<T extends InboundRegistrationLine>({
  required Key key,
  required List<T> lines,
  required String qtyLabel,
  required double Function(T line) qtyOf,
  required String? Function(T line) unitIdOf,
  required String? Function(T line) unitNameOf,
}) => UtenTotalsSummaryBar(
  key: key,
  density: true,
  entries: [
    UtenTotalEntry('明细', '${lines.length} 行'),
    utenQuantityTotalEntry(
      lines.map(
        (line) => MeasuredAmount(
          value: qtyOf(line),
          unitId: unitIdOf(line),
          unitName: unitNameOf(line),
        ),
      ),
      label: qtyLabel,
    ),
  ],
);

/// 表头筛选桶标签：空白与主档未解析的「—」不建桶(返回 null → 计入「未填」)。
String? inboundBucket(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed == '—') return null;
  return trimmed;
}

/// 明细表共用列：列名、宽度、格式、交互在两类登记页完全一致。
///
/// 列序口径(2026-09-27 统一)：来源单号 → 货品名称 → 编号 → 颜色 → 应收数量 →
/// 本次实收 → 单位 → 入库仓库 → 库位号 →(采购另有物料系列)。
class InboundGridColumns<T extends InboundRegistrationLine> {
  const InboundGridColumns({
    required this.names,
    required this.keyPrefix,
    required this.lineKeyOf,
    required this.goodsCodeOf,
    required this.colorNameOf,
    required this.unitNameOf,
  });

  final MasterNameService names;

  /// 单元格键前缀(如 `warehouse-arrival-batch`)，键 = `前缀-列-行键`。
  final String keyPrefix;
  final String Function(T line) lineKeyOf;
  final String Function(T line) goodsCodeOf;
  final String? Function(T line) colorNameOf;

  /// 单位显示名(行模型已按主档解析；null 显示「—」)。
  final String? Function(T line) unitNameOf;

  String _color(T line) => colorNameOf(line) ?? names.color(line.colorId);
  String _unit(T line) => unitNameOf(line) ?? '—';

  EditableGridColumn<T> goodsName() => EditableGridColumn(
    key: 'goodsName',
    label: '货品名称',
    width: 200,
    filterValueOf: (line) => inboundBucket(line.goodsName),
    textOf: (line) => line.goodsName,
    // 单行省略号(全站口径)：列宽随 textOf 自动加宽兜底。
    cellBuilder: (context, line) => Tooltip(
      message: line.goodsName,
      child: Text(line.goodsName, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );

  /// 编号是货品资料的身份快照，登记页只读。
  EditableGridColumn<T> goodsCode() => EditableGridColumn(
    key: 'goodsCode',
    label: '编号',
    width: 130,
    textOf: goodsCodeOf,
    cellBuilder: (context, line) {
      final code = goodsCodeOf(line);
      return Text(
        code.isEmpty ? '—' : code,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    },
  );

  EditableGridColumn<T> color() => EditableGridColumn(
    key: 'color',
    label: '颜色',
    width: 100,
    filterValueOf: (line) => inboundBucket(_color(line)),
    textOf: _color,
    cellBuilder: (context, line) => Text(_color(line)),
  );

  EditableGridColumn<T> unit() => EditableGridColumn(
    key: 'unit',
    label: '单位',
    width: 70,
    filterValueOf: (line) => inboundBucket(_unit(line)),
    textOf: _unit,
    cellBuilder: (context, line) => Text(_unit(line)),
  );

  /// 只读数量列(批准剩余 / 报工数量)。
  EditableGridColumn<T> quantity({
    required String key,
    required String label,
    required String Function(T line) textOf,
  }) => EditableGridColumn(
    key: key,
    label: label,
    width: 100,
    numeric: true,
    textOf: textOf,
    cellBuilder: (context, line) =>
        Text(textOf(line), textAlign: TextAlign.right),
  );

  /// 「本次实收」录入列(必填、大于 0；空或非正数红框)。
  EditableGridColumn<T> receivedQuantity({
    required TextEditingController? Function(T line) controllerOf,
    required bool Function(T line) enabled,
    required String headerInfo,
    String Function(T line)? readOnlyTextOf,
  }) => EditableGridColumn(
    key: 'qty',
    label: '本次实收',
    width: 130,
    numeric: true,
    required: true,
    headerInfo: headerInfo,
    textOf: (line) =>
        controllerOf(line)?.text ?? readOnlyTextOf?.call(line) ?? '',
    listenableOf: controllerOf,
    cellBuilder: (context, line) {
      final controller = controllerOf(line);
      if (controller == null) {
        return Text(
          readOnlyTextOf?.call(line) ?? '—',
          textAlign: TextAlign.right,
        );
      }
      return RequiredCellFrame(
        listenable: controller,
        isEmpty: () => (double.tryParse(controller.text.trim()) ?? 0) <= 0,
        child: Semantics(
          textField: true,
          label: '${line.goodsName} 本次实收',
          child: TextField(
            key: ValueKey('$keyPrefix-qty-${lineKeyOf(line)}'),
            controller: controller,
            enabled: enabled(line),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            decoration: const UtenInputDecoration(
              InputDecoration(hintText: '大于 0', isDense: true),
            ),
          ),
        ),
      );
    },
  );

  /// 入库仓库(行级必填)：未选红框、预填黄框；勾选多行时点任一行改仓 = 整批落值。
  ///
  /// [changedAwayOf] 为真时描橙边提醒(如改离订货单建议仓：合格库存不再计入原
  /// 物料分析目标仓备料)。
  EditableGridColumn<T> warehouse({
    required bool required,
    required bool Function(T line) enabled,
    required void Function(T line) onTap,
    required String autofillInfo,
    Widget Function(BuildContext context, T line)? lockedBuilder,
    bool Function(T line)? changedAwayOf,
  }) => EditableGridColumn(
    key: 'warehouse',
    label: '入库仓库',
    width: 170,
    required: required,
    filterValueOf: (line) =>
        inboundBucket(inboundWarehouseLabel(names, line.warehouseId)),
    textOf: (line) => inboundWarehouseLabel(names, line.warehouseId) ?? '未选择',
    listenableOf: (line) => line.warehouse,
    // 格尾箭头(20) + 预填黄标 ⓘ(44)计入量宽。
    chromeWidth:
        UtenEditableGridCellSpec.dropdownChevronWidth +
        UtenEditableGridCellSpec.hintIconWidth,
    cellBuilder: (context, line) {
      if (line.locked && lockedBuilder != null) {
        return lockedBuilder(context, line);
      }
      final theme = Theme.of(context);
      final label = inboundWarehouseLabel(names, line.warehouseId);
      final canEdit = enabled(line) && !line.locked;
      return Semantics(
        button: true,
        label: '${line.goodsName} 入库仓库：${label ?? '未选择'}，点击修改',
        child: InkWell(
          key: ValueKey('$keyPrefix-wh-${lineKeyOf(line)}'),
          onTap: canEdit ? () => onTap(line) : null,
          borderRadius: BorderRadius.circular(UtenRadius.control),
          child: InputDecorator(
            // 单元规格统一：圆角、内边距、字号吃 UtenEditableGrid 行级主题。
            decoration: applyAutofillHint(
              UtenInputDecoration(
                InputDecoration(
                  isDense: true,
                  enabledBorder: label == null && canEdit
                      ? requiredEmptyBorder(theme)
                      : label != null && (changedAwayOf?.call(line) ?? false)
                      ? autofillHintBorder(theme)
                      : null,
                ),
                info: line.warehouseAutofilled ? autofillInfo : null,
              ),
              theme,
              autofilled: label != null && line.warehouseAutofilled,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label ?? '必选 · 点击选择',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: label == null && canEdit
                        ? theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w600,
                          )
                        : null,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  /// 库位号：[required] 为真时空值红框；预填/建议值黄框待核对(ⓘ 说明来源)。
  EditableGridColumn<T> place({
    required bool required,
    required bool Function(T line) enabled,
    required void Function(T line, String value) onChanged,
    required String headerInfo,
  }) => EditableGridColumn(
    key: 'place',
    label: '库位号',
    width: 160,
    required: required,
    headerInfo: headerInfo,
    textOf: (line) => line.place.text,
    listenableOf: (line) => line.place,
    // 预填黄标 ⓘ(44)计入量宽。
    chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
    cellBuilder: (context, line) {
      final canEdit = enabled(line) && !line.locked;
      final field = Semantics(
        textField: true,
        label: '${line.goodsName} 库位号',
        child: WarehouseAutofillTextField(
          key: ValueKey('$keyPrefix-place-${lineKeyOf(line)}'),
          controller: line.place,
          source: line.placeSource.reviewHint,
          // 建议异步回填时来源随控制器通知一起变：重绘时现取，不用父级上次构建的旧值。
          sourceOf: () => line.placeSource.reviewHint,
          enabled: canEdit,
          hintText: required ? '必填' : '可修改',
          inputFormatters: [LengthLimitingTextInputFormatter(100)],
          onChanged: canEdit ? (value) => onChanged(line, value) : null,
        ),
      );
      if (!canEdit || !required) return field;
      return RequiredCellFrame(
        listenable: line.place,
        isEmpty: () => line.place.text.trim().isEmpty,
        child: field,
      );
    },
  );
}
