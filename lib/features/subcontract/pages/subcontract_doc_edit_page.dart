// 委外单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 2026-09 行级商业条款改造起不再服务委外订货单（走专属页 subcontract_order_edit_page.dart：
// 行级委外商+商业条款+按组合拆单）；本页服务 询价/申请(只读)/进仓/发料/退货/材料退/损耗。
//
// 差异由 SubcontractDocConfig 驱动：
//  - 委外商(supplier)/仓库/币种/税率 下拉按 has* / *Required 显隐；
//    汇率不展示不录入：固定 1（编辑历史单沿用其快照值）——订货单已支持行级汇率。
//  - 人员（采购员/交货人/经办人）按 hasPurchaser/hasSender/hasWorker 显隐 UtenEmployeePicker；
//  - 日期（单据/交货/最后交货）统一用 UtenDateField（outlined，与其它字段同款）；
//  - 材料退的 bStyle(int)、损耗的 totalWeight、进仓/退货的 settlementStyle 按 has* 显隐；
//  - 「从上游引入」按 hasUpstreamLink 显隐（进仓→订货；退货→进仓/订货；
//    发料→订货；材料退→发料/订货；损耗→发料）。
//  - 明细改 Excel 表（UtenEditableGrid）：货品/数量/(单价?)/(金额?)/(重量?)/(围数?)/(胶箱数)/
//    (损耗 4 列) 按 cfg.itemHas* 显隐 + 每行末尾「备注」列（随行提交 remark）；
//    添加行/添加多行 + 行尾删除 + sticky 表头。
//
// 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// 保存组装 body 调 create/update，成功后跳详情。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/providers/master_name_provider.dart' show GoodsOption;
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../basic_data/widgets/uten_supplier_picker.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/editable_grid_column_prefs.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/providers/session_provider.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../repositories/subcontract_repository.dart';
import '../services/subcontract_save_workflow.dart';
import '../widgets/subcontract_grid_columns.dart';
import '../widgets/subcontract_link_picker.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';

class SubcontractDocEditPage extends ConsumerStatefulWidget {
  const SubcontractDocEditPage({super.key, required this.docType, this.id});
  final SubcontractDocType docType;
  final String? id; // null=新建

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
  // 委外不录汇率（UI 无输入框）：新建固定 1，编辑沿用历史单快照值随保存回传，
  // 保证进仓审核「币种/汇率/结算方式与订单快照一致」校验不断链。
  final _rate = TextEditingController(text: '1');
  final _taxRate = TextEditingController();
  String? _currencyError;
  String? _taxRateError;
  final _bStyle = TextEditingController();
  final _totalWeight = TextEditingController();
  // 损耗建议索赔金额（本币）：仅供后续责任决定，不自动扣款或冲应付。
  final _deductAmount = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();

