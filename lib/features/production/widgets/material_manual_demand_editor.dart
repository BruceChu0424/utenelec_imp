// 物料分析「手工需求单」录入(ADR-130)。
//
// 一张手工需求单 = 一个单头(来源类型 / 需求编号 / 来源原因 / 需求日期) + 多行货品
// (货品 / 数量 / 可选的行需求日)，用自家可编辑明细表 UtenEditableGrid 录入，与销售
// 订单录入同一范式：点货品格弹多选选货滑窗，第一个填当前行，其余依次填后面的空行、
// 不够再追加新行。
//
// 手工需求不另建持久化单据：每一行货品在本页生成一条物料分析来源，与勾选的销售订单
// 产品一起联合分析(ADR-029 模型不变)。规则：同一(来源类型, 需求编号)只属于一份物料
// 分析；一个编号下可以有多个货品；同一货品(货品 + 颜色 + 单位)在一个编号下只出现一次。
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/providers/editable_grid_column_prefs.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/editable_grid_totals_bar.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../models/production_material_analysis.dart';

/// 手工需求的来源类型(服务端白名单)，值是界面上给人看的名字。
const materialManualDemandSourceTypes = <String, String>{
  'REWORK': '返工',
  'TRIAL': '试制',
  'SAMPLE': '样品',
  'STOCK': '备库',
  'OTHER': '其他',
};

/// 需求编号最长字符数(与服务端来源编号上限一致)。
const int materialManualDemandRefMaxLength = 200;

/// 单头「需求日期」与行「需求日」共用的可选范围：行日期默认取单头日期，
/// 两处范围不一致时，单头选了范围外的日期会让行日期选择器打不开。
final DateTime materialManualDemandFirstDate = DateTime(2020);
final DateTime materialManualDemandLastDate = DateTime(2100);

/// 行「需求日」选择器的初始日期：行日期 ?? 单头日期 ?? 今天，并夹进可选范围。
DateTime materialManualDemandPickerInitialDate(
  DateTime? lineDate,
  DateTime? headerDate,
) {
  final initial = lineDate ?? headerDate ?? ChinaDateTime.today();
  if (initial.isBefore(materialManualDemandFirstDate)) {
    return materialManualDemandFirstDate;
  }
  if (initial.isAfter(materialManualDemandLastDate)) {
    return materialManualDemandLastDate;
  }
  return initial;
}

/// 手工需求选货入口的函数签名：返回所选货品(按选择顺序、无重复 id)，取消返回空列表。
typedef MaterialManualGoodsPicker =
    Future<List<GoodsListItem>> Function(BuildContext context, WidgetRef ref);

/// 手工需求单「货品名称」格的选货入口(多选、除未分类外全部分类，与销售订单同款)。
/// 独立成 provider，组件测试可以换成固定结果，不必驱动整套分类树 + 分页选货面板。
final materialAnalysisManualGoodsPickerProvider =
    Provider<MaterialManualGoodsPicker>(
      (ref) =>
          (context, ref) => showUtenGoodsPickerMulti(
            context,
            ref,
            scope: UtenGoodsPickerScope.allExceptUncategorized,
          ),
    );

/// 一个手工需求编号下的货品身份：货品 + 颜色 + 单位(与服务端来源身份同口径)。
String materialManualGoodsIdentity(GoodsListItem goods) =>
    '${goods.id}|${goods.colorId ?? ''}|${goods.unitId ?? ''}';

/// 手工需求单的一行货品。货品 / 行需求日用 [ValueNotifier]，数量用控制器——
/// 单元格各自订阅，敲字只重绘本格(UtenEditableGrid 行模型约定)。
class MaterialManualDemandLine extends EditableGridRow {
  MaterialManualDemandLine({
    GoodsListItem? goods,
    String qty = '',
    DateTime? needDate,
  }) : goodsNotifier = ValueNotifier<GoodsListItem?>(goods),
       qty = TextEditingController(text: qty),
       needDate = ValueNotifier<DateTime?>(needDate) {
    // 校验标红(重复货品)「改动即消除」，下次分析重新判定。
    goodsNotifier.addListener(_clearFlagged);
    this.qty.addListener(_clearFlagged);
  }

