// 销售单据明细可编辑表的行模型 + 列定义（UtenEditableGrid 用）。
//
// SalesGridRow：货品(选择)/数量/单位/单价→金额自动（AmountRowMixin）；
// 颜色/单位换算率 + 上游明细 id
// 为透传（从上游引入或详情回填时预填，保存时随行写回）；报表补列（机加价/围数/进仓/
// 材料价/压铸价/折扣）按 docType 显隐对应列。
// 2026-09-04 口径：实际重量列下线（单位已表达重量；行模型 weight 保留透传），
// 单位列紧跟数量。折扣列表头 ⓘ 悬停说明「1 = 原价；0.9 = 9折」。
// salesGridColumns：货品/颜色/数量/单位/单价/金额 + 补列（条件）。
import 'package:flutter/material.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../../components/inputs/uten_input_decoration.dart';

import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/ui/app_notification.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import 'sales_doc_link_picker.dart';

final _salesOrderDiscountPattern = RegExp(r'^(?:0\.\d{1,4}|1(?:\.0{1,4})?)$');

/// 销售订单折扣的新写口径：倍率大于 0 且不大于 1，最多四位小数。
/// 科学计数法、NaN/Infinity 和超过数据库 NUMERIC(18,4) 精度的输入均拒绝，
/// 避免客户端预览与服务端落库舍入不一致。
bool isValidSalesOrderDiscountText(String raw) {
  final text = raw.trim();
  final value = double.tryParse(text);
  if (value == null || !value.isFinite || value <= 0 || value > 1) {
    return false;
  }
  return _salesOrderDiscountPattern.hasMatch(text);
}

/// 销售明细行。货品用 [ValueNotifier]（点选后单元格自动刷新，无需 setState）；
/// 数量/单价控制器变更 → 自动重算金额（amountNotifier）。
///
/// [documentItemId] 是当前单据自身明细 UUID；orderItemId/outItemId 只表示上游来源。
/// 颜色/单位 + 上游明细 id 为透传字段（详情回填或上游引入时预填，保存时随行写回，
/// UI 单元格只读/下拉同步到 row 字段）。报表补列（ machiningPrice 等）
/// 按 docType 在列定义中显隐对应列。
class SalesGridRow extends EditableGridRow with AmountRowMixin {
  /// 订单：金额 = 数量 × 单价 × 折扣(主档折扣仅作默认值，销售可在订单行调整)；
  /// 其它单据类型仍 = 数量 × 单价。
  /// 标志隔离订单折扣语义，避免出货/退货等单据的折扣列影响其金额（与各自后端口径一致）。
  final bool amountUsesDiscount;

  SalesGridRow({this.amountUsesDiscount = false}) {
    qty.addListener(_recalc);
    price.addListener(_recalc);
    discount.addListener(_recalc);
    // 校验红标（保存时标记，用户改动任一必填内容即自动消除）。
    goodsNotifier.addListener(_clearInvalid);
    qty.addListener(_clearInvalid);
    price.addListener(_clearInvalid);
    discount.addListener(_clearInvalid);
    // 新销售订单默认原价倍率；货品主档折扣或用户输入随后可覆盖。
    if (amountUsesDiscount) discount.text = '1';
  }

  final ValueNotifier<GoodsOption?> goodsNotifier = ValueNotifier<GoodsOption?>(
    null,
  );
  GoodsOption? get goods => goodsNotifier.value;
  set goods(GoodsOption? v) => goodsNotifier.value = v;

  final TextEditingController qty = TextEditingController();
  final TextEditingController weight = TextEditingController();
  final TextEditingController price = TextEditingController();

  /// 复制既有销售订货行时，冻结价不能直接成为“新行”的价格预览。
  /// true 表示必须重新选择货品，从当前主档取得价格后才允许保存。
  bool requiresOrderPriceRefresh = false;

  /// 货品选择后的只读价格预览。即使当前货品未维护售价也必须清空旧值，
  /// 避免换货后仍显示上一货品的价格。
  void applyLockedPricePreview(num? value) {
    requiresOrderPriceRefresh = false;
    price.text = value?.toString() ?? '';
  }

  /// 当前单据自身明细 UUID。仅受控更新既有销售订货行时回传为 JSON `id`。
  ///
  /// 不可与 [orderItemId] 混用：后者是出货/退货等下游单据对来源订货行的引用。
  String? documentItemId;

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
  double? unitRate;
  String? unitRateExact;

