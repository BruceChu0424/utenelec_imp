// 委外单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 差异由 SubcontractDocConfig 驱动：
//  - 委外商(supplier)/仓库/币种+汇率/税率 下拉按 has* / *Required 显隐；
//  - 人员（采购员/交货人/经办人）按 hasPurchaser/hasSender/hasWorker 显隐 UtenEmployeePicker；
//  - 日期（单据/交货/最后交货）统一用 UtenDateField（outlined，与其它字段同款）；
//  - 材料退的 bStyle(int)、损耗的 totalWeight、进仓/退货的 settlementStyle 按 has* 显隐；
//  - 「从上游引入」按 hasUpstreamLink 显隐（订货→申请；进仓→订货；退货→进仓/订货；
//    发料→订货；材料退→发料/订货；损耗→发料）。
//  - 明细改 Excel 表（UtenEditableGrid）：货品/数量/(单价?)/(金额?)/(重量?)/(围数?)/(胶箱数?)/
//    (损耗 4 列) 按 cfg.itemHas* 显隐；添加行/添加多行 + 行尾删除 + sticky 表头。
//    发料/材料退的 parent 父件字段本期不维护（可选，留空）。
//
// 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// 保存组装 body 调 create/update，成功后跳详情。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/providers/master_name_provider.dart' show GoodsOption;
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';
import '../repositories/subcontract_repository.dart';
import '../services/subcontract_save_workflow.dart';
import '../widgets/subcontract_grid_columns.dart';
import '../widgets/subcontract_link_picker.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;

class SubcontractDocEditPage extends ConsumerStatefulWidget {
  const SubcontractDocEditPage({
    super.key,
    required this.docType,
    this.id,
    this.applicationItemIds = const [],
    this.receiptPrefill,
  });
  final SubcontractDocType docType;
  final String? id; // null=新建
  final List<String> applicationItemIds;
  final ProcurementReceiptPrefill? receiptPrefill;

  @override
  ConsumerState<SubcontractDocEditPage> createState() =>
      _SubcontractDocEditPageState();
}

