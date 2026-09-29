// 仓库单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// StockGridRow：货品(选择) + 业务数量/实称重量(非盘点)
// / 账面 + 实盘 + 账面重量 + 实盘重量(盘点)→ 盘盈亏自动(AmountRowMixin)。
// 仓库单据无单价/金额概念；「金额」类比为盘点的"盘盈亏 = 实盘 - 账面"（仅 CHECK）。
// 非盘点类型 amountValue 恒 0（无金额列、无表尾合计）。
// stockGridColumns(onPickGoods, isCheck, weight)：列 = 货品/单位/数量/实称重量(非盘点)
// 或 货品/单位/账面/实盘/账面重量/实盘重量/盘盈亏(自动)(盘点)。
//
// 重量(ADR-135)：重量格是共用的 weightGridColumn(录入单位随用户偏好、带后缀换算、
// 永不批量、货品按重量计时只读「=25 kg」)。其它入库/产成品进仓与盘点的数量空着时，
// 填重量按学到的单重推算数量(黄框待核对，行打上 qtyFromWeight，不参与单重学习)。
import 'package:flutter/material.dart';

import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/providers/master_name_provider.dart';
import 'inbound_registration_widgets.dart' show WarehouseQtyInputField;

/// 仓库明细行。
/// - 非盘点(isCheck=false)：填 [qty](带单位的数量)和可选 [weight](本行实称重量)。
/// - 盘点(isCheck=true)：填 [bookQty](账面)+ [checkQty](实盘)+ 可选 [countWeight]
///   (实盘重量)；[bookWeightKg] 是读余额带出的账面重量(只读)；
///   amountNotifier = 盘盈亏 = 实盘 - 账面(订阅两控制器自动重算)。
class StockGridRow extends EditableGridRow with AmountRowMixin {
  StockGridRow({this.isCheck = false}) {
    // 仅盘点模式连线重算：非盘点无金额概念，amountNotifier 恒 0（不订阅省一次空更新）。
    if (isCheck) {
      bookQty.addListener(_recalc);
      checkQty.addListener(_recalc);
    }
  }

  final bool isCheck;
  String? upstreamItemId;
  String? executionSegmentId;
  String? executionSegmentSalesAllocationId;
  String? colorId;
  String? unitId;
  double unitRate = 1;

  // 只读主档展示（选品/载入时填充）：编号/系列/库位号/颜色名/单位名——仓库对位拣货用。
  String? goodsCode;
  String? goodsSeries;
  String? goodsStockPlace;
  String? colorName;
  String? unitName;

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  /// 非盘点模式的"数量"(对应后端 items.qty)；按称重推算时黄框待核对。
  final UtenAutofillTextController qty = UtenAutofillTextController(
    autofilled: false,
  );

  /// 非盘点模式的本行实称重量(对应后端 items.weight，千克为准；空 = 没称)。
  final WeightEntryController weight = WeightEntryController();

  /// 盘点模式的"账面数量"（对应后端 items.qty；后端按 surplusQty 联动库存）。
  final TextEditingController bookQty = TextEditingController();

  /// 盘点模式的"实盘数量"(对应后端 items.countQty)；按称重推算时黄框待核对。
  final UtenAutofillTextController checkQty = UtenAutofillTextController(
    autofilled: false,
  );

  /// 盘点模式的实盘重量(对应后端 items.countWeight，可选；审核时按它定账面重量)。
  final WeightEntryController countWeight = WeightEntryController();

  /// 盘点模式的账面重量(千克，读余额时带出/保存后的快照；null = 未知或未读取)。
  final ValueNotifier<double?> bookWeightKg = ValueNotifier<double?>(null);

  /// 账面重量含估算(显示「≈」)。先写它再写 [bookWeightKg]，格子随后者重绘。
  bool bookWeightEstimated = false;

  /// 本行生效的数量格(盘点 = 实盘，其它 = 数量)。
  UtenAutofillTextController get activeQty => isCheck ? checkQty : qty;