  final ValueNotifier<GoodsListItem?> goodsNotifier;
  GoodsListItem? get goods => goodsNotifier.value;
  set goods(GoodsListItem? value) => goodsNotifier.value = value;

  final TextEditingController qty;

  /// 行需求日：空 = 按单头的需求日期。
  final ValueNotifier<DateTime?> needDate;

  /// 没选货品也没填数量的行不算录入内容(分析时忽略)。
  bool get isBlank => goods == null && qty.text.trim().isEmpty;

  double? get qtyValue {
    final value = double.tryParse(qty.text.trim());
    return value == null || !value.isFinite ? null : value;
  }

  void _clearFlagged() {
    if (flagged) flagged = false;
  }

  /// 深拷贝(表格右键「复制选中 / 粘贴」用)。
  MaterialManualDemandLine clone() => MaterialManualDemandLine(
    goods: goods,
    qty: qty.text,
    needDate: needDate.value,
  );

  @override
  void dispose() {
    goodsNotifier.dispose();
    qty.dispose();
    needDate.dispose();
    super.dispose();
  }
}

/// 一张手工需求单(单头 + 货品明细表控制器)。页面持有、页面释放。
class MaterialManualDemandDraft {
  MaterialManualDemandDraft({
    this.sourceType,
    String sourceRef = '',
    String reason = '',
    DateTime? date,
    List<MaterialManualDemandLine>? lines,
  }) : refController = TextEditingController(text: sourceRef),
       reasonController = TextEditingController(text: reason),
       date = ValueNotifier<DateTime?>(date),
       grid = UtenEditableGridController<MaterialManualDemandLine>(
         initial: lines ?? [MaterialManualDemandLine()],
       );

  /// 来源类型(见 [materialManualDemandSourceTypes] 的 key)；null = 还没选。
  String? sourceType;
  final TextEditingController refController;
  final TextEditingController reasonController;

  /// 单头需求日期：行需求日为空的货品都按它要货。
  final ValueNotifier<DateTime?> date;
  final UtenEditableGridController<MaterialManualDemandLine> grid;

  /// 已选货品的行数(计入「本次分析」项数与 500 上限)。
  int get goodsLineCount {
    var count = 0;
    for (var i = 0; i < grid.length; i++) {
      if (grid[i].goods != null) count++;
    }
    return count;
  }

  bool get hasHeaderInput =>
      refController.text.trim().isNotEmpty ||
      reasonController.text.trim().isNotEmpty;

  /// 单头或明细里有人录过东西(删单前是否要确认)。
  bool get hasInput {
    if (hasHeaderInput) return true;
    for (var i = 0; i < grid.length; i++) {
      if (!grid[i].isBlank) return true;
    }
    return false;
  }

  void dispose() {
    refController.dispose();
    reasonController.dispose();
    date.dispose();
    grid.dispose();
  }
}

/// 手工需求单转成物料分析来源的结果：要么全部来源，要么一句给人看的错误。
class MaterialManualDemandSourcesResult {
  const MaterialManualDemandSourcesResult.valid(this.sources)
    : error = null,
      draftIndex = null,
      flaggedLines = const [];

  const MaterialManualDemandSourcesResult.invalid(
    String this.error, {
    this.draftIndex,
    this.flaggedLines = const [],
  }) : sources = const [];

  /// 每行货品一条来源(单的顺序、行的顺序)。
  final List<MaterialAnalysisSourceInput> sources;
  final String? error;

  /// 出错的是第几张单(0 起)；null = 不是某一张单的问题。
  final int? draftIndex;

  /// 需要标红提示的行(如同一张单里重复的货品)。
  final List<MaterialManualDemandLine> flaggedLines;

  bool get isValid => error == null;
}