  // 结算方式（进仓/退货兼容历史字典码）
  String? _settlementMethodId;
  String? _settlementError;

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
      // 币种默认人民币（进仓/退货等有币种的单据）。
      _prefillDefaultCurrency();
    }
    if (widget.id != null) {
      try {
        final d = await ref
            .read(subcontractRepositoryProvider(widget.docType))
            .detail(widget.id!);
        if (widget.docType != SubcontractDocType.application) {
          final writable =
              d.status == kSubcontractStatusDraft &&
              d.canEdit &&
              await loadDocumentOwnerCanWrite(
                ref,
                DocumentDataScope.subcontract,
                d.makerId,
              );
          if (!mounted) return;
          if (!writable) {
            context.appWarning(documentScopeReadOnlyMessage, force: true);
            context.replace(
              SubcontractRoute.detail(_cfg.pathSegment, widget.id!),
            );
            return;
          }
        }
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
        if (d.deductAmount != null) {
          _deductAmount.text = d.deductAmount.toString();
        }
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
            ..planItemId = it.planItemId
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..unitRate = it.unitRate
            ..sourceDocNo = it.sourceDocNo;
          row.remark.text = it.remark ?? '';
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
    if (_grid.isEmpty) {
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
            employeeCode: p.code,
            departmentName: p.departmentName,
          );
        } catch (_) {
          // 静默：picker 的 initial 为 null 时不显示名字，不阻塞流程。
        }
      }),
    );
  }

  bool get _commercialTermsInheritedFromSource =>
      widget.docType == SubcontractDocType.returnDoc &&
      _grid.rows.any((row) => row.upstreamItemId != null);

  /// 委外商确定后预填结算方式：上游单据带结算方式时优先（进仓/退货沿用来源
  /// 快照），否则用供应商主档默认（V452）。仅预填启用中的方式；不替换单据
  /// 必填校验，也不覆盖用户已选值；退货来源继承模式（字段隐藏）不预填。
  Future<void> _prefillSettlementForSupplier(
    String? supplierId,
    String? upstreamSettlementId,
  ) async {
    if (!_cfg.hasSettlement || _commercialTermsInheritedFromSource) return;
    if (_settlementMethodId != null) return;
    if (supplierId == null || supplierId.isEmpty) return;
    final candidate = (upstreamSettlementId?.isNotEmpty ?? false)
        ? upstreamSettlementId
        : ref
              .read(mn.masterNameServiceProvider)
              .supplierDefaultSettlement(supplierId);
    if (candidate == null || candidate.isEmpty) return;
    try {
      final methods = await ref.read(settlementMethodOptionsProvider.future);
      if (!mounted) return;
      // 默认/来源方式已停用或软删时不预填，避免下拉里出现死值。
      if (!methods.any((m) => m.id == candidate)) return;
      setState(() {
        _settlementMethodId = candidate;
        _settlementError = null;
      });
    } catch (_) {
      // 字典暂不可用不预填；保存前必填校验仍兜底。
    }
  }

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

  /// 表头委外商展示名（启用商显名称；编辑旧单遇禁用商标注「已禁用」）。
  String? _supplierHeaderName() {
    final id = _supplierId;
    if (id == null || id.isEmpty) return null;
    final names = ref.read(mn.masterNameServiceProvider);
    final name = names.supplierEntries[id];
    if (name == null || name.isEmpty) return id;
    return names.isSupplierDisabled(id) ? '$name（已禁用）' : name;
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
        r.stockPlaceNotifier.value = ref
            .read(mn.masterNameServiceProvider)
            .goodsInfo(id)
            ?.stockPlace;
      }
    }
  }

  /// 「从上游引入」：弹选择器，把所选 LinkedItem 映射成行追加。
  /// 表头已选委外商 → 面板锁定该委外商；表头未选 → 引入后以上游单据委外商回填。
  Future<void> _importFromUpstream() async {
    // 上游为申请单（仅 linkToApplicationItem，订货场景）时无委外商概念，
    // 不锁定也不回填（与采购订货引入申请同款）。
    final upstreamIsApplication =
        _cfg.linkToApplicationItem &&
        !_cfg.linkToOrderItem &&
        !_cfg.linkToReceiptItem &&
        !_cfg.linkToMaterialIssueItem;
    final result = await showSubcontractLinkPicker(
      context,
      ref,
      _cfg,
      initialSupplierId: upstreamIsApplication ? null : _supplierId,
    );
    if (!mounted) return;
    if (result == null || result.items.isEmpty) return;
    if (!upstreamIsApplication &&
        _supplierId != null &&
        result.supplierId != _supplierId) {
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
    // 表头未选委外商 → 以上游单据委外商回填；结算方式未选时按上游单据结算方式
    // （进仓/退货引入订货）或供应商默认（V452）预填。
    final sid = result.supplierId;
    if (_supplierId == null && sid != null && sid.isNotEmpty) {
      setState(() => _supplierId = sid);
      unawaited(_prefillSettlementForSupplier(sid, result.settlementMethodId));
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
    final taxRateText = _taxRate.text.trim();
    final taxRateError = validateSubcontractTaxRate(
      taxRateText,
      required: false,
    );
    if (_cfg.hasTaxRate &&
        !_commercialTermsInheritedFromSource &&
        taxRateError != null) {
      setState(() => _taxRateError = taxRateError);
      context.appError(taxRateError);
      return;
    }
    final parsedTaxRate = taxRateText.isEmpty
        ? null
        : double.tryParse(taxRateText);
    if (_cfg.settlementRequired) {
      final methodsState = ref.read(settlementMethodOptionsProvider);
      if (methodsState.isLoading) {
        context.appError('结算方式字典仍在加载，请稍后重试');
        return;
      }
      if (methodsState.hasError) {
        context.appError('结算方式字典加载失败，请点击重试');
        return;
      }
      final methods =
          methodsState.valueOrNull ?? const <ReferenceMethodOption>[];
      if (_settlementMethodId == null ||
          !methods.any((method) => method.id == _settlementMethodId)) {
        setState(
          () => _settlementError = _settlementMethodId == null
              ? '请选择结算方式'
              : '当前结算方式已停用，请重新选择',
        );
        context.appError('请选择有效的委外订单结算方式');
        return;
      }
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
        context.appError('${r.goods!.name} 的数量不能超过上游剩余量 ${r.maxQty}');
        return;
      }
      final price = double.tryParse(r.price.text);
      final priceError = validateSubcontractOrderPrice(
        docType: widget.docType,
        goodsName: r.goods!.name ?? r.goods!.code ?? '该货品',
        priceText: r.price.text,
      );
      if (priceError != null) {
        context.appError(priceError);
        return;
      }
      final weightText = r.weight.text.trim();
      final w = weightText.isEmpty ? null : double.tryParse(weightText);
      if (_cfg.itemHasWeight &&
          weightText.isNotEmpty &&
          (w == null || w <= 0)) {
        context.appError('${r.goods!.name} 的实际重量必须大于 0');
        return;
      }
      final ending = double.tryParse(r.endingQty.text);
      final std = double.tryParse(r.standardQty.text);
      final wr = double.tryParse(r.wasteRate.text);
      final remarkText = r.remark.text.trim();
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
        // 发料计划行回传（V304）：计划生成的出仓草稿保存时不断链。
        if (r.planItemId != null) 'planItemId': r.planItemId,
        if (remarkText.isNotEmpty) 'remark': remarkText,
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
      if (_cfg.hasCurrency &&
          !_commercialTermsInheritedFromSource &&
          _currencyId != null)
        'currencyId': _currencyId,
      if (_cfg.hasCurrency && !_commercialTermsInheritedFromSource)
        'exchangeRate': double.tryParse(_rate.text) ?? 1,
      if (_cfg.hasTaxRate && !_commercialTermsInheritedFromSource)
        'taxRate': parsedTaxRate,
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
      if (_cfg.hasDeductAmount)
        'deductAmount': double.tryParse(_deductAmount.text),
      if (_cfg.hasSettlement &&
          !_commercialTermsInheritedFromSource &&
          _settlementMethodId != null)
        'settlementMethodId': _settlementMethodId,
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(subcontractRepositoryProvider(widget.docType));
      final outcome = await saveSubcontractDocument(
        repository: repo,
        docType: widget.docType,
        body: body,
        id: widget.id,
      );
      if (!mounted) return;
      final d = outcome.detail;
      if (outcome.financeSubmitError case final error?) {
        context.appWarning('单据已保存，但未提交财务：$error。可在详情页重新提交。');
        bumpListRefresh(ref, _cfg.refreshKey);
        context.replace(SubcontractRoute.detail(_cfg.pathSegment, d.id));
        return;
      }
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
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
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}',
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
                          if (_cfg.hasUpstreamLink)
                            UtenImportButton(
                              label: '从上游引入',
                              onPressed: _importFromUpstream,
                            ),
                        ],
                      ),
                      // 列显隐/排序按单据模式分桶持久化（账号级，跨设备生效）。
                      Builder(
                        builder: (_) {
                          final columnPrefs = ref.watch(
                            subcontractApplicationGridColumnPrefsProvider,
                          )[widget.docType.name];
                          return UtenEditableGrid<SubcontractGridRow>(
                            controller: _grid,
                            showColumnSettings: true,
                            initialColumnOrder: columnPrefs?.order,
                            initialHiddenColumnKeys: columnPrefs?.hidden,
                            onColumnSettingsChanged: (order, hidden) => ref
                                .read(
                                  subcontractApplicationGridColumnPrefsProvider
                                      .notifier,
                                )
                                .updateFor(widget.docType.name, order, hidden),
                            columns: subcontractGridColumns(
                              _pickGoods,
                              _cfg,
                              unitEntries: ref
                                  .watch(mn.masterNameServiceProvider)
                                  .unitEntries,
                              // 每行末尾备注列（随行提交 remark）。
                              showRemark: true,
                            ),
                            createBlankRow: () => SubcontractGridRow(),
                            cloneRow: (r) => r.clone(),
                          );
                        },
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
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
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
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => context.pop(),
                child: const Text('取消'),
              ),
              SubcontractSaveActionButton(
                docType: widget.docType,
                isLoading: _saving,
                enabled: true,
                // 订货已走专属编辑页（含提交财务）；本页各类型统一普通保存。
                submitFinance: false,
                onPressed: _save,
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
    final settlementMethods =
        ref.watch(settlementMethodOptionsProvider).valueOrNull ??
        const <ReferenceMethodOption>[];
    final settlementEntries = <String, String>{
      for (final method in settlementMethods)
        method.id: '${method.name}(${method.code})',
    };
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
                  errorBuilder: utenTextFieldErrorBuilder,
                  readOnly: true,
                  controller: _billNo,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: '单据号',
                      hintText: _billNo.text.isEmpty ? '保存后自动生成' : null,
                      filled: _billNo.text.isEmpty,
                      suffixIcon: _billNo.text.isEmpty
                          ? const Icon(Icons.autorenew_outlined, size: 18)
                          : const Icon(Icons.lock_outline, size: 16),
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
                  onChanged: (d) => setState(() => _billDate = d),
                ),
                // 进仓/发料/退货等：表头单一委外商（订货单行级条款已走专属页）。
                // 选商走右侧滑入面板（同销售订货单「客户」交互）：
                // 分类树+搜索+分页+可内联新建，仅列启用供应商。
                if (_cfg.hasSupplier)
                  SupplierPickerField(
                    initialId: _supplierId,
                    initialName: _supplierHeaderName(),
                    label: '委外商',
                    required: _cfg.supplierRequired,
                    onChanged: (v) {
                      setState(() => _supplierId = v);
                      unawaited(_prefillSettlementForSupplier(v, null));
                    },
                    onPick: () =>
                        showUtenSupplierPicker(context, ref, title: '选择委外商'),
                  ),
                if (_cfg.hasWarehouse)
                  // 回厂新建已经迁到仓库独立登记页；这里仅服务其余单据或既有草稿编辑。
                  // V476：仓库下拉带主/子层级（父仓置灰分组，单据落具体仓）。
                  UtenDropdownField(
                    label: '仓库',
                    value: _warehouseId,
                    required: _cfg.warehouseRequired,
                    items: warehouseHierarchyItems(names.warehouseHierarchy),
                    onChanged: (v) => setState(() => _warehouseId = v),
                  ),
                if (_cfg.hasCurrency && !_commercialTermsInheritedFromSource)
                  _dropdown(
                    '币种',
                    _currencyId,
                    names.currencyEntries,
                    (v) => setState(() {
                      _currencyId = v;
                      _currencyError = null;
                    }),
                    required: widget.docType == SubcontractDocType.order,
                    allowClear: widget.docType != SubcontractDocType.order,
                    errorMessage: _currencyError,
                    info: widget.docType == SubcontractDocType.order
                        ? '财务批准后冻结为委外订单币种快照'
                        : null,
                  ),
                // 结算方式紧跟币种（与采购订货单表头次序一致）。
                if (_cfg.hasSettlement && !_commercialTermsInheritedFromSource)
                  _dropdown(
                    '结算方式',
                    _settlementMethodId,
                    settlementEntries,
                    (value) => setState(() {
                      _settlementMethodId = value;
                      _settlementError = null;
                    }),
                    required: _cfg.settlementRequired,
                    allowClear: !_cfg.settlementRequired,
                    errorMessage: _settlementError,
                    info: _cfg.settlementRequired ? '财务批准后冻结为委外订单结算快照' : null,
                  ),
                if (_cfg.hasTaxRate && !_commercialTermsInheritedFromSource)
                  TextField(
                    controller: _taxRate,
                    onChanged: (_) {
                      if (_taxRateError != null) {
                        setState(() => _taxRateError = null);
                      }
                    },
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        label: fieldLabel(
                          '税率(%)',
                          theme,
                          required: widget.docType == SubcontractDocType.order,
                          info: widget.docType == SubcontractDocType.order
                              ? '必填，允许 0；财务批准后冻结，范围 0–100'
                              : '范围 0–100',
                        ),
                        error: _taxRateError == null
                            ? null
                            : UtenFieldMessage.error(_taxRateError!),
                      ),
                    ),
                  ),
                if (_commercialTermsInheritedFromSource)
                  const Text('币种、税率与结算方式继承来源订货/回厂快照，本页只读且不重复提交。'),
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
                      labelText: 'bStyle(业务类型)',
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
                if (_cfg.hasDeductAmount)
                  TextField(
                    controller: _deductAmount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        label: fieldLabel(
                          '建议索赔金额(本币)',
                          theme,
                          info: '仅供后续财务责任决定参考；不会自动扣款、抵销或生成负应付',
                        ),
                      ),
                    ),
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
              employeeCode: e.code,
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
    bool allowClear = true,
    String? errorMessage,
    String? info,
  }) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
      enabled: enabled,
      allowClear: allowClear,
      errorMessage: errorMessage,
      info: info,
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
    this.submitFinance = true,
    required this.onPressed,
  });

  final SubcontractDocType docType;
  final bool isLoading;
  final bool enabled;
  final bool submitFinance;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final submitsFinance = docType == SubcontractDocType.order && submitFinance;
    return UtenButton(
      isLoading: isLoading,
      icon: submitsFinance ? Icons.send_outlined : Icons.save_outlined,
      onPressed: enabled && !isLoading ? onPressed : null,
      child: Text(
        // 文案与采购订货单编辑页（purchaseSaveActionLabel）同款。
        switch (docType) {
          SubcontractDocType.order when submitFinance => '保存并提交财务审核',
          SubcontractDocType.order => '保存订货单草稿',
          SubcontractDocType.receipt ||
          SubcontractDocType.returnDoc => '保存，下一步审核',
          _ => '保存',
        },
      ),
    );
  }
}