  /// 本行生效的重量格(盘点 = 实盘重量，其它 = 实称重量)。
  WeightEntryController get activeWeight => isCheck ? countWeight : weight;

  /// 生效数量折成基本单位(盘点单位恒为基本单位)；没填为 null。
  double? get qtyBase {
    final value = double.tryParse(activeQty.text.trim());
    if (value == null) return null;
    return isCheck ? value : value * (unitRate > 0 ? unitRate : 1);
  }

  void _recalc() => recalcAmount(
    () =>
        (double.tryParse(checkQty.text) ?? 0) -
        (double.tryParse(bookQty.text) ?? 0),
  );

  /// 深拷贝(明细复制/粘贴用)：拷货品、录入量(非盘点=数量/重量；盘点=账面/实盘/
  /// 账面重量/实盘重量，盘盈亏随控制器自动重算)与只读主档展示列。重量连同「按称重
  /// 改数量」标记一起拷(复制行是用户显式动作)。上游/执行段来源引用门控不拷——可编辑
  /// 模式下本就为空，防御性排除。
  StockGridRow clone() {
    final c = StockGridRow(isCheck: isCheck)
      ..goods = goods
      ..colorId = colorId
      ..unitId = unitId
      ..unitRate = unitRate
      ..goodsCode = goodsCode
      ..goodsSeries = goodsSeries
      ..goodsStockPlace = goodsStockPlace
      ..colorName = colorName
      ..unitName = unitName
      ..bookWeightEstimated = bookWeightEstimated;
    c.qty.text = qty.text;
    c.weight.setKg(weight.kg, qtyFromWeight: weight.qtyFromWeight);
    c.bookQty.text = bookQty.text;
    c.checkQty.text = checkQty.text;
    c.countWeight.setKg(
      countWeight.kg,
      qtyFromWeight: countWeight.qtyFromWeight,
    );
    c.bookWeightKg.value = bookWeightKg.value;
    return c;
  }

  @override
  void dispose() {
    goodsNotifier.dispose();
    qty.dispose();
    weight.dispose();
    bookQty.dispose();
    checkQty.dispose();
    countWeight.dispose();
    bookWeightKg.dispose();
    super.dispose();
  }
}

/// 仓库单据明细的重量接线(编辑页提供)。
class StockGridWeightWiring {
  const StockGridWeightWiring({
    required this.entryUnit,
    required this.mode,
    required this.paramsOf,
    required this.paramsListenable,
    this.exactKgOf,
    this.onWeighCount,
    this.display = WeightDisplay.auto,
  });

  /// 录入单位(用户偏好「称重单位」)。
  final WeightUnit entryUnit;

  /// 入库(其它入库/产成品进仓) / 出库(其它出库/产成品出仓/调拨/领料) / 盘点。
  final WeightCaptureMode mode;
  final WeightParams? Function(StockGridRow row) paramsOf;

  /// 单重参数到达时通知格子重绘。
  final Listenable paramsListenable;

  /// 按数量精确换算的重量(货品或行单位是重量单位时，格子只读「=25 kg」)；
  /// 不给则只按参数 EXACT × 基本数量判断。
  final double? Function(StockGridRow row)? exactKgOf;

  /// 格内 ⚖ 称重计数；null 不挂按钮。
  final Future<void> Function(BuildContext context, StockGridRow row)?
  onWeighCount;

  /// 只读重量(账面重量)的显示单位。
  final WeightDisplay display;

  /// 数量空着时按称重推算数量(入库与盘点；出库的数量是应发量，不推算)。
  bool get autofillQty => mode != WeightCaptureMode.outbound;
}