  /// 库位号（只读，货品主档带出；出货/其它出货/退货实物单据的拣货/上架指引，
  /// 异步补全后自动刷新）。
  final stockPlaceNotifier = ValueNotifier<String?>(null);

  /// 退货专属：处理方案 / 责任单位（仅 returnDoc 显列）。
  final solutionNotifier = ValueNotifier<String?>(null);
  String? get solution => solutionNotifier.value;
  set solution(String? v) => solutionNotifier.value = v;
  final responsibleNotifier = ValueNotifier<String?>(null);
  String? get responsible => responsibleNotifier.value;
  set responsible(String? v) => responsibleNotifier.value = v;

  // 报表补列：成本分项/包装派生/折扣。空文本不随 body 提交（后端按 nullable 处理）。
  // order：机加价/围数/进仓数量（inNo/outNo 是系统字段，不入录）。
  // other_shipment：材料价/压铸价/机加价/围数/折扣；shipment 已精简，不展示这些补列。
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
  factory SalesGridRow.fromLinked(
    SalesLinkedItem li,
    GoodsOption goods, {
    bool amountUsesDiscount = false,
  }) {
    final r = SalesGridRow(amountUsesDiscount: amountUsesDiscount)
      ..goods = goods
      ..orderItemId = li.orderItemId
      ..outItemId = li.outItemId
      ..colorId = li.colorId
      ..unitId = li.unitId
      ..unitRate = li.unitRate;
    r.qty.text = li.qty.toString();
    if (li.price != null) r.price.text = li.price.toString();
    return r;
  }

  void _recalc() => recalcAmount(() {
    final q = double.tryParse(qty.text) ?? 0;
    final p = double.tryParse(price.text) ?? 0;
    if (!amountUsesDiscount) return q * p;
    // 订单：金额 = 数量 × 单价 × 折扣倍率；空/0 的 1 倍兼容仅用于旧数据回填。
    final d = double.tryParse(discount.text);
    final mult = (d == null || !d.isFinite)
        ? 0.0
        : d == 0
        ? 1.0
        : d;
    return q * p * mult;
  });

