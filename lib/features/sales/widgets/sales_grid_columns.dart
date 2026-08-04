// 销售单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// SalesGridRow：货品(选择)/数量/单价→金额自动（AmountRowMixin）；颜色/单位 + 上游明细 id
// 为透传（从上游引入或详情回填时预填，保存时随行写回）；V66 报表补列（机加价/围数/进仓/
// 材料价/压铸价/折扣）按 docType 显隐对应列。
// salesGridColumns：货品/颜色/单位/数量/单价/金额 + V66 补列（条件）。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import 'sales_doc_link_picker.dart';

/// 销售明细行。货品用 [ValueNotifier]（点选后单元格自动刷新，无需 setState）；
/// 数量/单价控制器变更 → 自动重算金额（amountNotifier）。
///
/// 颜色/单位 + 上游明细 id（orderItemId/outItemId）为透传字段（详情回填或上游引入时预填，
/// 保存时随行写回，UI 单元格只读/下拉同步到 row 字段）。V66 报表补列（ machiningPrice 等）
/// 按 docType 在列定义中显隐对应列。
class SalesGridRow extends EditableGridRow with AmountRowMixin {
  SalesGridRow() {
    qty.addListener(_recalc);
    price.addListener(_recalc);
    // 校验红标（保存时标记，用户改动任一必填内容即自动消除）。
    goodsNotifier.addListener(_clearInvalid);
    qty.addListener(_clearInvalid);
    price.addListener(_clearInvalid);
  }

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController qty = TextEditingController();
  final TextEditingController price = TextEditingController();

  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 直接映射为
  /// orderItemId/outItemId —— 销售双挂所以两 id 各自独立透传，不像采购三选一）。
  String? orderItemId;
  String? outItemId;

  /// 颜色/单位（选货品后自动回填或上游引入预填；单元格只读显示）。
  /// 用 ValueNotifier：选货品后单元格即时刷新（与 goodsNotifier 同款），无需整页 setState。
  final colorIdNotifier = ValueNotifier<String?>(null);
  String? get colorId => colorIdNotifier.value;
  set colorId(String? v) => colorIdNotifier.value = v;
  final unitIdNotifier = ValueNotifier<String?>(null);
  String? get unitId => unitIdNotifier.value;
  set unitId(String? v) => unitIdNotifier.value = v;

  /// 退货专属：处理方案 / 责任单位（仅 returnDoc 显列）。
  final solutionNotifier = ValueNotifier<String?>(null);
  String? get solution => solutionNotifier.value;
  set solution(String? v) => solutionNotifier.value = v;
  final responsibleNotifier = ValueNotifier<String?>(null);
  String? get responsible => responsibleNotifier.value;
  set responsible(String? v) => responsibleNotifier.value = v;

  // V66 报表补列：成本分项/包装派生/折扣。空文本不随 body 提交（后端按 nullable 处理）。
  // order：机加价/围数/进仓数量（inNo/outNo 是系统字段，不入录）。
  // shipment/other_shipment：材料价/压铸价/机加价/围数/折扣。
  // return：折扣。
  final machiningPrice = TextEditingController();
  final circumference = TextEditingController();
  final inboundQty = TextEditingController();
  final materialPrice = TextEditingController();
  final dieCastPrice = TextEditingController();
  final discount = TextEditingController();

  /// 行备注（5 类单据通用，网格末列；空文本不随 body 提交）。
  final remark = TextEditingController();

  /// 行级校验红标：保存拦截时置 true（货品/数量/单价缺失的格变红），
  /// 用户改货品/数量/单价即自动清除。
  final invalidNotifier = ValueNotifier<bool>(false);

  void _clearInvalid() {
    if (invalidNotifier.value) invalidNotifier.value = false;
  }