/// 仓库明细列。
/// - isCheck=false：货品 / 编码 / 颜色 / 系列 / 库位 / 单位 / 数量 / 实称重量。
/// - isCheck=true：货品 / 编码 / 颜色 / 系列 / 库位 / 单位 / 账面 / 实盘 / 账面重量 /
///   实盘重量 / 盘盈亏(自动)。
///
/// [onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
List<EditableGridColumn<StockGridRow>> stockGridColumns(
  Future<void> Function(StockGridRow row) onPickGoods, {
  bool isCheck = false,
  required StockGridWeightWiring weight,
}) {
  WeightQtyAutofill<StockGridRow>? autofill() => weight.autofillQty
      ? WeightQtyAutofill<StockGridRow>(
          qtyControllerOf: (r) => r.activeQty,
          unitRateOf: (r) => r.isCheck ? 1 : r.unitRate,
        )
      : null;
  String? baseUnitName(StockGridRow r) =>
      r.isCheck || r.unitRate == 1 ? r.unitName : null;

  return [
    EditableGridColumn<StockGridRow>(
      key: 'goods',
      // 2026-09-14 全站列头统一：名称列叫「货品名称」（编号/颜色本表本来就
      // 各有独立列，顺序也已是 名称 → 编号 → 颜色）。
      label: '货品名称',
      width: 200,
      required: true,
      textOf: (r) => r.goods?.name ?? '',
      listenableOf: (r) => r.goodsNotifier,
      // 格尾搜索/锁图标(16)计入自动加宽量宽（2026-09-16）。
      chromeWidth: UtenEditableGridCellSpec.dropdownChevronWidth,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.goodsNotifier,
        isEmpty: () => row.goods == null,
        child: InkWell(
          onTap: () => onPickGoods(row),
          child: InputDecorator(
            decoration: const InputDecoration(isDense: true),
            child: Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<GoodsOption?>(
                    valueListenable: row.goodsNotifier,
                    builder: (context, g, _) => Text(
                      g?.name ?? '点击选择',
                      style: TextStyle(
                        color: g == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
                const Icon(Icons.search_rounded, size: 16),
              ],
            ),
          ),
        ),
      ),
    ),
    // 编码/系列/库位/颜色/单位：行 model 普通字段（选货品后整行重建回填），
    // 无变更通知器可挂——只给 textOf（行集变化时整体量宽），不接实时加宽。
    EditableGridColumn<StockGridRow>(
      key: 'code',
      label: '编号',
      width: 110,
      textOf: (r) => r.goodsCode ?? '',
      cellBuilder: (context, row) => Text(
        row.goodsCode ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    // 颜色原排在系列/库位号之后：同名不同色的物料（自制白色 / 委外香槟金）录单时
    // 极易选错，编号与颜色必须紧跟货品列同屏可见，故上移到编码之后。
    // 已有独立颜色列，货品列就不再重复带颜色。
    EditableGridColumn<StockGridRow>(
      key: 'color',
      label: '颜色',
      width: 80,
      textOf: (r) => r.colorName ?? '',
      cellBuilder: (context, row) => Text(
        row.colorName ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    EditableGridColumn<StockGridRow>(
      key: 'series',
      label: '系列',
      width: 80,
      textOf: (r) => r.goodsSeries ?? '',
      cellBuilder: (context, row) => Text(
        row.goodsSeries ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    EditableGridColumn<StockGridRow>(
      key: 'stockPlace',
      label: '库位号',
      width: 80,
      textOf: (r) => r.goodsStockPlace ?? '',
      cellBuilder: (context, row) => Text(
        row.goodsStockPlace ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    EditableGridColumn<StockGridRow>(
      key: 'unit',
      label: '单位',
      width: 64,
      textOf: (r) => r.unitName ?? '',
      cellBuilder: (context, row) => Text(
        row.unitName ?? '—',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
    if (isCheck) ...[
      EditableGridColumn<StockGridRow>(
        key: 'bookQty',
        label: '账面',
        width: 96,
        numeric: true,
        cellBuilder: (context, row) => TextField(
          readOnly: true,
          controller: row.bookQty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            isDense: true,
            filled: true,
            hintText: '选择货品后读取',
            suffixIcon: Icon(Icons.lock_outline, size: 16),
          ),
        ),
      ),
      EditableGridColumn<StockGridRow>(
        key: 'checkQty',
        label: '实盘',
        width: 110,
        numeric: true,
        required: true,
        // 按称重推算的黄标 ⓘ(44)计入量宽。
        chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
        cellBuilder: (context, row) => RequiredCellFrame(
          listenable: row.checkQty,
          isEmpty: () => row.checkQty.text.trim().isEmpty,
          child: WarehouseQtyInputField(
            fieldKey: const ValueKey('stock-grid-check-qty'),
            controller: row.checkQty,
            hintText: '0',
            sourceOf: () => row.countWeight.qtyEstimateNote ?? '按称重推算的实盘数量，请核对',
          ),
        ),
      ),
      EditableGridColumn<StockGridRow>(
        key: 'bookWeight',
        label: '账面重量',
        width: 110,
        numeric: true,
        headerInfo:
            '读取账面数量时一并带出的库存重量(只读)；「≈」= 含估算，「未称」= 账面重量未知。'
            '填了实盘重量，审核后账面重量按实盘重量定。',
        textOf: (r) => _bookWeightText(r, weight.display),
        listenableOf: (r) => r.bookWeightKg,
        cellBuilder: (context, row) => ValueListenableBuilder<double?>(
          valueListenable: row.bookWeightKg,
          builder: (context, kg, _) => Text(
            _bookWeightText(row, weight.display),
            key: const ValueKey('stock-grid-book-weight'),
            textAlign: TextAlign.right,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      weightGridColumn<StockGridRow>(
        key: 'countWeight',
        label: '实盘重量',
        controllerOf: (r) => r.countWeight,
        entryUnit: weight.entryUnit,
        mode: WeightCaptureMode.count,
        paramsOf: weight.paramsOf,
        paramsListenable: weight.paramsListenable,
        qtyBaseOf: (r) => r.qtyBase,
        qtyListenableOf: (r) => r.checkQty,
        exactKgOf: weight.exactKgOf,
        baseUnitNameOf: baseUnitName,
        qtyAutofill: autofill(),
        onWeighCount: weight.onWeighCount,
      ),
      EditableGridColumn<StockGridRow>(
        key: 'surplus',
        label: '盘盈亏',
        width: 110,
        numeric: true,
        cellBuilder: (context, row) => ValueListenableBuilder<double>(
          valueListenable: row.amountNotifier,
          builder: (_, v, _) => Text(v.toStringAsFixed(2)),
        ),
      ),
    ] else ...[
      EditableGridColumn<StockGridRow>(
        key: 'qty',
        label: '数量',
        width: 110,
        numeric: true,
        required: true,
        // 按称重推算的黄标 ⓘ(44)计入量宽。
        chromeWidth: UtenEditableGridCellSpec.hintIconWidth,
        cellBuilder: (context, row) => RequiredCellFrame(
          listenable: row.qty,
          isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
          child: WarehouseQtyInputField(
            fieldKey: const ValueKey('stock-grid-qty'),
            controller: row.qty,
            hintText: '0',
            sourceOf: () => row.weight.qtyEstimateNote ?? '按称重推算的数量，请核对',
          ),
        ),
      ),
      weightGridColumn<StockGridRow>(
        controllerOf: (r) => r.weight,
        entryUnit: weight.entryUnit,
        mode: weight.mode,
        paramsOf: weight.paramsOf,
        paramsListenable: weight.paramsListenable,
        qtyBaseOf: (r) => r.qtyBase,
        qtyListenableOf: (r) => r.qty,
        exactKgOf: weight.exactKgOf,
        baseUnitNameOf: baseUnitName,
        qtyAutofill: autofill(),
        onWeighCount: weight.onWeighCount,
      ),
    ],
  ];
}

/// 账面重量文本：没读账面为「—」；账面重量未知为「未称」；含估算加「≈」。
String _bookWeightText(StockGridRow row, WeightDisplay display) {
  if (row.bookQty.text.trim().isEmpty) return '—';
  return formatWeightValue(
    row.bookWeightKg.value,
    display: display,
    estimated: row.bookWeightEstimated,
  );
}