/// 把页面上的手工需求单整理成物料分析来源，并做提交前校验(纯函数，不弹提示)。
///
/// - 没选货品也没填数量的空行忽略；单头没填、明细也空的单整张忽略；
/// - 每行来源：来源类型 / 需求编号(去首尾空格) / 货品 + 颜色 + 单位 / 数量 /
///   来源原因(去首尾空格) / 需求日期 = 行需求日 ?? 单头需求日期 ?? [defaultDeliveryDate]；
/// - [otherSourceCount] 是同一次分析里已勾选的销售订单产品数，与手工行合计不超过
///   [maxSources]，两边都没有时提示先选。
MaterialManualDemandSourcesResult buildMaterialManualDemandSources(
  List<MaterialManualDemandDraft> drafts, {
  DateTime? defaultDeliveryDate,
  int otherSourceCount = 0,
  int maxSources = 500,
}) {
  String label(int index) =>
      drafts.length > 1 ? '第 ${index + 1} 张手工需求单' : '手工需求单';
  final sources = <MaterialAnalysisSourceInput>[];
  final numberOwner = <String, int>{};
  for (var index = 0; index < drafts.length; index++) {
    final draft = drafts[index];
    final rows = draft.grid.rows;
    final contentRows = <int>[
      for (var row = 0; row < rows.length; row++)
        if (!rows[row].isBlank) row,
    ];
    if (contentRows.isEmpty) {
      if (!draft.hasHeaderInput) continue;
      return MaterialManualDemandSourcesResult.invalid(
        drafts.length > 1
            ? '${label(index)}还没有选货品：请在表格里选择货品，或删除这张单'
            : '${label(index)}还没有选货品：请在表格里选择货品；不录手工需求就清空需求编号和来源原因',
        draftIndex: index,
      );
    }
    final sourceType = draft.sourceType;
    if (sourceType == null ||
        !materialManualDemandSourceTypes.containsKey(sourceType)) {
      return MaterialManualDemandSourcesResult.invalid(
        '${label(index)}请选择来源类型(返工、试制、样品、备库或其他)',
        draftIndex: index,
      );
    }
    final sourceRef = draft.refController.text.trim();
    if (sourceRef.isEmpty) {
      return MaterialManualDemandSourcesResult.invalid(
        '${label(index)}请填写需求编号',
        draftIndex: index,
      );
    }
    if (sourceRef.length > materialManualDemandRefMaxLength) {
      return MaterialManualDemandSourcesResult.invalid(
        '${label(index)}的需求编号不能超过 $materialManualDemandRefMaxLength 个字符',
        draftIndex: index,
      );
    }
    final reason = draft.reasonController.text.trim();
    if (reason.length < 2) {
      return MaterialManualDemandSourcesResult.invalid(
        '${label(index)}请填写来源原因(至少 2 个字)',
        draftIndex: index,
      );
    }
    final rowsByGoods = <String, List<int>>{};
    for (final row in contentRows) {
      final line = rows[row];
      final goods = line.goods;
      if (goods == null) {
        return MaterialManualDemandSourcesResult.invalid(
          '${label(index)}第 ${row + 1} 行还没选货品',
          draftIndex: index,
          flaggedLines: [line],
        );
      }
      final qty = line.qtyValue;
      if (qty == null || qty <= 0) {
        return MaterialManualDemandSourcesResult.invalid(
          '${label(index)}第 ${row + 1} 行「${_goodsLabel(goods)}」的数量必须大于 0',
          draftIndex: index,
          flaggedLines: [line],
        );
      }
      rowsByGoods
          .putIfAbsent(materialManualGoodsIdentity(goods), () => [])
          .add(row);
    }
    for (final group in rowsByGoods.values) {
      if (group.length < 2) continue;
      final goods = rows[group.first].goods!;
      return MaterialManualDemandSourcesResult.invalid(
        '${label(index)}里「${_goodsLabel(goods)}」重复了'
        '(第 ${group.map((row) => row + 1).join('、')} 行)；同一货品请合并成一行',
        draftIndex: index,
        flaggedLines: [for (final row in group) rows[row]],
      );
    }
    final numberKey = '$sourceType|${sourceRef.toLowerCase()}';
    final owner = numberOwner[numberKey];
    if (owner != null) {
      return MaterialManualDemandSourcesResult.invalid(
        '第 ${owner + 1} 张和第 ${index + 1} 张手工需求单用了同一个需求编号「$sourceRef」；'
        '同一编号的货品请录在同一张单里',
        draftIndex: index,
      );
    }
    numberOwner[numberKey] = index;
    final headerDate = draft.date.value ?? defaultDeliveryDate;
    for (final row in contentRows) {
      final line = rows[row];
      final goods = line.goods!;
      final date = line.needDate.value ?? headerDate;
      sources.add(
        MaterialAnalysisSourceInput(
          sourceType: sourceType,
          sourceRef: sourceRef,
          goodsId: goods.id,
          colorId: goods.colorId,
          unitId: goods.unitId,
          requestedQty: line.qtyValue!,
          sourceReason: reason,
          deliveryDate: date == null ? null : ChinaDateTime.formatDate(date),
        ),
      );
    }
  }
  final total = sources.length + otherSourceCount;
  if (total == 0) {
    return const MaterialManualDemandSourcesResult.invalid(
      '请先勾选销售订单产品，或在「手工需求」里选择货品',
    );
  }
  if (total > maxSources) {
    return MaterialManualDemandSourcesResult.invalid(
      '单次联合分析最多 $maxSources 项(销售订单产品与手工需求合计)，当前 $total 项；'
      '请拆成多个分析批次',
    );
  }
  return MaterialManualDemandSourcesResult.valid(sources);
}