  /// 从上游引入项构造（货品/数量/单价/upstream/颜色/单位 预填）。
  factory SalesGridRow.fromLinked(SalesLinkedItem li, GoodsOption goods) {
    final r = SalesGridRow()
      ..goods = goods
      ..orderItemId = li.orderItemId
      ..outItemId = li.outItemId
      ..colorId = li.colorId
      ..unitId = li.unitId;
    r.qty.text = li.qty.toString();
    if (li.price != null) r.price.text = li.price.toString();
    return r;
  }

  void _recalc() => recalcAmount(
    () => (double.tryParse(qty.text) ?? 0) * (double.tryParse(price.text) ?? 0),
  );

  /// 深拷贝（明细复制/粘贴用）：新建行 + 拷贝各控制器文本 + 透传字段 + 自动重算金额。
  SalesGridRow clone() {
    final c = SalesGridRow()
      ..goods = goods
      ..orderItemId = orderItemId
      ..outItemId = outItemId
      ..colorId = colorId
      ..unitId = unitId;
    c.qty.text = qty.text;
    c.price.text = price.text;
    c.machiningPrice.text = machiningPrice.text;
    c.circumference.text = circumference.text;
    c.inboundQty.text = inboundQty.text;
    c.materialPrice.text = materialPrice.text;
    c.dieCastPrice.text = dieCastPrice.text;
    c.discount.text = discount.text;
    c.remark.text = remark.text;
    return c;
  }

  @override
  void dispose() {
    goodsNotifier.dispose();
    colorIdNotifier.dispose();
    unitIdNotifier.dispose();
    solutionNotifier.dispose();
    responsibleNotifier.dispose();
    qty.dispose();
    price.dispose();
    machiningPrice.dispose();
    circumference.dispose();
    inboundQty.dispose();
    materialPrice.dispose();
    dieCastPrice.dispose();
    discount.dispose();
    remark.dispose();
    invalidNotifier.dispose();
    super.dispose();
  }
}

