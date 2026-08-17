// 销售单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 差异由 config 驱动（与采购 edit 页同形）：
//  - 客户/仓库/币种下拉按 has* 显隐；
//  - 业务员/发货人按 has* 显隐 UtenEmployeePicker；
//  - 有效期（报价）/交货日（订货）按 has* 显隐 UtenDateField（outlined，与其它字段同款）；
//  - 合同信息（订货）/发货信息（出货类）/出库类型（其它出货）按 has* 显隐；
//  - 「从上游引入」按 hasUpstreamLink 显隐（出货→订货，退货→出货）。
//  - 明细改 Excel 表：货品/颜色/单位/数量/单价→金额自动 + 报表补列 + 添加行/添加多行 + 行尾删除。
//
// 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// 保存组装 body 调 create/update，成功后跳详情。
// 路由用 SalesRoutePath 字面量（route_names.dart 由上层统一加 sales_*）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/repositories/client_repository.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../../basic_data/providers/master_dict_add.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_doc_link_picker.dart';
import '../../basic_data/models/goods_node.dart' show GoodsListItem;
import '../../basic_data/widgets/uten_client_picker.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../widgets/sales_grid_columns.dart';

class SalesDocEditPage extends ConsumerStatefulWidget {
  const SalesDocEditPage({super.key, required this.docType, this.id});
  final SalesDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<SalesDocEditPage> createState() => _SalesDocEditPageState();
}

class _SalesDocEditPageState extends ConsumerState<SalesDocEditPage> {
  SalesDocConfig get _cfg => SalesDocConfig.by(widget.docType);

  /// 订单：金额 = 数量 × 单价 × 折扣（折扣由货品主档带入、锁定）；其它单据仍 = 数量 × 单价。
  bool get _amountUsesDiscount => widget.docType == SalesDocType.order;
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _taxRate = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();

  // 合同信息（订货）
  final _contractNo = TextEditingController();
  final _linkPhone = TextEditingController();
  final _logisticsNo = TextEditingController();
  final _signAddr = TextEditingController();
  final _shipAddr = TextEditingController();
  final _deposit = TextEditingController();

  // 出货类发货信息
  final _shipLinkPhone = TextEditingController();
  final _parcelCount = TextEditingController();
  final _outType = TextEditingController();

  /// 退货原因（销售退货专属）。
  final _returnReason = TextEditingController();

  String? _clientId;
  String? _warehouseId;
  String? _currencyId;
  String? _settlementMethodId;

  // 人员字段（id + 给 picker 的 initial 项缓存）
  String? _sellerId;
  String? _senderId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  // 日期字段
  DateTime? _validUntil; // 报价有效期
  DateTime? _deliverDate; // 订货交货日
  // 默认不填，由销售自选 ALLOW_PARTIAL / REQUIRE_COMPLETE（customerConfirm 新单不再提供）。
  String? _shipmentPolicy;
  String? _warehouseWorkStatus;

  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

  final _grid = UtenEditableGridController<SalesGridRow>();
  final _scrollCtl = ScrollController();

  /// 网格底部「总数量」实时汇总（行增删/数量改动时刷新）。
  final _totalQtyNotifier = ValueNotifier<double>(0);
  bool _saving = false;
  bool _loading = true;
  String? _initializationError;

  /// 必填校验未通过的表头字段 key（client/warehouse/currency/deliverDate/items），
  /// 对应输入框描红；字段改值即时清除。
  final Set<String> _errors = {};

  /// 已挂「件数自动汇总」监听的数量控制器（随行增删同步挂载/卸除）。
  final Set<TextEditingController> _qtyListened = {};