  /// 深拷贝（明细复制/粘贴用）：新建行 + 拷贝各控制器文本 + 透传字段 + 自动重算金额。
  SalesGridRow clone({bool requireOrderPriceRefresh = false}) {
    // 复制产生的是新明细，绝不能复制当前单据行 UUID；否则受控修订会覆盖原行。
    final c = SalesGridRow(amountUsesDiscount: amountUsesDiscount)
      ..goods = goods
      ..orderItemId = orderItemId
      ..outItemId = outItemId
      ..colorId = colorId
      ..unitId = unitId
      ..unitRate = unitRate
      ..unitRateExact = unitRateExact;
    c.qty.text = qty.text;
    c.weight.text = weight.text;
    c.requiresOrderPriceRefresh =
        requireOrderPriceRefresh && amountUsesDiscount && goods != null;
    if (!c.requiresOrderPriceRefresh) c.price.text = price.text;
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
    stockPlaceNotifier.dispose();
    solutionNotifier.dispose();
    responsibleNotifier.dispose();
    qty.dispose();
    weight.dispose();
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

/// 销售明细列：货品（点选）/ 颜色 / 单位 / 数量 / 单价 / 金额（自动）+ 报表补列（按
/// [docType] 条件追加）。[onPickGoods] 由编辑页提供（弹货品选择器并写回 row.goods）。
/// [colorEntries]/[unitEntries] 由编辑页从 SalesMasterNameService 注入（单元格下拉用）。
List<EditableGridColumn<SalesGridRow>> salesGridColumns({
  required BuildContext context,
  required Future<void> Function(SalesGridRow row) onPickGoods,
  required SalesDocType docType,
  required Map<String, String> colorEntries,
  required Map<String, String> unitEntries,
  bool freeCustomerShipment = false,
}) {
  final priceRequired =
      docType != SalesDocType.otherShipment && !freeCustomerShipment;
  // 列说明统一挂表头 ⓘ（2026-09-09 口径）：每行重复的 ⓘ 既冗余又挤占格宽。
  final l10n = workflowFieldText(context);
  final qtyHint = switch (docType) {
    SalesDocType.order => l10n.workflowOrderQuantityHint,
    SalesDocType.returnDoc => l10n.workflowReturnQuantityHint,
    _ => l10n.workflowQuantityHint,
  };
  final priceHint =
      (docType == SalesDocType.order || docType == SalesDocType.shipment)
      ? _lockedPriceHint
      : docType == SalesDocType.returnDoc
      ? l10n.workflowReturnPriceHint
      : l10n.workflowPriceHint;
  return [
    EditableGridColumn<SalesGridRow>(
      key: 'goods',
      label: '货品',
      width: 220,
      required: true,
      textOf: (r) => r.goods?.name ?? '',
      listenableOf: (r) => r.goodsNotifier,
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
      textOf: (r) => colorEntries[r.colorId ?? ''] ?? '',
      listenableOf: (r) => r.colorIdNotifier,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.colorIdNotifier, colorEntries),
    ),
    // 实物出入库单据（出货/其它出货/退货=hasWarehouse）：库位号（主档带出，拣货/上架指引）。
    if (const [
      SalesDocType.shipment,
      SalesDocType.otherShipment,
      SalesDocType.returnDoc,
    ].contains(docType))
      EditableGridColumn<SalesGridRow>(
        key: 'stockPlace',
        label: '库位号',
        width: 90,
        textOf: (r) => r.stockPlaceNotifier.value ?? '',
        listenableOf: (r) => r.stockPlaceNotifier,
        cellBuilder: (context, row) => ValueListenableBuilder<String?>(
          valueListenable: row.stockPlaceNotifier,
          builder: (_, v, _) => Text(
            (v == null || v.isEmpty) ? '—' : v,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: (v == null || v.isEmpty)
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    EditableGridColumn<SalesGridRow>(
      key: 'qty',
      label: '数量',
      width: 128,
      numeric: true,
      required: true,
      headerInfo: qtyHint,
      cellBuilder: (context, row) => RequiredCellFrame(
        listenable: row.qty,
        isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
        child: TextField(
          controller: row.qty,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const UtenInputDecoration(
            InputDecoration(isDense: true, hintText: '0'),
          ),
        ),
      ),
    ),
    // 单位紧跟数量（2026-09-04 口径）：单位已表达重量，实际重量列下线（行模型
    // weight 字段保留，编辑既有单回填并随保存透传，不丢历史数据）。
    EditableGridColumn<SalesGridRow>(
      key: 'unit',
      label: '单位',
      width: 110,
      textOf: (r) => unitEntries[r.unitId ?? ''] ?? '',
      listenableOf: (r) => r.unitIdNotifier,
      cellBuilder: (context, row) =>
          _readOnlyMasterCell(context, row.unitIdNotifier, unitEntries),
    ),
    if (!freeCustomerShipment)
      EditableGridColumn<SalesGridRow>(
        key: 'price',
        label: '单价',
        width: 128,
        numeric: true,
        required: priceRequired,
        // 锁定/可编辑两种分支共用表头说明（锁定口径 + 录入口径按 docType 择一）。
        headerInfo: priceHint,
        cellBuilder: (context, row) => RequiredCellFrame(
          listenable: row.price,
          isEmpty: () =>
              priceRequired &&
              (row.price.text.trim().isEmpty ||
                  double.tryParse(row.price.text.trim()) == null),
          // 订单/出货：单价由货品主档或受信任来源单据带入、锁定不可改。
          // 复制订单行会清空冻结价；重新选择货品即可取得当前主档价。
          child:
              (docType == SalesDocType.order ||
                  docType == SalesDocType.shipment)
              ? _lockedCell(context, row.price)
              : TextField(
                  controller: row.price,
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const UtenInputDecoration(
                    InputDecoration(isDense: true, hintText: '0'),
                  ),
                ),
        ),
      ),
    // 订单折扣：紧跟单价；货品主档 zk 仅作为初始建议，销售可按订单调整。
    if (!freeCustomerShipment &&
        (docType == SalesDocType.order ||
            docType == SalesDocType.customerShipment))
      EditableGridColumn<SalesGridRow>(
        key: 'discount',
        label: '折扣',
        width: 128,
        numeric: true,
        required: true,
        // 表头 ⓘ 悬停说明折扣口径（2026-09-04 用户口径）；格内不再重复 ⓘ。
        headerInfo: l10n.workflowDiscountHint,
        cellBuilder: (context, row) => RequiredCellFrame(
          listenable: row.discount,
          isEmpty: () => !isValidSalesOrderDiscountText(row.discount.text),
          child: TextField(
            controller: row.discount,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const UtenInputDecoration(
              InputDecoration(isDense: true, hintText: '1=原价'),
            ),
          ),
        ),
      ),
    if (!freeCustomerShipment)
      EditableGridColumn<SalesGridRow>(
        key: 'amount',
        // 销售订单金额是所选订单币种的原币金额；销售端不展示人民币换算，
        // 也不要用“¥”让外币订单看起来像人民币。
        label: docType == SalesDocType.order
            ? '金额(订单币种)'
            : docType == SalesDocType.customerShipment
            ? '金额预览(所选币种)'
            : '金额',
        width: 110,
        numeric: true,
        cellBuilder: (context, row) => ValueListenableBuilder<double>(
          valueListenable: row.amountNotifier,
          builder: (_, v, _) => Text(
            docType == SalesDocType.order ||
                    docType == SalesDocType.customerShipment
                ? v.toStringAsFixed(2)
                : '¥${v.toStringAsFixed(2)}',
          ),
        ),
      ),
    // 报表补列（与 _save/_init 字段映射一致；按 docType 显隐）。
    // 出货单(shipment)只留 货品/颜色/单位/数量/单价/金额/备注：成本分项/折扣等补列不展示
    //（出货是发货履约，价格/折扣沿用订货单）。隐藏列的字段仍在行模型里，编辑既有出货单时
    // 回填并随保存回写，不丢数据。
    if (docType == SalesDocType.order || docType == SalesDocType.otherShipment)
      _extraNumericColumn('机加价', 'machiningPrice', (r) => r.machiningPrice),
    if (docType == SalesDocType.order || docType == SalesDocType.otherShipment)
      _extraNumericColumn('围数', 'circumference', (r) => r.circumference),
    if (docType == SalesDocType.order)
      _extraNumericColumn('进仓数量', 'inboundQty', (r) => r.inboundQty),
    if (docType == SalesDocType.otherShipment)
      _extraNumericColumn('材料价', 'materialPrice', (r) => r.materialPrice),
    if (docType == SalesDocType.otherShipment)
      _extraNumericColumn('压铸价', 'dieCastPrice', (r) => r.dieCastPrice),
    if (docType == SalesDocType.otherShipment ||
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
    // 行备注：5 类单据通用，固定放网格末列。随输入自动加宽（封顶 480 后格内滚动）。
    EditableGridColumn<SalesGridRow>(
      key: 'remark',
      label: '备注',
      width: 160,
      textOf: (r) => r.remark.text,
      listenableOf: (r) => r.remark,
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

/// 锁定单元格(订单/出货单价)：readOnly 保持正文字色，不用 enabled:false 的禁用浅灰；
/// 点击弹说明权威来源（格内 ⓘ 已上移表头，见 salesGridColumns 的 priceHint）。
/// 控制器值可用于客户端预览，但服务端不信任请求体中的单价/金额。
/// 锁定单价说明：表头 ⓘ 与只读格点按提示同一份口径（2026-09-11 去重，
/// 此前两处各硬编码一份易改漏；暂无 l10n key，待补 arb 后统一换成 l10n）。
const String _lockedPriceHint =
    '单价由货品资料或来源单据带入，并由服务端锁定，不可在订货单修改。'
    '复制的新行如单价为空，请重新选择货品取得当前价格';

Widget _lockedCell(BuildContext context, TextEditingController ctl) {
  final theme = Theme.of(context);
  return TextField(
    controller: ctl,
    readOnly: true,
    textAlign: TextAlign.right,
    style: TextStyle(color: theme.colorScheme.onSurface),
    decoration: const UtenInputDecoration(
      InputDecoration(isDense: true, hintText: '重新选货取价'),
    ),
    onTap: () => context.appInfo(_lockedPriceHint),
  );
}

/// 补列 numeric 列工厂：右对齐数字输入框（与数量/单价同款）。
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
          DropdownMenuItem(
            value: o,
            child: Text(o, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) => notifier.value = v,
    ),
  );
}