/// 销售明细列：货品（点选）/ 颜色 / 单位 / 数量 / 单价 / 金额（自动）+ V66 报表补列（按
/// [docType] 条件追加）。[onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
/// [colorEntries]/[unitEntries] 由编辑页从 SalesMasterNameService 注入（单元格下拉用）。
List<EditableGridColumn<SalesGridRow>> salesGridColumns({
  required Future<void> Function(SalesGridRow row) onPickGoods,
  required SalesDocType docType,
  required Map<String, String> colorEntries,
  required Map<String, String> unitEntries,
}) {
  final priceRequired = docType != SalesDocType.otherShipment;
  return [
    EditableGridColumn<SalesGridRow>(
      key: 'goods',
      label: '货品',
      width: 220,
      required: true,
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
    EditableGridColumn<SalesGridRow>(
      key: 'color',
      label: '颜色',
      width: 130,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.colorIdNotifier, colorEntries),
    ),
    EditableGridColumn<SalesGridRow>(
      key: 'unit',
      label: '单位',
      width: 110,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.unitIdNotifier, unitEntries),
    ),
    EditableGridColumn<SalesGridRow>(
      key: 'qty',
      label: '数量',
      width: 96,
      numeric: true,
      required: true,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.qty,
        isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.qty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    ),
    EditableGridColumn<SalesGridRow>(
      key: 'price',
      label: '单价',
      width: 96,
      numeric: true,
      required: priceRequired,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.price,
        isEmpty: () =>
            priceRequired &&
            (row.price.text.trim().isEmpty ||
                double.tryParse(row.price.text.trim()) == null),
        child: TextField(
          controller: row.price,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    ),
    EditableGridColumn<SalesGridRow>(
      key: 'amount',
      label: '金额',
      width: 110,
      numeric: true,
      cellBuilder: (context, row) => ValueListenableBuilder<double>(
        valueListenable: row.amountNotifier,
        builder: (_, v, _) => Text('¥${v.toStringAsFixed(2)}'),
      ),
    ),
    // V66 报表补列（与 _save/_init 字段映射一致；按 docType 显隐）。
    if (docType == SalesDocType.order ||
        docType == SalesDocType.shipment ||
        docType == SalesDocType.otherShipment)
      _extraNumericColumn('机加价', 'machiningPrice', (r) => r.machiningPrice),
    if (docType == SalesDocType.order ||
        docType == SalesDocType.shipment ||
        docType == SalesDocType.otherShipment)
      _extraNumericColumn('围数', 'circumference', (r) => r.circumference),
    if (docType == SalesDocType.order)
      _extraNumericColumn('进仓数量', 'inboundQty', (r) => r.inboundQty),
    if (docType == SalesDocType.shipment ||
        docType == SalesDocType.otherShipment)
      _extraNumericColumn('材料价', 'materialPrice', (r) => r.materialPrice),
    if (docType == SalesDocType.shipment ||
        docType == SalesDocType.otherShipment)
      _extraNumericColumn('压铸价', 'dieCastPrice', (r) => r.dieCastPrice),
    if (docType == SalesDocType.shipment ||
        docType == SalesDocType.otherShipment ||
        docType == SalesDocType.returnDoc)
      _extraNumericColumn('折扣', 'discount', (r) => r.discount),
    // 退货专属：处理方案 / 责任单位（无字典端点，用预置业务选项）。
    if (docType == SalesDocType.returnDoc) ...[
      EditableGridColumn<SalesGridRow>(
        key: 'solution',
        label: '处理方案',
        width: 124,
        cellBuilder: (context, row) => _returnDropdown(
          row.solutionNotifier,
          const ['退款', '换货', '补发', '维修后返还', '其他'],
          hint: '处理方案',
        ),
      ),
      EditableGridColumn<SalesGridRow>(
        key: 'responsible',
        label: '责任单位',
        width: 110,
        cellBuilder: (context, row) => _returnDropdown(
          row.responsibleNotifier,
          const ['本公司', '客户', '物流', '供应商', '其他'],
          hint: '责任单位',
        ),
      ),
    ],
    // 行备注：5 类单据通用，固定放网格末列。
    EditableGridColumn<SalesGridRow>(
      key: 'remark',
      label: '备注',
      width: 160,
      cellBuilder: (context, row) => TextField(
        controller: row.remark,
        decoration: const InputDecoration(isDense: true, hintText: '备注'),
      ),
    ),
  ];
}

/// 只读主档字段单元格（颜色/单位自动回填后用）：显示 entries[id] 名，空显示「—」。
Widget _readOnlyMasterCell(
  BuildContext context,
  ValueNotifier<String?> notifier,
  Map<String, String> entries,
) {
  final theme = Theme.of(context);
  return ValueListenableBuilder<String?>(
    valueListenable: notifier,
    builder: (context, id, _) {
      final name = (id != null && id.isNotEmpty) ? entries[id] : null;
      final hasName = name != null && name.isNotEmpty;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          hasName ? name : '—',
          style: TextStyle(
            color: hasName ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    },
  );
}

/// V66 补列 numeric 列工厂：右对齐数字输入框（与数量/单价同款）。
EditableGridColumn<SalesGridRow> _extraNumericColumn(
  String label,
  String key,
  TextEditingController Function(SalesGridRow row) controller,
) {
  return EditableGridColumn<SalesGridRow>(
    key: key,
    label: label,
    width: 100,
    numeric: true,
    cellBuilder: (context, row) => TextField(
      controller: controller(row),
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(isDense: true, hintText: '0'),
    ),
  );
}

/// 退货「处理方案 / 责任单位」下拉单元格：订阅 [notifier]，预置业务选项。
Widget _returnDropdown(
  ValueNotifier<String?> notifier,
  List<String> options, {
  required String hint,
}) {
  return ValueListenableBuilder<String?>(
    valueListenable: notifier,
    builder: (context, value, _) => DropdownButtonFormField<String>(
      initialValue: options.contains(value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(isDense: true, hintText: hint),
      items: [
        for (final o in options)
          DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) => notifier.value = v,
    ),
  );
}