/// 一次多选选货落到手工需求单的结果。
class MaterialManualDemandPickResult {
  const MaterialManualDemandPickResult({
    this.added = 0,
    this.duplicates = 0,
    this.capped = 0,
  });

  /// 落进表格的货品数(含点选的那一行)。
  final int added;

  /// 本单已有、被跳过的货品数。
  final int duplicates;

  /// 超过本次分析 500 项上限、没有加入的货品数。
  final int capped;
}

/// 把多选结果落到 [draft]：第一个填 [target] 行，其余依次填它后面的空行，
/// 不够再追加新行；本单已有的货品跳过(同一编号下同一货品只能一行)。
///
/// [remainingSlots] 是本次分析还能再加入的项数(500 减去已选销售订单产品和已选货品的
/// 手工行)；[target] 原本就有货品时，换货不占新名额。
MaterialManualDemandPickResult applyMaterialManualDemandPick(
  MaterialManualDemandDraft draft,
  MaterialManualDemandLine target,
  List<GoodsListItem> picked, {
  required int remainingSlots,
}) {
  final rows = draft.grid.rows;
  final targetIndex = rows.indexOf(target);
  if (targetIndex < 0 || picked.isEmpty) {
    return const MaterialManualDemandPickResult();
  }
  final taken = <String>{
    for (final line in rows)
      if (!identical(line, target) && line.goods != null)
        materialManualGoodsIdentity(line.goods!),
  };
  var slots = remainingSlots < 0 ? 0 : remainingSlots;
  if (target.goods != null) slots++;
  final accepted = <GoodsListItem>[];
  var duplicates = 0;
  var capped = 0;
  for (final goods in picked) {
    if (!taken.add(materialManualGoodsIdentity(goods))) {
      duplicates++;
      continue;
    }
    if (accepted.length >= slots) {
      capped++;
      continue;
    }
    accepted.add(goods);
  }
  if (accepted.isEmpty) {
    return MaterialManualDemandPickResult(
      duplicates: duplicates,
      capped: capped,
    );
  }
  target.goods = accepted.first;
  var next = 1;
  for (
    var row = targetIndex + 1;
    row < rows.length && next < accepted.length;
    row++
  ) {
    final line = rows[row];
    if (line.isBlank) line.goods = accepted[next++];
  }
  if (next < accepted.length) {
    draft.grid.addRows([
      for (final goods in accepted.skip(next))
        MaterialManualDemandLine(goods: goods),
    ]);
  }
  return MaterialManualDemandPickResult(
    added: accepted.length,
    duplicates: duplicates,
    capped: capped,
  );
}

String _goodsLabel(GoodsListItem goods) {
  final name = goods.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  final code = goods.code?.trim();
  return code == null || code.isEmpty ? '所选货品' : code;
}