class _SubcontractDocEditPageState
    extends ConsumerState<SubcontractDocEditPage> {
  SubcontractDocConfig get _cfg => SubcontractDocConfig.by(widget.docType);
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _taxRate = TextEditingController();
  final _bStyle = TextEditingController();
  final _totalWeight = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();

  // 结帐方式（进仓/退货；B_PStyle 字典码）
  int? _settlementStyle;
  String? _settlementMethodId;

  String? _supplierId;
  String? _warehouseId;
  String? _currencyId;

  // 人员字段
  String? _purchaserId;
  String? _senderId;
  String? _workerId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  // 日期
  DateTime? _deliverDate;
  DateTime? _lastDate;

  final _grid = UtenEditableGridController<SubcontractGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loading = false;
  bool _orderSourceReady = true;
  String? _sourceApplicationBillNo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _billNo.dispose();
    _remark.dispose();
    _rate.dispose();
    _taxRate.dispose();
    _bStyle.dispose();
    _totalWeight.dispose();
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(mn.masterNameServiceProvider).ensureLoaded();
    if (widget.id == null) {
      // 仓库预填「本类型最近一张单的仓库」（与销售 D1 同款），减少手选。
      // 订货单不涉及仓库（成品入库仓库到进仓登记时再选），跳过预填。
      if (_cfg.hasWarehouse) {
        try {
          final last = await ref
              .read(subcontractRepositoryProvider(widget.docType))
              .list(size: 1);
          if (last.items.isNotEmpty && last.items.first.warehouseId != null) {
            _warehouseId = last.items.first.warehouseId;
          }
        } catch (_) {
          /* 预填失败静默，用户手选 */
        }
      }
      // 采购员/经办人默认当前登录人（交货人是委外商侧人员，不预填）。
      final meId = ref.read(sessionProvider).user?.employeeId;
      if (meId != null && meId.isNotEmpty) {
        if (_cfg.hasPurchaser) _purchaserId = meId;
        if (_cfg.hasWorker) _workerId = meId;
        await _preloadEmployees([meId]);
      }
      // 币种默认人民币（订货/进仓/退货等有币种的单据）。
      _prefillDefaultCurrency();
    }
    if (widget.id == null && widget.docType == SubcontractDocType.receipt) {
      _prefillReceiptFromExpectation();
    }
    if (widget.id == null && widget.docType == SubcontractDocType.order) {
      await _prefillFromApplication();
    }
    if (widget.id != null) {
      try {
        final d = await ref
            .read(subcontractRepositoryProvider(widget.docType))
            .detail(widget.id!);
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
        await _preloadEmployees([d.purchaserId, d.senderId, d.workerId]);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _supplierId = d.supplierId;
        _warehouseId = d.warehouseId;
        _currencyId = d.currencyId;
        _rate.text = d.exchangeRate?.toString() ?? '1';
        if (d.taxRate != null) _taxRate.text = d.taxRate.toString();
        if (d.bStyle != null) _bStyle.text = d.bStyle.toString();
        if (d.totalWeight != null) _totalWeight.text = d.totalWeight.toString();
        _settlementStyle = d.settlementStyleLegacy;
        _settlementMethodId = d.settlementMethodId;
        _purchaserId = d.purchaserId;
        _senderId = d.senderId;
        _workerId = d.workerId;
        _deliverDate = _parseDate(d.deliverDate);
        _lastDate = _parseDate(d.lastDate);
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        final rows = <SubcontractGridRow>[];
        for (final it in d.items) {
          final upstreamItemId =
              it.receiptItemId ??
              it.materialIssueItemId ??
              it.orderItemId ??
              it.applicationItemId;
          final row = SubcontractGridRow(sourceLocked: upstreamItemId != null)
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref
                        .read(mn.masterNameServiceProvider)
                        .goods(it.goodsId),
                  )
            ..qty.text = it.qty?.toString() ?? ''
            ..price.text = it.price?.toString() ?? ''
            ..weight.text = it.weight?.toString() ?? ''
            ..upstreamItemId = upstreamItemId
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..unitRate = it.unitRate
            ..sourceDocNo = it.sourceDocNo;
          row.endingQty.text = it.endingQty?.toString() ?? '';
          row.standardQty.text = it.standardQty?.toString() ?? '';
          row.wasteRate.text = it.wasteRate?.toString() ?? '';
          row.cause.text = it.cause ?? '';
          row.girth.text = it.girthQty?.toString() ?? '';
          row.boxQty.text = it.boxQty?.toString() ?? '';
          rows.add(row);
        }
        if (_cfg.itemHasStockPlace) {
          await _fillStockPlaces(rows);
        }
        _grid.replaceAll(rows);
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_grid.isEmpty &&
        !(widget.id == null && widget.docType == SubcontractDocType.order)) {
      _grid.addRow(SubcontractGridRow());
    }
    if (mounted) setState(() => _loading = false);
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  /// 新建时币种默认人民币：从币种字典按名称「人民币」解析其 id。
  /// 字典无 code，故按名称匹配；命中不到则保持空，交给用户手选。
  void _prefillDefaultCurrency() {
    if (!_cfg.hasCurrency || _currencyId != null) return;
    final entries = ref.read(mn.masterNameServiceProvider).currencyEntries;
    for (final entry in entries.entries) {
      if (entry.value.contains('人民币')) {
        _currencyId = entry.key;
        return;
      }
    }
  }

  /// 并发按 id 拉 3 个人员字段的名字（picker 的 initial 显示用）。失败静默。
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

  Future<void> _prefillFromApplication() async {
    final selectedIds = widget.applicationItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    // 卡片直达新建（无任务中心带入的申请行）：留空白单，由用户「从上游引入」拉取申请明细。
    if (selectedIds.isEmpty) return;
    try {
      final open = await ref
          .read(subcontractRepositoryProvider(SubcontractDocType.application))
          .decompositionPreview(selectedIds);
      if (open.isEmpty) {
        throw StateError('所选申请明细已全部分解，请返回委外任务中心刷新');
      }
      final goodsIds = open.map((item) => item.goodsId).toSet();
      await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      final names = ref.read(mn.masterNameServiceProvider);
      final rows = <SubcontractGridRow>[];
      for (final item in open) {
        final linked = LinkedItem(
          goodsId: item.goodsId,
          qty: item.remainingQty,
          maxQty: item.remainingQty,
          upstreamItemId: item.sourceItemId,
          colorId: item.colorId,
          unitId: item.unitId,
        );
        rows.add(
          SubcontractGridRow.fromLinked(
              linked,
              GoodsOption(id: item.goodsId, name: names.goods(item.goodsId)),
            )
            ..unitRate = item.unitRate
            ..sourceDocNo = item.sourceDocumentNo,
        );
      }
      if (rows.isEmpty) throw StateError('所选委外申请明细缺少有效货品');
      // 订货单不携带仓库：委外成品回收入哪个仓库，到进仓（到货登记）时再选，
      // 因此不做「同仓库才可合并生成订货」的限制。
      _grid.replaceAll(rows);
      final dates =
          open
              .map((line) => _parseDate(line.needDate))
              .whereType<DateTime>()
              .toList()
            ..sort();
      _deliverDate = dates.isEmpty ? null : dates.first;
      _sourceApplicationBillNo = open
          .map((line) => line.sourceDocumentNo)
          .where((number) => number.isNotEmpty)
          .toSet()
          .join('、');
      _orderSourceReady = true;
    } on StateError catch (error) {
      _orderSourceReady = false;
      if (mounted) context.appError(error.message);
    } on ApiException catch (error) {
      _orderSourceReady = false;
      if (mounted) context.appError(error.message);
    } catch (_) {
      _orderSourceReady = false;
      if (mounted) context.appError('读取委外申请失败，请返回委外任务中心重试');
    }
  }

  void _prefillReceiptFromExpectation() {
    final prefill = widget.receiptPrefill;
    if (prefill == null) return;
    if (prefill.orderType != ProcurementInboundOrderType.subcontract) {
      context.appError('预计到货来源与委外进仓单不一致，请返回任务中心重试');
      return;
    }
    _supplierId = prefill.supplierId;
    _warehouseId = prefill.warehouseId;
    final rows = <SubcontractGridRow>[];
    for (final item in prefill.items) {
      if (item.orderItemId.isEmpty ||
          item.goodsId.isEmpty ||
          item.approvedRemainingQty <= 0) {
        continue;
      }
      final row = SubcontractGridRow(sourceLocked: true)
        ..goods = GoodsOption(
          id: item.goodsId,
          code: item.goodsCode,
          name: item.goodsName,
        )
        ..upstreamItemId = item.orderItemId
        ..colorId = item.colorId
        ..unitId = item.unitId
        ..unitRate = item.unitRate.toDouble()
        ..sourceDocNo = prefill.orderBillNo
        ..approvedQty = item.approvedRemainingQty;
      // 预填批准剩余量但不设置 maxQty；仓库必须能如实登记实到超量，
      // 是否隔离由服务端审核动作权威判定。
      row.qty.text = procurementQty(item.approvedRemainingQty);
      // 到货登记不录价：订货单价随行携带（价格列隐藏），服务端审核时权威重算金额。
      if (item.unitPrice != null) {
        row.price.text = procurementQty(item.unitPrice!);
      }
      rows.add(row);
    }
    if (rows.isNotEmpty) {
      // 到货登记模式列已收窄（库位号列隐藏），此处仍补缓存：保存后详情页直接可显。
      _fillStockPlaces(rows);
      _grid.replaceAll(rows);
    }
  }

  /// 预计到货「登记实际到货」模式：新建进仓单且带任务中心预填。
  /// 标题/明细列/表单锁定都按到货登记场景呈现（只登记实到数量，不管价格）。
  bool get _isArrivalMode =>
      widget.id == null &&
      widget.docType == SubcontractDocType.receipt &&
      widget.receiptPrefill != null;

  /// 选货品范围：发料/材料退/损耗=材料；进仓/退货/订货/申请/询价=成品。
  UtenGoodsPickerScope get _pickerScope => switch (widget.docType) {
    SubcontractDocType.materialIssue ||
    SubcontractDocType.materialReturn ||
    SubcontractDocType.waste => UtenGoodsPickerScope.material,
    _ => UtenGoodsPickerScope.sellable,
  };

  Future<void> _pickGoods(SubcontractGridRow row) async {
    if (row.sourceLocked) return;
    final g = await showUtenGoodsPicker(context, ref, scope: _pickerScope);
    if (g == null) return;
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      ..colorId = g.colorId
      ..unitId = g.unitId
      ..stockPlaceNotifier.value = g.stockPlace;
  }

  /// 实物出入库单据（进仓/发料/退货/材料退）：按货品主档补全各行库位号
  /// （选择器已返回的不再二次拉取）。
  Future<void> _fillStockPlaces(Iterable<SubcontractGridRow> rows) async {
    final pending = rows
        .map((r) => r.goods?.id)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    if (pending.isEmpty) return;
    await ref.read(mn.masterNameServiceProvider).loadGoodsDetails(pending);
    if (!mounted) return;
    for (final r in rows) {
      final id = r.goods?.id;
      if (id != null && id.isNotEmpty) {
        r.stockPlaceNotifier.value =
            ref.read(mn.masterNameServiceProvider).goodsInfo(id)?.stockPlace;
      }
    }
  }

  /// 「从上游引入」：弹选择器，把所选 LinkedItem 映射成行追加。
  /// 表头已选委外商 → 面板锁定该委外商；表头未选 → 引入后以上游单据委外商回填。
  Future<void> _importFromUpstream() async {
    final result = await showSubcontractLinkPicker(
      context,
      ref,
      _cfg,
      initialSupplierId: _supplierId,
    );
    if (!mounted) return;
    if (result == null || result.items.isEmpty) return;
    if (_supplierId != null && result.supplierId != _supplierId) {
      context.appError('上游单据委外商与表头委外商不一致，已阻止引入');
      return;
    }
    final goodsIds = result.items
        .map((e) => e.goodsId)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    final rows = <SubcontractGridRow>[];
    for (final li in result.items) {
      if (li.goodsId.isEmpty) continue;
      final goods = GoodsOption(
        id: li.goodsId,
        name: ref.read(mn.masterNameServiceProvider).goods(li.goodsId),
      );
      rows.add(SubcontractGridRow.fromLinked(li, goods));
    }
    if (_cfg.itemHasStockPlace) {
      await _fillStockPlaces(rows);
    }
    // 引入前清掉占位空白行（新建态预填的无货品空行），直接显示引入项，不留顶部空行。
    _grid.removeWhere(
      (r) =>
          r.goods == null &&
          r.qty.text.trim().isEmpty &&
          r.price.text.trim().isEmpty,
    );
    _grid.addRows(rows);
    // 表头未选委外商 → 以上游单据委外商回填。
    final sid = result.supplierId;
    if (_supplierId == null && sid != null && sid.isNotEmpty) {
      setState(() => _supplierId = sid);
    }
  }

  Future<void> _save() async {
    final rows = _grid.rows;
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      context.appError('请至少添加一条明细');
      return;
    }
    if (_cfg.supplierRequired && _supplierId == null) {
      context.appError('请选择委外商');
      return;
    }
    if (_cfg.warehouseRequired && _warehouseId == null) {
      context.appError('请选择仓库');
      return;
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text) ?? 0;
      if (qty <= 0) {
        context.appError('${r.goods!.name} 的数量必须大于 0');
        return;
      }
      if (widget.docType != SubcontractDocType.receipt &&
          r.maxQty != null &&
          qty > r.maxQty! + 0.0000001) {
        context.appError('${r.goods!.name} 的数量不能超过申请剩余量 ${r.maxQty}');
        return;
      }
      if (widget.docType == SubcontractDocType.order &&
          r.upstreamItemId == null) {
        context.appError('${r.goods!.name} 缺少申请来源，请返回委外任务中心重新生成');
        return;
      }
      final price = double.tryParse(r.price.text);
      final priceError = validateSubcontractOrderPrice(
        docType: widget.docType,
        goodsName: r.goods!.name ?? r.goods!.code ?? '\u8be5\u8d27\u54c1',
        priceText: r.price.text,
      );
      if (priceError != null) {
        context.appError(priceError);
        return;
      }
      final w = double.tryParse(r.weight.text);
      final ending = double.tryParse(r.endingQty.text);
      final std = double.tryParse(r.standardQty.text);
      final wr = double.tryParse(r.wasteRate.text);
      final line = <String, dynamic>{
        'goodsId': r.goods!.id,
        'qty': qty,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        if (r.unitRate != null) 'unitRate': r.unitRate,
        if (r.sourceDocNo?.isNotEmpty == true) 'sourceDocNo': r.sourceDocNo,
        if (_cfg.itemHasPrice && price != null) 'price': price,
        if (_cfg.itemHasPrice && price != null) 'amountOriginal': qty * price,
        if (_cfg.itemHasPrice && price != null) 'amountLocal': qty * price,
        if (_cfg.itemHasWeight && w != null) 'weight': w,
        if (_cfg.itemHasGirth) 'girthQty': double.tryParse(r.girth.text),
        if (_cfg.itemHasBoxQty) 'boxQty': double.tryParse(r.boxQty.text),
        if (_cfg.itemHasWasteFields && ending != null) 'endingQty': ending,
        if (_cfg.itemHasWasteFields && std != null) 'standardQty': std,
        if (_cfg.itemHasWasteFields && wr != null) 'wasteRate': wr,
        if (_cfg.itemHasWasteFields && r.cause.text.trim().isNotEmpty)
          'cause': r.cause.text.trim(),
        if (r.upstreamItemId != null) ..._linkItemKey(r.upstreamItemId!),
        // 订货单：明细级委外商（为空时后端按表头委外商回落）；保存时按委外商拆单。
        if (widget.docType == SubcontractDocType.order && r.supplierId != null)
          'supplierId': r.supplierId,
      };
      itemsBody.add(line);
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      if (_cfg.hasSupplier && _supplierId != null) 'supplierId': _supplierId,
      if (_cfg.hasWarehouse && _warehouseId != null)
        'warehouseId': _warehouseId,
      if (_cfg.hasCurrency && _currencyId != null) 'currencyId': _currencyId,
      if (_cfg.hasCurrency) 'exchangeRate': double.tryParse(_rate.text) ?? 1,
      if (_cfg.hasTaxRate) 'taxRate': double.tryParse(_taxRate.text),
      if (_cfg.hasPurchaser && _purchaserId != null)
        'purchaserId': _purchaserId,
      if (_cfg.hasSender && _senderId != null) 'senderId': _senderId,
      if (_cfg.hasWorker && _workerId != null) 'workerId': _workerId,
      if (_cfg.hasDeliverDate && _deliverDate != null)
        'deliverDate': _fmt(_deliverDate!),
      if (_cfg.hasLastDate && _lastDate != null) 'lastDate': _fmt(_lastDate!),
      if (_cfg.hasBStyle) 'bStyle': int.tryParse(_bStyle.text),
      if (_cfg.hasTotalWeight)
        'totalWeight': double.tryParse(_totalWeight.text),
      if (_cfg.hasSettlement && _settlementMethodId != null)
        'settlementMethodId': _settlementMethodId,
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(subcontractRepositoryProvider(widget.docType));
      // 委外订货单新建：按委外商自动拆单（createBatch），逐张提交财务。
      if (widget.docType == SubcontractDocType.order && widget.id == null) {
        final created = await repo.createBatch(body);
        if (!mounted) return;
        String? financeError;
        for (final createdDoc in created) {
          try {
            await repo.submitFinance(createdDoc.id);
          } on ApiException catch (e) {
            financeError ??= e.message;
          }
        }
        if (!mounted) return;
        bumpListRefresh(ref, _cfg.refreshKey);
        if (financeError != null) {
          context.appWarning(
            '已生成 ${created.length} 张委外订货单，部分未提交财务：$financeError',
          );
        } else {
          context.appSuccess(
            created.length > 1
                ? '已按委外商拆分为 ${created.length} 张委外订货单并提交财务'
                : '委外订货单已提交财务审核',
          );
        }
        if (created.length == 1) {
          context.replace(
            SubcontractRoute.detail(_cfg.pathSegment, created.first.id),
          );
        } else {
          context.go('/subcontract/${_cfg.type.pathSegment}');
        }
        return;
      }
      final outcome = await saveSubcontractDocument(
        repository: repo,
        docType: widget.docType,
        body: body,
        id: widget.id,
      );
      if (!mounted) return;
      final d = outcome.detail;
      if (outcome.financeSubmitError case final error?) {
        context.appWarning('委外订货单已保存，但未提交财务：$error。可在详情页重新提交。');
        bumpListRefresh(ref, _cfg.refreshKey);
        context.replace(SubcontractRoute.detail(_cfg.pathSegment, d.id));
        return;
      }
      if (!mounted) return;
      context.appSuccess(
        widget.docType == SubcontractDocType.order
            ? '委外订货单已提交财务审核'
            : (widget.id == null ? '已创建' : '已保存'),
      );
      bumpListRefresh(ref, _cfg.refreshKey);
      context.replace(SubcontractRoute.detail(_cfg.pathSegment, d.id));
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 按 cfg 的链路开关把 upstreamItemId 映射到对应 key。
  /// 优先级与 upstreamTypeOf 一致（进仓 > 发料 > 订货 > 申请），保证 round-trip。
  Map<String, dynamic> _linkItemKey(String upstreamItemId) {
    if (_cfg.linkToReceiptItem) return {'receiptItemId': upstreamItemId};
    if (_cfg.linkToMaterialIssueItem) {
      // 材料退同时可链发料&订货；单字段设计下走 materialIssueItemId（与采购退货同款已知限制）。
      return {'materialIssueItemId': upstreamItemId};
    }
    if (_cfg.linkToOrderItem) return {'orderItemId': upstreamItemId};
    if (_cfg.linkToApplicationItem) {
      return {'applicationItemId': upstreamItemId};
    }
    return const {};
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(mn.masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: _isArrivalMode
            ? '登记实际到货 · ${_cfg.label}'
            : widget.id == null
            ? '新建${_cfg.label}'
            : '编辑${_cfg.label}',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: '/subcontract'),
        ),
        actions: _cfg.skipListOnCreate
            ? [
                UtenButton(
                  type: UtenButtonType.tonal,
                  icon: Icons.history_rounded,
                  onPressed: () =>
                      context.push('/subcontract/${_cfg.type.pathSegment}'),
                  child: const Text('查看历史'),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : UtenContentContainer(
                child: Scrollbar(
                  controller: _scrollCtl,
                  thumbVisibility: true,
                  child: ListView(
                    controller: _scrollCtl,
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    children: [
                      if (widget.id == null &&
                          widget.docType == SubcontractDocType.order &&
                          _sourceApplicationBillNo != null) ...[
                        _orderSourceBanner(theme),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      if (widget.docType == SubcontractDocType.receipt) ...[
                        _receiptArrivalBanner(theme),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      if (_cfg.approvalBlockedReason != null) ...[
                        _materialIssueSafetyBanner(theme),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
                      _headerCard(theme),
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
                          if (_cfg.hasUpstreamLink &&
                              // 到货登记模式：明细只能来自该预计到货任务，不允许再引入。
                              !_isArrivalMode)
                            UtenImportButton(
                              label: '从上游引入',
                              onPressed: _importFromUpstream,
                            ),
                        ],
                      ),
                      UtenEditableGrid<SubcontractGridRow>(
                        controller: _grid,
                        columns: subcontractGridColumns(
                          _pickGoods,
                          _cfg,
                          arrivalMode: _isArrivalMode,
                          // 订货单：明细可逐行选委外商，保存时按委外商自动拆单。
                          supplierEntries:
                              widget.docType == SubcontractDocType.order
                              ? names.supplierEntries
                              : const {},
                          headerSupplierId:
                              widget.docType == SubcontractDocType.order
                              ? _supplierId
                              : null,
                          onSupplierChanged: (_) => setState(() {}),
                        ),
                        createBlankRow: () => SubcontractGridRow(),
                        // 到货登记模式：行来自预计到货任务（带订货明细关联），
                        // 不允许添加无来源行；行尾删除保留（部分到货=该行本次不收）。
                        showAddRow:
                            widget.docType != SubcontractDocType.order &&
                            !_isArrivalMode,
                      ),
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: SafeArea(
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
              if (_cfg.hasAmount)
                ValueListenableBuilder<double>(
                  valueListenable: _grid.totalListenable,
                  builder: (_, total, _) => Text(
                    '合计 ¥${total.toStringAsFixed(2)}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else if (_cfg.hasTotalWeight)
                Text(
                  '总重 ${_totalWeight.text.isEmpty ? "0.00" : _totalWeight.text}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                )
              else
                ListenableBuilder(
                  listenable: _grid,
                  builder: (_, _) => Text(
                    '${_grid.rows.where((r) => r.goods != null).length} 行',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(width: UtenSpacing.s16),
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => context.pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: UtenSpacing.s12),
              SubcontractSaveActionButton(
                docType: widget.docType,
                isLoading: _saving,
                enabled: true,
                onPressed: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _receiptArrivalBanner(ThemeData theme) {
    final source = widget.receiptPrefill?.orderBillNo;
    // 权威订货单 id：有则编号可点跳订货详情，无则只展示编号（谱系仍可读）。
    final sourceOrderId = widget.receiptPrefill?.orderId;
    return Semantics(
      container: true,
      label:
          '请按实际到货数量登记。超出财务批准剩余量时不会直接入库，'
          '系统会隔离并通知指定财务负责人审批。',
      child: Card(
        color: theme.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.fact_check_outlined,
                color: theme.colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '请按实际到货数量登记',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (source?.isNotEmpty == true) ...[
                      const SizedBox(height: UtenSpacing.s4),
                      // 来源订货单：编号可点跳订货详情（展示编号而非 id；
                      // 任务不带权威 id 时退化为纯文本谱系）。
                      InkWell(
                        onTap: sourceOrderId == null
                            ? null
                            : () => context.push(
                                RoutePath.subcontractDocDetail(
                                  'orders',
                                  sourceOrderId,
                                ),
                              ),
                        borderRadius: BorderRadius.circular(4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '来源订货单：',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onTertiaryContainer,
                              ),
                            ),
                            Flexible(
                              child: Text(
                                source!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onTertiaryContainer,
                                  fontWeight: FontWeight.w700,
                                  decoration: sourceOrderId == null
                                      ? null
                                      : TextDecoration.underline,
                                  decorationColor:
                                      theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                            ),
                            if (sourceOrderId != null) ...[
                              const SizedBox(width: UtenSpacing.s4),
                              Icon(
                                Icons.open_in_new,
                                size: 14,
                                color: theme.colorScheme.onTertiaryContainer,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '请选择本次入库仓库，并按实际到货数量登记。'
                      '如果实到数量超过财务批准剩余量，仍可如实填写。'
                      '超出部分不会入库、不会生成应付：保存后审核时系统会自动隔离，'
                      '并通知指定财务负责人审批——财务可批准实到数量进入后续流程，'
                      '或要求退货（生成供应商退货任务）。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _orderSourceBanner(ThemeData theme) {
    final ready = _orderSourceReady;
    final background = ready
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.errorContainer;
    final foreground = ready
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onErrorContainer;
    final source = _sourceApplicationBillNo?.trim();
    return Semantics(
      container: true,
      label: ready ? '已从委外任务中心带入计划下达申请，可填写委外商和单价' : '必须先从委外任务中心选择计划下达申请',
      child: Card(
        color: background,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                ready ? Icons.account_tree_outlined : Icons.task_alt_outlined,
                color: foreground,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ready ? '已带入计划下达申请' : '请先选择委外申请明细',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      ready
                          ? '来源：${source?.isNotEmpty == true ? source : '计划下达申请'}。'
                                '每一行都保留原申请来源；可减少本次委外数量，剩余数量会继续留在任务中心。'
                          : '委外订货单不能手工空白新建。请回到任务中心选择需要分解的申请明细。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                      ),
                    ),
                    if (!ready) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      UtenButton(
                        icon: Icons.arrow_back_rounded,
                        onPressed: () => goFrom(
                          context,
                          RouteName.operationsSubcontractWorkbench,
                        ),
                        child: const Text('返回委外任务中心选择'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _materialIssueSafetyBanner(ThemeData theme) {
    final reason = _cfg.approvalBlockedReason!;
    return Semantics(
      container: true,
      label: '新增发料审核暂不可用。$reason 可保存草稿，但不能作为已发料事实。',
      child: Card(
        color: theme.colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                color: theme.colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '新增发料审核暂不可用',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '$reason\n可保存草稿，但不能作为已发料事实。'
                      '\n$kSubcontractMaterialIssueHistoricalCompatibilityNote',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerCard(ThemeData theme) {
    final names = ref.watch(mn.masterNameServiceProvider);
    final List<ReferenceMethodOption> settlementMethods =
        ref.watch(settlementMethodOptionsProvider).valueOrNull ??
        const <ReferenceMethodOption>[];
    return Card(
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
                    hintText: _billNo.text.isEmpty ? '保存后自动生成' : null,
                    filled: _billNo.text.isEmpty,
                    suffixIcon: _billNo.text.isEmpty
                        ? const Icon(Icons.autorenew_outlined, size: 18)
                        : const Icon(Icons.lock_outline, size: 16),
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
                  onChanged: (d) => setState(() => _billDate = d),
                ),
                if (_cfg.hasSupplier)
                  _dropdown(
                    '委外商',
                    _supplierId,
                    names.supplierEntries,
                    (v) => setState(() => _supplierId = v),
                    required: _cfg.supplierRequired,
                    // 到货登记模式：委外商来自预计到货任务，锁定防手滑改坏来源关联。
                    enabled: !_isArrivalMode,
                  ),
                if (_cfg.hasWarehouse)
                  // 到货登记模式也不锁仓：入库仓库在进仓时确定，
                  // 预计到货任务可能不再携带仓库（订货单不带仓库）。
                  _dropdown(
                    '仓库',
                    _warehouseId,
                    names.warehouseEntries,
                    (v) => setState(() => _warehouseId = v),
                    required: _cfg.warehouseRequired,
                  ),
                if (_cfg.hasCurrency) ...[
                  _dropdown(
                    '币种',
                    _currencyId,
                    names.currencyEntries,
                    (v) => setState(() => _currencyId = v),
                  ),
                  TextField(
                    controller: _rate,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '汇率'),
                  ),
                ],
                if (_cfg.hasTaxRate)
                  TextField(
                    controller: _taxRate,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '税率(%)'),
                  ),
                // 人员字段（按 config 显隐）
                if (_cfg.hasPurchaser)
                  _employeePicker(
                    label: '采购员',
                    currentId: _purchaserId,
                    defaultDeptCode: kDeptCodeSales,
                    onChanged: (id) => setState(() => _purchaserId = id),
                  ),
                if (_cfg.hasSender)
                  _employeePicker(
                    label: '交货人',
                    currentId: _senderId,
                    onChanged: (id) => setState(() => _senderId = id),
                  ),
                if (_cfg.hasWorker)
                  _employeePicker(
                    label: '经办人',
                    currentId: _workerId,
                    defaultDeptCode: kDeptCodeSales,
                    onChanged: (id) => setState(() => _workerId = id),
                  ),
                // 日期字段（按 config 显隐，统一 UtenDateField）
                if (_cfg.hasDeliverDate)
                  UtenDateField(
                    label: '交货日期',
                    value: _deliverDate,
                    onChanged: (d) => setState(() => _deliverDate = d),
                  ),
                if (_cfg.hasLastDate)
                  UtenDateField(
                    label: '最后交货日',
                    value: _lastDate,
                    onChanged: (d) => setState(() => _lastDate = d),
                  ),
                if (_cfg.hasBStyle)
                  TextField(
                    controller: _bStyle,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'bStyle（业务类型）',
                    ),
                  ),
                if (_cfg.hasTotalWeight)
                  TextField(
                    controller: _totalWeight,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '总重'),
                  ),
                if (_cfg.hasSettlement)
                  DropdownButtonFormField<String?>(
                    initialValue: _settlementMethodId,
                    decoration: const InputDecoration(labelText: '结帐方式'),
                    items: [
                      const DropdownMenuItem<String?>(child: Text('— 不选 —')),
                      for (final method in settlementMethods)
                        DropdownMenuItem<String?>(
                          value: method.id,
                          child: Text('${method.name}（${method.code}）'),
                        ),
                      if (_settlementMethodId != null &&
                          !settlementMethods.any(
                            (method) => method.id == _settlementMethodId,
                          ))
                        DropdownMenuItem<String?>(
                          value: _settlementMethodId,
                          child: Text(
                            _settlementStyle == null
                                ? _settlementMethodId!
                                : '历史结帐方式 $_settlementStyle',
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _settlementMethodId = v;
                      final matches = settlementMethods.where(
                        (method) => method.id == v,
                      );
                      _settlementStyle = matches.isEmpty
                          ? null
                          : matches.first.legacyId;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _remark,
              decoration: const InputDecoration(labelText: '备注'),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  /// 人员选择器：关键字为空且指定 [defaultDeptCode] 时收敛到该部门子树、否则全公司搜。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
    String? defaultDeptCode,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
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

  Widget _dropdown(
    String label,
    String? value,
    Map<String, String> entries,
    ValueChanged<String?> onChanged, {
    bool required = false,
    bool enabled = true,
  }) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
      enabled: enabled,
      items: [
        for (final e in entries.entries)
          UtenDropdownItem(value: e.key, label: e.value),
        if (value != null && value.isNotEmpty && !entries.containsKey(value))
          UtenDropdownItem(value: value, label: value),
      ],
      onChanged: onChanged,
    );
  }
}

class SubcontractSaveActionButton extends StatelessWidget {
  const SubcontractSaveActionButton({
    super.key,
    required this.docType,
    required this.isLoading,
    required this.enabled,
    required this.onPressed,
  });

  final SubcontractDocType docType;
  final bool isLoading;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final submitsFinance = docType == SubcontractDocType.order;
    return UtenButton(
      isLoading: isLoading,
      icon: submitsFinance ? Icons.send_outlined : Icons.save_outlined,
      onPressed: enabled && !isLoading ? onPressed : null,
      child: Text(submitsFinance ? '保存并提交财务' : '保存'),
    );
  }
}