  @override
  void initState() {
    super.initState();
    // 明细行增删 → 重新挂载数量监听并重算件数（行内数量改动走各行 qty 监听）。
    _grid.addListener(_onGridRowsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _grid.removeListener(_onGridRowsChanged);
    for (final c in _qtyListened) {
      c.removeListener(_recalcParcelCount);
      c.removeListener(_recalcQtyTotal);
    }
    _qtyListened.clear();
    _billNo.dispose();
    _remark.dispose();
    _returnReason.dispose();
    _rate.dispose();
    _taxRate.dispose();
    _contractNo.dispose();
    _linkPhone.dispose();
    _logisticsNo.dispose();
    _signAddr.dispose();
    _shipAddr.dispose();
    _deposit.dispose();
    _shipLinkPhone.dispose();
    _parcelCount.dispose();
    _outType.dispose();
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    _totalQtyNotifier.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _initializationError = null;
    });
    try {
      await ref.read(salesMasterNameServiceProvider).ensureLoaded();
      if (widget.id == null && _cfg.hasWarehouse) {
        // D1（王浩然）：新建出库单按「本人类型最近一张单的仓库」预填，减少手选。
        try {
          final last = await ref
              .read(salesRepositoryProvider(widget.docType))
              .list(size: 1);
          if (last.items.isNotEmpty && last.items.first.warehouseId != null) {
            _warehouseId = last.items.first.warehouseId;
          }
        } catch (_) {
          /* 预填失败静默，用户手选 */
        }
      }
      if (widget.id == null && (_cfg.hasSeller || _cfg.hasSender)) {
        // 业务员/发货人默认当前登录人（员工档案 id），界面上可改。
        final meId = ref.read(sessionProvider).user?.employeeId;
        if (meId != null && meId.isNotEmpty) {
          if (_cfg.hasSeller) _sellerId = meId;
          if (_cfg.hasSender) _senderId = meId;
          await _preloadEmployees([meId]);
        }
      }
      if (widget.id != null) {
        final d = await ref
            .read(salesRepositoryProvider(widget.docType))
            .detail(widget.id!);
        if (!mounted) return;
        if (!d.writable) {
          context.appInfo('该单据不在你的可写数据范围内，已切换为只读详情');
          context.replace(
            SalesRoutePath.docDetail(_cfg.type.pathSegment, widget.id!),
          );
          return;
        }
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds);
        await _preloadEmployees([d.sellerId, d.senderId]);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _clientId = d.clientId;
        _warehouseId = d.warehouseId;
        _currencyId = d.currencyId;
        _settlementMethodId = d.settlementMethodId;
        _rate.text = d.exchangeRate?.toString() ?? '1';
        _taxRate.text = d.taxRate?.toString() ?? '';
        _sellerId = d.sellerId;
        _senderId = d.senderId;
        _validUntil = _parseDate(d.validUntil);
        _deliverDate = _parseDate(d.deliverDate);
        if (widget.docType == SalesDocType.order) {
          _shipmentPolicy = d.shipmentPolicy;
        }
        if (widget.docType == SalesDocType.shipment) {
          _warehouseWorkStatus = d.warehouseWorkStatus;
        }
        _contractNo.text = d.contractNo ?? '';
        _linkPhone.text = d.linkPhone ?? '';
        _logisticsNo.text = d.logisticsNo ?? '';
        _signAddr.text = d.signAddr ?? '';
        _shipAddr.text = d.shipAddr ?? '';
        _deposit.text = d.deposit?.toString() ?? '';
        _shipLinkPhone.text = d.linkPhone ?? '';
        _parcelCount.text = d.parcelCount?.toString() ?? '';
        _outType.text = d.outType ?? '';
        _returnReason.text = d.returnReason ?? '';
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        final rows = <SalesGridRow>[];
        for (final it in d.items) {
          final row = SalesGridRow(amountUsesDiscount: _amountUsesDiscount)
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref
                        .read(salesMasterNameServiceProvider)
                        .goods(it.goodsId),
                  )
            ..orderItemId = it.orderItemId
            ..outItemId = it.outItemId
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..solution = it.solution
            ..responsible = it.responsible;
          row.qty.text = it.qty?.toString() ?? '';
          row.price.text = it.price?.toString() ?? '';
          // 补列回填（按 docType 仅填该单据类型对应字段；其余保持空）。
          if (it.machiningPrice != null) {
            row.machiningPrice.text = it.machiningPrice.toString();
          }
          if (it.circumference != null) {
            row.circumference.text = it.circumference.toString();
          }
          if (it.inboundQty != null) {
            row.inboundQty.text = it.inboundQty.toString();
          }
          if (it.materialPrice != null) {
            row.materialPrice.text = it.materialPrice.toString();
          }
          if (it.dieCastPrice != null) {
            row.dieCastPrice.text = it.dieCastPrice.toString();
          }
          if (it.discount != null) {
            row.discount.text = it.discount.toString();
          }
          row.remark.text = it.remark ?? '';
          rows.add(row);
        }
        if (_cfg.hasWarehouse) {
          await _fillStockPlaces(rows);
        }
        _grid.replaceAll(rows);
      }
      if (_grid.isEmpty) {
        _grid.addRow(SalesGridRow(amountUsesDiscount: _amountUsesDiscount));
      }
    } on ApiException catch (e) {
      _initializationError = e.message;
    } catch (_) {
      _initializationError = '无法读取完整单据数据，请检查网络或权限后重试';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  bool get _requiresLinkedSalesShipment =>
      widget.docType == SalesDocType.shipment &&
      salesShipmentRequiresOrderLinks(
        isNew: widget.id == null,
        warehouseWorkStatus: _warehouseWorkStatus,
      );

  /// 并发按 id 拉人员字段的名字（picker 的 initial 显示用）。失败静默。
  Future<void> _preloadEmployees(Iterable<String?> ids) async {
    final uniq = ids.whereType<String>().where((id) => id.isNotEmpty).toSet();
    if (uniq.isEmpty) return;
    final repo = ref.read(employeeRepositoryProvider);
    await Future.wait(
      uniq.map((id) async {
        try {
          final p = await repo.getById(id);
          _empCache[id] = UtenEmployeePickerItem(
            id: p.id,
            name: p.fullName ?? '',
            departmentName: p.departmentName,
          );
        } catch (_) {
          // 静默：picker 的 initial 为 null 时不显示名字，不阻塞流程。
        }
      }),
    );
  }

  /// 点货品：滑窗除未分类外全部分类都展示（含原材料，问题 #17），支持多选——
  /// 选中的第一个填当前行，其余各自追加一新行，一次选完不用逐个重复"加行→选货品"。
  Future<void> _pickGoods(SalesGridRow row) async {
    final picked = await showUtenGoodsPickerMulti(
      context,
      ref,
      scope: UtenGoodsPickerScope.allExceptUncategorized,
    );
    if (picked.isEmpty) return;
    void fill(SalesGridRow target, GoodsListItem g) {
      target
        ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
        // 颜色/单位直接回填货品主档 UUID，单元格只读显示。
        ..colorId = g.colorId
        ..unitId = g.unitId
        ..stockPlaceNotifier.value = g.stockPlace;
      // 订单/出货：单价由货品主档自动带入、锁定（出货亦可由来源订货单引入；金额=数量×单价）。
      if (widget.docType == SalesDocType.order ||
          widget.docType == SalesDocType.shipment) {
        if (g.price != null) target.price.text = g.price.toString();
      }
      // 订单折扣：货品 zk 倍率（1=原价；空/0→1）自动带入、锁定。
      if (widget.docType == SalesDocType.order) {
        final disc = (g.discount == null || g.discount == 0) ? 1.0 : g.discount;
        target.discount.text = disc.toString();
      }
    }

    fill(row, picked.first);
    if (picked.length > 1) {
      final extraRows = <SalesGridRow>[];
      for (final g in picked.skip(1)) {
        final r = SalesGridRow(amountUsesDiscount: _amountUsesDiscount);
        fill(r, g);
        extraRows.add(r);
      }
      _grid.addRows(extraRows);
    }
    // 货品选定后该行数量才计入件数（先填数量后选货品的情形）。
    _recalcParcelCount();
  }

  /// 实物出入库单据（出货/其它出货/退货）：按货品主档补全各行库位号（拣货/上架指引）。
  Future<void> _fillStockPlaces(Iterable<SalesGridRow> rows) async {
    final pending = rows
        .map((r) => r.goods?.id)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    if (pending.isEmpty) return;
    await ref.read(salesMasterNameServiceProvider).loadGoodsDetails(pending);
    if (!mounted) return;
    for (final r in rows) {
      final id = r.goods?.id;
      if (id != null && id.isNotEmpty) {
        r.stockPlaceNotifier.value =
            ref.read(salesMasterNameServiceProvider).goodsInfo(id)?.stockPlace;
      }
    }
  }

  /// 「从上游引入」：弹选择器，把所选 SalesLinkedItem 映射成行追加。
  /// 表头已选客户 → 面板锁定该客户；表头未选 → 引入后以上游单据客户回填。
  Future<void> _importFromUpstream() async {
    final result = await showSalesDocLinkPicker(
      context,
      ref,
      _cfg,
      initialClientId: _clientId,
    );
    if (!mounted) return;
    if (result == null || result.items.isEmpty) return;
    if (_clientId != null && result.clientId != _clientId) {
      context.appError('上游单据客户与表头客户不一致，已阻止引入');
      return;
    }
    final goodsIds = result.items
        .map((e) => e.goodsId)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    final rows = <SalesGridRow>[];
    for (final li in result.items) {
      if (li.goodsId.isEmpty) continue;
      final goods = GoodsOption(
        id: li.goodsId,
        name: ref.read(salesMasterNameServiceProvider).goods(li.goodsId),
      );
      rows.add(
        SalesGridRow.fromLinked(
          li,
          goods,
          amountUsesDiscount: _amountUsesDiscount,
        ),
      );
    }
    if (_cfg.hasWarehouse) {
      await _fillStockPlaces(rows);
    }
    // 引入前清掉占位空白行（新建态预填的无货品空行），直接显示引入项，不留顶部空行。
    _grid.removeWhere(
      (r) =>
          r.goods == null &&
          r.qty.text.trim().isEmpty &&
          r.price.text.trim().isEmpty &&
          r.remark.text.trim().isEmpty,
    );
    _grid.addRows(rows);
    // 表头未选客户 → 以上游单据客户回填，并联动收货地址/联系电话。
    final cid = result.clientId;
    if (_clientId == null && cid != null && cid.isNotEmpty) {
      await _onClientChanged(cid);
    }
  }

  /// 表头客户变更（手动选择或上游引入回填）：查客户主档，把收货地址/联系电话
  /// 带出来（订货合同信息 / 出货类发货信息字段；带不出则清空，均可继续手改）。
  Future<void> _onClientChanged(String? id) async {
    setState(() => _clientId = id);
    _clearError('client');
    if (id == null || id.isEmpty) return;
    if (!(_cfg.hasShipInfo || _cfg.hasContractInfo)) return;
    try {
      final c = await ref.read(clientRepositoryProvider).detail(id);
      // 竞态守卫：await 期间用户又改了客户 → 丢弃本次结果。
      if (!mounted || _clientId != id) return;
      // 收货地址优先主档「收货地址」，无则取「地址」；电话依次 电话→手机→备用电话。
      String firstOf(Iterable<String?> vs) => vs
          .map((e) => e?.trim() ?? '')
          .firstWhere((e) => e.isNotEmpty, orElse: () => '');
      final addr = firstOf([c.shipAddress, c.address]);
      final phone = firstOf([c.phone, c.mobile, c.phone2]);
      setState(() {
        _shipAddr.text = addr; // 订货合同信息 / 出货类发货信息共用该控制器
        if (_cfg.hasShipInfo) _shipLinkPhone.text = phone;
        if (_cfg.hasContractInfo) _linkPhone.text = phone;
      });
    } catch (_) {
      // 查询失败静默：不阻塞开单，地址/电话可手填。
    }
  }

  /// Rebind quantity listeners and recalculate parcel totals after row changes.
  void _onGridRowsChanged() {
    final current = _grid.rows.map((r) => r.qty).toSet();
    for (final c in _qtyListened.difference(current)) {
      c.removeListener(_recalcParcelCount);
      c.removeListener(_recalcQtyTotal);
    }
    for (final c in current.difference(_qtyListened)) {
      c.addListener(_recalcParcelCount);
      c.addListener(_recalcQtyTotal);
    }
    _qtyListened
      ..clear()
      ..addAll(current);
    _recalcParcelCount();
    _recalcQtyTotal();
  }

  /// 件数 = 明细各行（已选货品）数量之和，四舍五入取整；无有效行返回 null。
  int? _computedParcelCount() {
    var sum = 0.0;
    var has = false;
    for (final r in _grid.rows) {
      if (r.goods == null) continue;
      has = true;
      sum += double.tryParse(r.qty.text.trim()) ?? 0;
    }
    return has ? sum.round() : null;
  }

  /// 件数自动汇总（仅出货类 hasShipInfo 单据）：数量改动/行增删时刷新只读框。
  void _recalcParcelCount() {
    if (!_cfg.hasShipInfo) return;
    final n = _computedParcelCount();
    final text = n == null ? '' : n.toString();
    if (_parcelCount.text != text) _parcelCount.text = text;
  }

  /// 网格底部「总数量」= 各行数量之和（行增删/数量改动时实时刷新 footer）。
  void _recalcQtyTotal() {
    var sum = 0.0;
    for (final r in _grid.rows) {
      sum += double.tryParse(r.qty.text.trim()) ?? 0;
    }
    _totalQtyNotifier.value = sum;
  }

  /// 必填校验：返回第一条错误文案；并把未填的表头字段记入 [_errors]（红框）、
  /// 不合格明细行打红标。通过则返回 null（并清除旧标记）。
  String? _validate() {
    final errs = <String>{};
    String? first;
    void fail(String key, String msg) {
      errs.add(key);
      first ??= msg;
    }

    if (_cfg.clientRequired && _clientId == null) fail('client', '请选择客户');
    if (_cfg.sellerRequired && _sellerId == null) fail('seller', '请选择业务员');
    if (_cfg.hasWarehouse && _warehouseId == null) fail('warehouse', '请选择仓库');
    if (_cfg.hasCurrency && _currencyId == null) fail('currency', '请选择币种');
    if (_cfg.hasDeliverDate && _deliverDate == null) {
      fail('deliverDate', '请选择交货日期');
    }
    final allRows = _grid.rows;
    final rows = allRows.where((r) => r.goods != null).toList();
    // 填了内容但没选货品的行：不能静默丢弃，拦下提示（货品格描红）。
    var noGoodsRow = 0;
    for (var i = 0; i < allRows.length; i++) {
      final r = allRows[i];
      if (r.goods != null) continue;
      final touched =
          r.qty.text.trim().isNotEmpty ||
          r.price.text.trim().isNotEmpty ||
          r.remark.text.trim().isNotEmpty;
      if (touched) {
        r.invalidNotifier.value = true;
        noGoodsRow = noGoodsRow == 0 ? i + 1 : noGoodsRow;
      }
    }
    if (noGoodsRow > 0) {
      fail('items', '第 $noGoodsRow 行明细：请选择货品');
    } else if (rows.isEmpty) {
      fail('items', '请至少添加一条明细（选择货品）');
    } else {
      final priceRequired = widget.docType != SalesDocType.otherShipment;
      var badRow = 0;
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final qtyOk = (double.tryParse(r.qty.text.trim()) ?? 0) > 0;
        final priceOk =
            !priceRequired ||
            (r.price.text.trim().isNotEmpty &&
                double.tryParse(r.price.text.trim()) != null);
        if (!qtyOk || !priceOk) {
          r.invalidNotifier.value = true;
          badRow = badRow == 0 ? i + 1 : badRow;
        }
      }
      if (badRow > 0) {
        fail('items', '第 $badRow 行明细：数量须大于 0${priceRequired ? '，单价必填' : ''}');
      }
    }
    if (_requiresLinkedSalesShipment && rows.isNotEmpty) {
      final firstUnlinked = salesShipmentFirstUnlinkedLine(
        rows.map((row) => row.orderItemId),
      );
      if (firstUnlinked > 0) {
        for (final row in rows.where(
          (row) => row.orderItemId == null || row.orderItemId!.isEmpty,
        )) {
          row.invalidNotifier.value = true;
        }
        fail('items', '销售出货必须从订货单引入，零星无订单出库请用其它出货');
      }
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(errs);
    });
    return first;
  }

  /// 字段修改后即时清除对应红框。
  void _clearError(String key) {
    if (_errors.contains(key)) setState(() => _errors.remove(key));
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      context.appError(err);
      return;
    }
    final rows = _grid.rows;
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text) ?? 0;
      final price = double.tryParse(r.price.text);
      // 补列：按 docType 序列化对应字段（空文本不传，后端按 nullable 处理）。
      double? parseExtra(TextEditingController c) {
        final t = c.text.trim();
        return t.isEmpty ? null : double.tryParse(t);
      }

      final body = <String, dynamic>{
        'goodsId': r.goods!.id,
        'qty': qty,
        if (price case final price?) ...{
          'price': price,
          'amountOriginal': r.amountNotifier.value,
          // 销售订单只提交所选币种的原币金额；销售请求不得夹带伪本币事实。
          if (widget.docType != SalesDocType.order) 'amountLocal': qty * price,
        },
        if (r.orderItemId != null) 'orderItemId': r.orderItemId,
        if (r.outItemId != null) 'outItemId': r.outItemId,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        // 行备注：5 类单据通用（空文本不传，后端按 null 处理）。
        if (r.remark.text.trim().isNotEmpty) 'remark': r.remark.text.trim(),
      };
      switch (widget.docType) {
        case SalesDocType.order:
          final mp = parseExtra(r.machiningPrice);
          final circ = parseExtra(r.circumference);
          final inb = parseExtra(r.inboundQty);
          final disc = parseExtra(r.discount);
          if (mp != null) body['machiningPrice'] = mp;
          if (circ != null) body['circumference'] = circ;
          if (inb != null) body['inboundQty'] = inb;
          if (disc != null) body['discount'] = disc;
          break;
        case SalesDocType.shipment:
        case SalesDocType.otherShipment:
          final mat = parseExtra(r.materialPrice);
          final dc = parseExtra(r.dieCastPrice);
          final jp = parseExtra(r.machiningPrice);
          final circ = parseExtra(r.circumference);
          final disc = parseExtra(r.discount);
          if (mat != null) body['materialPrice'] = mat;
          if (dc != null) body['dieCastPrice'] = dc;
          if (jp != null) body['machiningPrice'] = jp;
          if (circ != null) body['circumference'] = circ;
          if (disc != null) body['discount'] = disc;
          break;
        case SalesDocType.returnDoc:
          final disc = parseExtra(r.discount);
          if (disc != null) body['discount'] = disc;
          if (r.solution != null) body['solution'] = r.solution;
          if (r.responsible != null) body['responsible'] = r.responsible;
          break;
        case SalesDocType.quote:
          break;
      }
      itemsBody.add(body);
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      if (_clientId != null) 'clientId': _clientId,
      if (_cfg.hasWarehouse && _warehouseId != null)
        'warehouseId': _warehouseId,
      if (_cfg.hasCurrency && _currencyId != null) 'currencyId': _currencyId,
      if (_cfg.hasCurrency && _cfg.hasExchangeRate)
        'exchangeRate': double.tryParse(_rate.text) ?? 1,
      if (_cfg.hasCurrency && _taxRate.text.isNotEmpty)
        'taxRate': double.tryParse(_taxRate.text),
      if (widget.docType != SalesDocType.quote && _settlementMethodId != null)
        'settlementMethodId': _settlementMethodId,
      if (_cfg.hasSeller && _sellerId != null) 'sellerId': _sellerId,
      if (_cfg.hasSender && _senderId != null) 'senderId': _senderId,
      if (_cfg.hasValidUntil && _validUntil != null)
        'validUntil': _fmt(_validUntil!),
      if (_cfg.hasDeliverDate && _deliverDate != null)
        'deliverDate': _fmt(_deliverDate!),
      if (widget.docType == SalesDocType.order &&
          _shipmentPolicy != null &&
          SalesShipmentPolicy.selectable.contains(_shipmentPolicy))
        'shipmentPolicy': _shipmentPolicy,
      if (_cfg.hasContractInfo) ...{
        if (_contractNo.text.trim().isNotEmpty)
          'contractNo': _contractNo.text.trim(),
        if (_linkPhone.text.trim().isNotEmpty)
          'linkPhone': _linkPhone.text.trim(),
        if (_signAddr.text.trim().isNotEmpty) 'signAddr': _signAddr.text.trim(),
        if (_shipAddr.text.trim().isNotEmpty) 'shipAddr': _shipAddr.text.trim(),
        if (_deposit.text.trim().isNotEmpty)
          'deposit': double.tryParse(_deposit.text.trim()),
      },
      if (_cfg.hasShipInfo) ...{
        if (_shipAddr.text.trim().isNotEmpty) 'shipAddr': _shipAddr.text.trim(),
        if (_shipLinkPhone.text.trim().isNotEmpty)
          'linkPhone': _shipLinkPhone.text.trim(),
        // 物流/快递单号：一张出货单一个；订单详情聚合展示全部出货单的单号。
        if (_logisticsNo.text.trim().isNotEmpty)
          'logisticsNo': _logisticsNo.text.trim(),
        // 件数由明细数量自动汇总（不依赖只读框文本）。
        if (_computedParcelCount() != null)
          'parcelCount': _computedParcelCount(),
      },
      if (_cfg.hasOutType && _outType.text.trim().isNotEmpty)
        'outType': _outType.text.trim(),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      if (widget.docType == SalesDocType.returnDoc &&
          _returnReason.text.trim().isNotEmpty)
        'returnReason': _returnReason.text.trim(),
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(salesRepositoryProvider(widget.docType));
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      bumpListRefresh(ref, _cfg.refreshKey);
      context.replace(SalesRoutePath.docDetail(_cfg.type.pathSegment, d.id));
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _totalText(
    SalesMasterNameService names, {
    required String prefix,
    required double value,
  }) {
    if (widget.docType != SalesDocType.order) {
      return '$prefix ¥${value.toStringAsFixed(2)}';
    }
    final resolved = names.currency(_currencyId);
    final currency = resolved == '—' ? '订单币种' : resolved;
    return '$prefix（$currency） ${value.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    final List<ReferenceMethodOption> settlementMethods =
        ref.watch(settlementMethodOptionsProvider).valueOrNull ??
        const <ReferenceMethodOption>[];
    final settlementEntries = <String, String>{
      for (final item in settlementMethods)
        item.id: '${item.name}（${item.code}）',
    };
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: SalesRoutePath.hub),
        ),
        actions:
            !_loading && _initializationError == null && _cfg.skipListOnCreate
            ? [
                UtenButton(
                  type: UtenButtonType.tonal,
                  icon: Icons.history_rounded,
                  onPressed: () =>
                      context.push('/sales/${_cfg.type.pathSegment}'),
                  child: const Text('查看历史'),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _initializationError != null
            ? UtenEmpty.error(
                key: const ValueKey('sales-doc-edit-load-error'),
                message: '${_cfg.label}加载失败',
                description:
                    '${_initializationError!}\n当前未加载任何可编辑数据。请重试，或使用左上角返回按钮退出编辑。',
                actionLabel: '重试',
                onAction: _init,
              )
            : UtenContentContainer(
                child: Scrollbar(
                  controller: _scrollCtl,
                  thumbVisibility: true,
                  child: ListView(
                    controller: _scrollCtl,
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(UtenSpacing.s12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              UtenFormGrid(
                                children: [
                                  // 单据号：系统自动生成，只读显示。
                                  TextFormField(
                                    readOnly: true,
                                    controller: _billNo,
                                    decoration: InputDecoration(
                                      labelText: '单据号',
                                      hintText: _billNo.text.isEmpty
                                          ? '保存后自动生成'
                                          : null,
                                      filled: _billNo.text.isEmpty,
                                      suffixIcon: _billNo.text.isEmpty
                                          ? const Icon(
                                              Icons.autorenew_outlined,
                                              size: 18,
                                            )
                                          : const Icon(
                                              Icons.lock_outline,
                                              size: 16,
                                            ),
                                    ),
                                  ),
                                  // 制单员/制单时间：服务端权威，只读展示（责任制）。
                                  ...utenMakerAuditCells(
                                    ref,
                                    makerName: _makerName,
                                    createdAt: _createdAt,
                                  ),
                                  UtenDateField(
                                    label: '单据日期',
                                    required: true,
                                    value: _billDate,
                                    onChanged: (d) =>
                                        setState(() => _billDate = d),
                                  ),
                                  ClientPickerField(
                                    initialId: _clientId,
                                    initialName: names.client(_clientId),
                                    required: _cfg.clientRequired,
                                    errorText: _errors.contains('client')
                                        ? '请选择客户'
                                        : null,
                                    // 选客户后联动带出主档收货地址/联系电话。
                                    onChanged: (v) => _onClientChanged(v),
                                    onPick: () =>
                                        showUtenClientPicker(context, ref),
                                  ),
                                  if (_cfg.hasWarehouse)
                                    _dropdown(
                                      '仓库',
                                      _warehouseId,
                                      names.warehouseEntries,
                                      (v) {
                                        setState(() => _warehouseId = v);
                                        _clearError('warehouse');
                                      },
                                      required: true,
                                      errorText: _errors.contains('warehouse')
                                          ? '请选择仓库'
                                          : null,
                                    ),
                                  if (_cfg.hasCurrency) ...[
                                    _dropdown(
                                      '币种',
                                      _currencyId,
                                      names.currencyEntries,
                                      (v) {
                                        setState(() => _currencyId = v);
                                        _clearError('currency');
                                      },
                                      required: true,
                                      errorText: _errors.contains('currency')
                                          ? '请选择币种'
                                          : null,
                                      // 列表没有的币种可内联新增（currency:edit），
                                      // 新建后字典重载并自动选中新值。
                                      addNewLabel: '添加币种',
                                      onAddNew: _canAddCurrency
                                          ? () async {
                                              final id =
                                                  await showCurrencyAddSheet(
                                                    context,
                                                    ref,
                                                    names,
                                                  );
                                              if (id == null || !mounted) return;
                                              setState(() => _currencyId = id);
                                              _clearError('currency');
                                            }
                                          : null,
                                    ),
                                    if (_cfg.hasExchangeRate)
                                      TextField(
                                        controller: _rate,
                                        keyboardType:
                                            const TextInputType.numberWithOptions(
                                              decimal: true,
                                            ),
                                        decoration: const InputDecoration(
                                          labelText: '汇率',
                                        ),
                                      ),
                                    TextField(
                                      controller: _taxRate,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      decoration: const InputDecoration(
                                        labelText: '税率(%)',
                                      ),
                                    ),
                                  ],
                                  if (widget.docType != SalesDocType.quote)
                                    _dropdown(
                                      '结帐方式',
                                      _settlementMethodId,
                                      settlementEntries,
                                      (value) => setState(
                                        () => _settlementMethodId = value,
                                      ),
                                      // 列表没有的结账方式可内联新增（payment_style:edit）。
                                      addNewLabel: '添加结账方式',
                                      onAddNew: _canAddSettlement
                                          ? () async {
                                              final id =
                                                  await showSettlementAddSheet(
                                                    context,
                                                    ref,
                                                  );
                                              if (id == null || !mounted) return;
                                              setState(
                                                () => _settlementMethodId = id,
                                              );
                                            }
                                          : null,
                                    ),
                                  // 人员字段（按 config 显隐）
                                  if (_cfg.hasSeller)
                                    _employeePicker(
                                      label: '业务员',
                                      currentId: _sellerId,
                                      defaultDeptCode: kDeptCodeMarketing,
                                      required: _cfg.sellerRequired,
                                      onChanged: (id) =>
                                          setState(() => _sellerId = id),
                                    ),
                                  if (_cfg.hasSender)
                                    _employeePicker(
                                      label: '发货人',
                                      currentId: _senderId,
                                      onChanged: (id) =>
                                          setState(() => _senderId = id),
                                    ),
                                  // 日期字段（按 config 显隐，统一 UtenDateField）
                                  if (_cfg.hasValidUntil)
                                    UtenDateField(
                                      label: '有效期',
                                      value: _validUntil,
                                      onChanged: (d) =>
                                          setState(() => _validUntil = d),
                                    ),
                                  if (_cfg.hasDeliverDate)
                                    UtenDateField(
                                      label: '交货日期',
                                      required: true,
                                      value: _deliverDate,
                                      errorText: _errors.contains('deliverDate')
                                          ? '请选择交货日期'
                                          : null,
                                      onChanged: (d) {
                                        setState(() => _deliverDate = d);
                                        _clearError('deliverDate');
                                      },
                                    ),
                                  if (widget.docType == SalesDocType.order)
                                    _shipmentPolicyField(),
                                  if (_cfg.hasContractInfo) ...[
                                    TextField(
                                      controller: _contractNo,
                                      decoration: const InputDecoration(
                                        labelText: '合同号',
                                      ),
                                    ),
                                    TextField(
                                      controller: _linkPhone,
                                      decoration: const InputDecoration(
                                        labelText: '联系电话',
                                      ),
                                    ),
                                    TextField(
                                      controller: _signAddr,
                                      decoration: const InputDecoration(
                                        labelText: '签约地点',
                                      ),
                                    ),
                                    TextField(
                                      controller: _shipAddr,
                                      decoration: const InputDecoration(
                                        labelText: '收货地址',
                                      ),
                                    ),
                                    TextField(
                                      controller: _deposit,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      decoration: const InputDecoration(
                                        labelText: '订金',
                                      ),
                                    ),
                                  ],
                                  if (_cfg.hasShipInfo) ...[
                                    TextField(
                                      controller: _shipAddr,
                                      decoration: const InputDecoration(
                                        labelText: '收货地址',
                                      ),
                                    ),
                                    TextField(
                                      controller: _shipLinkPhone,
                                      decoration: const InputDecoration(
                                        labelText: '联系电话',
                                      ),
                                    ),
                                    TextField(
                                      controller: _logisticsNo,
                                      decoration: const InputDecoration(
                                        labelText: '物流单号（发货后可填）',
                                      ),
                                    ),
                                    // 件数：按明细数量自动汇总，只读（保存时同样按明细重算）。
                                    TextField(
                                      controller: _parcelCount,
                                      readOnly: true,
                                      decoration: const InputDecoration(
                                        labelText: '件数',
                                        hintText: '按明细数量自动汇总',
                                        filled: true,
                                        suffixIcon: Icon(
                                          Icons.calculate_outlined,
                                          size: 16,
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (_cfg.hasOutType)
                                    TextField(
                                      controller: _outType,
                                      decoration: const InputDecoration(
                                        labelText: '出库类型',
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                              if (widget.docType == SalesDocType.returnDoc) ...[
                                TextField(
                                  controller: _returnReason,
                                  decoration: const InputDecoration(
                                    labelText: '退货原因',
                                  ),
                                  maxLines: 2,
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                              ],
                              TextField(
                                controller: _remark,
                                decoration: const InputDecoration(
                                  labelText: '备注',
                                ),
                                maxLines: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      Row(
                        children: [
                          Text(
                            '明细 (${_grid.length})',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          if (_cfg.hasUpstreamLink)
                            UtenImportButton(
                              label: '从上游引入',
                              onPressed: _importFromUpstream,
                            ),
                        ],
                      ),
                      if (_requiresLinkedSalesShipment)
                        Container(
                          key: const ValueKey(
                            'sales-shipment-order-link-guidance',
                          ),
                          margin: const EdgeInsets.only(
                            top: UtenSpacing.s8,
                            bottom: UtenSpacing.s4,
                          ),
                          padding: const EdgeInsets.all(UtenSpacing.s8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.link_outlined,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: UtenSpacing.s8),
                              const Expanded(
                                child: Text('销售出货必须从订货单引入；零星无订单出库请使用“其它出货”。'),
                              ),
                            ],
                          ),
                        ),
                      UtenEditableGrid<SalesGridRow>(
                        controller: _grid,
                        columns: salesGridColumns(
                          onPickGoods: _pickGoods,
                          docType: widget.docType,
                          colorEntries: names.colorEntries,
                          unitEntries: names.unitEntries,
                        ),
                        createBlankRow: () => SalesGridRow(
                          amountUsesDiscount: _amountUsesDiscount,
                        ),
                        cloneRow: (r) => r.clone(),
                        // 网格底部「添加行」上方：总数量 + 总金额（右对齐实时汇总）。
                        footer: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            ValueListenableBuilder<double>(
                              valueListenable: _totalQtyNotifier,
                              builder: (_, q, _) =>
                                  Text('总数量 ${q.toStringAsFixed(2)}'),
                            ),
                            const SizedBox(width: UtenSpacing.s16),
                            ValueListenableBuilder<double>(
                              valueListenable: _grid.totalListenable,
                              builder: (_, t, _) => Text(
                                _totalText(names, prefix: '总金额', value: t),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: _loading || _initializationError != null
          ? null
          : SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ValueListenableBuilder<double>(
                      valueListenable: _grid.totalListenable,
                      builder: (_, total, _) => Text(
                        _totalText(names, prefix: '合计', value: total),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s16),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: () =>
                          popOrBackTo(context, defaultPath: SalesRoutePath.hub),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    UtenButton(
                      isLoading: _saving,
                      icon: Icons.save_outlined,
                      onPressed: _saving ? null : _save,
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _shipmentPolicyField() {
    final value = _shipmentPolicy;
    // 可编辑：未选择(null) 或 当前值仍是新单可选策略。历史 CUSTOMER_CONFIRM/LEGACY 只读保留。
    final editable =
        value == null || SalesShipmentPolicy.selectable.contains(value);
    return Column(
      key: const ValueKey('sales-order-shipment-policy-field'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (editable)
          UtenDropdownField(
            key: const ValueKey('sales-order-shipment-policy'),
            label: '发运策略',
            value: value,
            items: [
              for (final policy in SalesShipmentPolicy.selectable)
                UtenDropdownItem(
                  value: policy,
                  label: salesShipmentPolicyLabel(policy),
                ),
            ],
            allowClear: false,
            searchable: false,
            onChanged: (next) {
              if (next == null) return;
              setState(() => _shipmentPolicy = next);
            },
          )
        else
          InputDecorator(
            key: const ValueKey('sales-order-shipment-policy-readonly'),
            decoration: const InputDecoration(
              labelText: '发运策略',
              filled: true,
              suffixIcon: Icon(Icons.lock_outline, size: 18),
            ),
            child: Text(salesShipmentPolicyLabel(value)),
          ),
      ],
    );
  }

  /// 人员选择器：关键字为空且指定 [defaultDeptCode] 时收敛到该部门子树、否则全公司搜。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
    String? defaultDeptCode,
    bool required = false,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
      required: required,
      hint: '请选择$label',
      sheetTitle: '选择$label',
      initial: currentId == null ? null : _empCache[currentId],
      loader: (kw) async {
        final deptId = (kw == null || kw.isEmpty) && defaultDeptCode != null
            ? (ref.read(departmentCodeIdMapProvider).valueOrNull ??
                  const {})[defaultDeptCode]
            : null;
        final res = await ref
            .read(employeeRepositoryProvider)
            .list(
              size: 30,
              search: kw,
              departmentId: deptId,
              includeSubtree: true,
            );
        return [
          for (final e in res.items)
            UtenEmployeePickerItem(
              id: e.id,
              name: e.fullName,
              departmentName: e.departmentName,
            ),
        ];
      },
      onChanged: (item) {
        if (item != null) _empCache[item.id] = item;
        onChanged(item?.id);
      },
    );
  }

  /// 币种/结账方式内联新增按钮可见性（后端 @PreAuthorize 仍是最终授权边界）。
  bool get _canAddCurrency =>
      ref.watch(currentPermissionsProvider).contains(Perm.currencyEdit);
  bool get _canAddSettlement =>
      ref.watch(currentPermissionsProvider).contains(Perm.paymentStyleEdit);

  Widget _dropdown(
    String label,
    String? value,
    Map<String, String> entries,
    ValueChanged<String?> onChanged, {
    bool required = false,
    String? errorText,
    Future<void> Function()? onAddNew,
    String? addNewLabel,
  }) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
      errorText: errorText,
      searchable: true, // 客户/仓库/币种等主档下拉一律支持搜索
      items: [
        for (final e in entries.entries)
          UtenDropdownItem(value: e.key, label: e.value),
        if (value != null && value.isNotEmpty && !entries.containsKey(value))
          UtenDropdownItem(value: value, label: value),
      ],
      onChanged: onChanged,
      onAddNew: onAddNew,
      addNewLabel: addNewLabel,
    );
  }
}