/// 手工需求单货品明细表的列：货品名称(点选) / 编号 / 颜色 / 规格 / 单位(随货品带出，
/// 只读) / 数量(必填) / 需求日(选填，空 = 按单头需求日期)。
List<EditableGridColumn<MaterialManualDemandLine>>
materialManualDemandGridColumns({
  required void Function(MaterialManualDemandLine line) onPickGoods,
  required String? Function(GoodsListItem goods) colorNameOf,
  required String? Function(GoodsListItem goods) unitNameOf,
  required ValueListenable<DateTime?> headerDate,
  bool enabled = true,
}) {
  Widget goodsAttribute(
    MaterialManualDemandLine line,
    String? Function(GoodsListItem goods) valueOf,
  ) => ValueListenableBuilder<GoodsListItem?>(
    valueListenable: line.goodsNotifier,
    builder: (context, goods, _) =>
        UtenGoodsAttributeCell(goods == null ? null : valueOf(goods)),
  );
  return [
    EditableGridColumn<MaterialManualDemandLine>(
      key: 'goods',
      label: '货品名称',
      width: 200,
      required: true,
      textOf: (line) => line.goods?.name ?? '',
      listenableOf: (line) => line.goodsNotifier,
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, line) => RequiredCellFrame(
        listenable: line.goodsNotifier,
        isEmpty: () => line.goods == null,
        child: InkWell(
          onTap: enabled ? () => onPickGoods(line) : null,
          child: InputDecorator(
            decoration: const InputDecoration(isDense: true),
            child: Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<GoodsListItem?>(
                    valueListenable: line.goodsNotifier,
                    builder: (context, goods, _) => goods == null
                        ? Text(
                            '点击选择',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          )
                        : UtenGoodsIdentityCell(name: goods.name ?? goods.code),
                  ),
                ),
                const Icon(Icons.search_rounded, size: 16),
              ],
            ),
          ),
        ),
      ),
    ),
    EditableGridColumn<MaterialManualDemandLine>(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      textOf: (line) => line.goods?.code ?? '',
      listenableOf: (line) => line.goodsNotifier,
      cellBuilder: (context, line) =>
          goodsAttribute(line, (goods) => goods.code),
    ),
    EditableGridColumn<MaterialManualDemandLine>(
      key: 'color',
      label: '颜色',
      width: 100,
      textOf: (line) =>
          line.goods == null ? '' : colorNameOf(line.goods!) ?? '',
      listenableOf: (line) => line.goodsNotifier,
      cellBuilder: (context, line) => goodsAttribute(line, colorNameOf),
    ),
    EditableGridColumn<MaterialManualDemandLine>(
      key: 'spec',
      label: '规格',
      width: 140,
      textOf: (line) => line.goods?.spec ?? '',
      listenableOf: (line) => line.goodsNotifier,
      cellBuilder: (context, line) =>
          goodsAttribute(line, (goods) => goods.spec),
    ),
    EditableGridColumn<MaterialManualDemandLine>(
      key: 'unit',
      label: '单位',
      width: 90,
      textOf: (line) => line.goods == null ? '' : unitNameOf(line.goods!) ?? '',
      listenableOf: (line) => line.goodsNotifier,
      cellBuilder: (context, line) => goodsAttribute(line, unitNameOf),
    ),
    EditableGridColumn<MaterialManualDemandLine>(
      key: 'qty',
      exactValueOf: (r) => r.qty.text,
      exactListenableOf: (r) => r.qty,
      label: '数量',
      width: 120,
      numeric: true,
      required: true,
      frozenTextOf: (line) => line.qty.text,
      cellBuilder: (context, line) => RequiredCellFrame(
        listenable: line.qty,
        isEmpty: () => (line.qtyValue ?? 0) <= 0,
        child: TextField(
          controller: line.qty,
          enabled: enabled,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, hintText: '0'),
          ),
        ),
      ),
    ),
    EditableGridColumn<MaterialManualDemandLine>(
      key: 'needDate',
      label: '需求日',
      width: 150,
      headerInfo: '不填就按单头的需求日期；个别货品要货日期不同时在这里单独改',
      textOf: (line) => line.needDate.value == null
          ? ''
          : ChinaDateTime.formatDate(line.needDate.value!),
      listenableOf: (line) => line.needDate,
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, line) => ValueListenableBuilder<DateTime?>(
        valueListenable: line.needDate,
        builder: (context, value, _) {
          final theme = Theme.of(context);
          return InkWell(
            onTap: enabled
                ? () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: materialManualDemandPickerInitialDate(
                        value,
                        headerDate.value,
                      ),
                      firstDate: materialManualDemandFirstDate,
                      lastDate: materialManualDemandLastDate,
                    );
                    if (picked != null) line.needDate.value = picked;
                  }
                : null,
            child: InputDecorator(
              decoration: const InputDecoration(isDense: true),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value == null ? '同单头' : ChinaDateTime.formatDate(value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: value == null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (value != null && enabled)
                    InkResponse(
                      radius: 16,
                      onTap: () => line.needDate.value = null,
                      child: Tooltip(
                        message: '改回按单头需求日期',
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    const Icon(Icons.event_outlined, size: 16),
                ],
              ),
            ),
          );
        },
      ),
    ),
  ];
}

/// 手工需求单表尾合计：数量(按单位分组，绝不跨单位相加)。
/// 行数由 EditableGridTotalsBar 的 rowCount 统一出口（「总行数: N 行」）。
List<UtenTotalEntry> materialManualDemandTotals(
  List<MaterialManualDemandLine> rows,
  String? Function(GoodsListItem goods) unitNameOf,
) {
  final goodsRows = [
    for (final row in rows)
      if (row.goods != null) row,
  ];
  return [
    utenQuantityTotalEntry([
      for (final row in goodsRows)
        MeasuredAmount(
          value: row.qtyValue ?? 0,
          unitId: row.goods!.unitId,
          unitName: unitNameOf(row.goods!),
        ),
    ], label: '数量'),
  ];
}

/// 一张手工需求单：单头四个字段 + 货品明细表(自家 UtenEditableGrid)。
///
/// 数据全在 [draft] 里(控制器跨重建存活)；来源类型改动与选货由页面接管，
/// 页面据此刷新「本次分析 N 项」计数。
class MaterialManualDemandCard extends ConsumerWidget {
  const MaterialManualDemandCard({
    super.key,
    required this.draft,
    required this.index,
    required this.cardCount,
    required this.onSourceTypeChanged,
    required this.onPickGoods,
    this.onRemove,
    this.enabled = true,
    this.compact = false,
  });

  final MaterialManualDemandDraft draft;

  /// 第几张单(0 起)，用于标题与测试锚点。
  final int index;
  final int cardCount;
  final ValueChanged<String?> onSourceTypeChanged;
  final void Function(MaterialManualDemandLine line) onPickGoods;

  /// 删除此单；null = 不显示删除入口(只剩一张单时)。
  final VoidCallback? onRemove;
  final bool enabled;
  final bool compact;

  /// 列设置分桶 key：各张手工需求单共用同一套列布局。
  static const String columnPrefsMode = 'manualDemand';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final columnPrefs = ref.watch(
      materialAnalysisManualDemandGridColumnPrefsProvider,
    )[columnPrefsMode];
    String? colorNameOf(GoodsListItem goods) =>
        _nonEmpty(goods.colorName) ?? names.colorEntries[goods.colorId ?? ''];
    String? unitNameOf(GoodsListItem goods) =>
        _nonEmpty(goods.unitName) ?? names.unitEntries[goods.unitId ?? ''];
    return Container(
      key: ValueKey('manual-demand-card-$index'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(theme),
          const SizedBox(height: UtenSpacing.s12),
          _headerFields(theme),
          const SizedBox(height: UtenSpacing.s12),
          // 分析请求进行中([enabled] 为 false)：来源已按当时的明细交给服务端，
          // 表格整块只看不动——行尾删除收起，「添加行」、右键粘贴与键盘操作也
          // 一并拦住，保证看到的明细就是提交的明细。
          IgnorePointer(
            ignoring: !enabled,
            child: ExcludeFocus(
              excluding: !enabled,
              child: UtenEditableGrid<MaterialManualDemandLine>(
                tableKey:
                    'features.production.widgets.material_manual_demand_editor.MaterialManualDemandCard.build.1',
                key: ValueKey('manual-demand-grid-$index'),
                controller: draft.grid,
                columns: materialManualDemandGridColumns(
                  onPickGoods: onPickGoods,
                  colorNameOf: colorNameOf,
                  unitNameOf: unitNameOf,
                  headerDate: draft.date,
                  enabled: enabled,
                ),
                createBlankRow: MaterialManualDemandLine.new,
                cloneRow: (line) => line.clone(),
                selectionEnabled: enabled,
                canDeleteRow: (_) => enabled,
                emptyMessage: '这张单还没有货品，点下方「添加行」后选择货品',
                deleteConfirmLabel: '确认删除这一行货品？',
                initialColumnOrder: columnPrefs?.order,
                initialHiddenColumnKeys: columnPrefs?.hidden,
                initialPinnedColumnKeys: columnPrefs?.pinned,
                onColumnSettingsChanged: (order, hidden, pinned) => ref
                    .read(
                      materialAnalysisManualDemandGridColumnPrefsProvider
                          .notifier,
                    )
                    .updateFor(columnPrefsMode, order, hidden, pinned),
                footer: EditableGridTotalsBar<MaterialManualDemandLine>(
                  controller: draft.grid,
                  watchOf: (line) => [line.qty],
                  entriesBuilder: (rows) =>
                      materialManualDemandTotals(rows, unitNameOf),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _title(ThemeData theme) {
    final goodsCount = draft.goodsLineCount;
    final removeKey = ValueKey('manual-demand-remove-$index');
    return Row(
      children: [
        Icon(Icons.assignment_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text.rich(
            TextSpan(
              text: cardCount > 1 ? '手工需求单 ${index + 1}' : '手工需求单',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
              children: [
                TextSpan(
                  text: '   已选 $goodsCount 个货品',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onRemove != null)
          compact
              ? IconButton(
                  key: removeKey,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: '删除此单',
                  onPressed: enabled ? onRemove : null,
                  icon: const Icon(Icons.delete_outline_rounded),
                )
              : TextButton.icon(
                  key: removeKey,
                  onPressed: enabled ? onRemove : null,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('删除此单'),
                ),
      ],
    );
  }

  Widget _headerFields(ThemeData theme) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = compact || width < 560
          ? 1
          : width < 900
          ? 2
          : 4;
      return UtenFormGrid(
        columns: columns,
        children: [
          UtenDropdownField(
            key: ValueKey('manual-demand-type-$index'),
            label: '来源类型',
            required: true,
            allowClear: false,
            value: draft.sourceType,
            enabled: enabled,
            items: [
              for (final entry in materialManualDemandSourceTypes.entries)
                UtenDropdownItem(value: entry.key, label: entry.value),
            ],
            onChanged: onSourceTypeChanged,
          ),
          _RequiredTextField(
            key: ValueKey('manual-demand-ref-$index'),
            controller: draft.refController,
            label: '需求编号',
            info: '同一需求请始终使用同一个编号，后续可凭它找回任务',
            hintText: '例：RW-20260808-001',
            maxLength: materialManualDemandRefMaxLength,
            enabled: enabled,
          ),
          _RequiredTextField(
            key: ValueKey('manual-demand-reason-$index'),
            controller: draft.reasonController,
            label: '来源原因',
            hintText: '例：客诉返工、展会样品、安全备库',
            enabled: enabled,
          ),
          ValueListenableBuilder<DateTime?>(
            valueListenable: draft.date,
            builder: (context, value, _) => UtenDateField(
              key: ValueKey('manual-demand-date-$index'),
              label: '需求日期',
              value: value,
              firstDate: materialManualDemandFirstDate,
              lastDate: materialManualDemandLastDate,
              enabled: enabled,
              info: '单里的货品默认按这个日期要货；个别货品不同，在表格「需求日」列单独改',
              onChanged: (date) => draft.date.value = date,
            ),
          ),
        ],
      );
    },
  );
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// 单头必填文本框：空时红框(全站「必填空红框」口径)，填了即恢复。
class _RequiredTextField extends StatelessWidget {
  const _RequiredTextField({
    super.key,
    required this.controller,
    required this.label,
    this.info,
    this.hintText,
    this.maxLength,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final String? info;
  final String? hintText;
  final int? maxLength;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        enabled: enabled,
        maxLength: maxLength,
        decoration: applyRequiredEmpty(
          UtenInputDecoration(
            InputDecoration(
              label: fieldLabel(label, theme, required: true, info: info),
              hintText: hintText,
              counterText: '',
            ),
          ),
          theme,
          requiredEmpty: enabled && value.text.trim().isEmpty,
        ),
      ),
    );
  }
}
