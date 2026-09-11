// 采购单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 2026-09 行级商业条款改造起只服务 申请(只读)/收货/退货 三类；采购订货单走专属页
// （purchase_order_edit_page.dart，行级供应商+商业条款+按组合拆单）。
//
// 差异由 config 驱动：供应商/币种/仓库下拉按 has* 显隐；
// 人员（申请人/采购员/交货人/收货人）按 has* 显隐 UtenEmployeePicker；
// 日期（单据/需求/交货）统一用 UtenDateField（outlined，与其它字段同款）；
// 「从上游引入」按 hasUpstreamLink 显隐（收货/退货）。
//
// 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// 明细改 Excel 表：货品/数量/单价→金额自动 + 添加行/添加多行 + 行尾删除 + sticky 表头
// + 每行末尾「备注」列（随行提交 remark）。
// 保存组装 body 调 create/update，成功后跳详情。
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/buttons/uten_drafts_button.dart';
import '../../../components/buttons/uten_edit_floating_actions.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/widgets/editable_grid_totals_bar.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../notice/providers/notice_providers.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/editable_grid_column_prefs.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_hierarchy_dropdown.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../repositories/purchase_repository.dart';
import '../../basic_data/widgets/uten_supplier_picker.dart';
import '../widgets/doc_link_picker.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import '../widgets/purchase_grid_columns.dart';

String purchaseSaveActionLabel(
  PurchaseDocType docType, {
  required bool submitFinance,
}) => switch (docType) {
  PurchaseDocType.order when submitFinance => '保存并提交财务审核',
  PurchaseDocType.order => '保存订货单草稿',
  PurchaseDocType.receipt || PurchaseDocType.returnDoc => '保存，下一步审核',
  PurchaseDocType.request => '保存',
};

class PurchaseDocEditPage extends ConsumerStatefulWidget {
  const PurchaseDocEditPage({super.key, required this.docType, this.id});
  final PurchaseDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<PurchaseDocEditPage> createState() =>
      _PurchaseDocEditPageState();
}

class _PurchaseDocEditPageState extends ConsumerState<PurchaseDocEditPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);

  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _taxRate = TextEditingController(text: '0');
  DateTime _billDate = ChinaDateTime.today();
  String? _supplierId;
  String? _warehouseId;
  String? _departmentId;
  String? _currencyId;
  String? _settlementMethodId;
  String? _settlementError;

  // 人员字段（id + 给 picker 的 initial 项缓存）
  String? _applicantId;
  String? _purchaserId;
  String? _senderId;
  String? _receiverId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  // 日期字段
  DateTime? _needDate;
  DateTime? _deliverDate;

  final _grid = UtenEditableGridController<PurchaseGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loading = false;
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

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
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    if (widget.id == null) {
      // 仓库预填「本类型最近一张单的仓库」（与销售 D1 同款），减少手选。
      // 订货单不涉及仓库（入库仓库到收货登记时再选），跳过预填。
      if (_cfg.hasWarehouse) {
        try {
          final last = await ref
              .read(purchaseRepositoryProvider(widget.docType))
              .list(size: 1);
          if (last.items.isNotEmpty &&
              WarehouseSelection(
                ref.read(masterNameServiceProvider).warehouseHierarchy,
              ).selectableIds.contains(last.items.first.warehouseId)) {
            _warehouseId = last.items.first.warehouseId;
          }
        } catch (_) {
          /* 预填失败静默，用户手选 */
        }
      }
      // 申请人/采购员/收货人默认当前登录人（交货人是供应商侧人员，不预填）。
      final meId = ref.read(sessionProvider).user?.employeeId;
      if (meId != null && meId.isNotEmpty) {
        if (_cfg.hasApplicant) _applicantId = meId;
        if (_cfg.hasPurchaser) _purchaserId = meId;
        if (_cfg.hasReceiver) _receiverId = meId;
        await _preloadEmployees([meId]);
      }
      // 币种默认人民币（订货/收货/退货；申请无币种）。
      _prefillDefaultCurrency();
    }
    if (widget.id != null) {
      try {
        final d = await ref
            .read(purchaseRepositoryProvider(widget.docType))
            .detail(widget.id!);
        if (widget.docType != PurchaseDocType.request) {
          final writable =
              d.status == kPurchaseStatusDraft &&
              d.canEdit &&
              await loadDocumentOwnerCanWrite(
                ref,
                DocumentDataScope.purchase,
                d.makerId,
              );
          if (!mounted) return;
          if (!writable) {
            context.appWarning(documentScopeReadOnlyMessage, force: true);
            context.replace(
              RoutePath.purchaseDocDetail(_cfg.type.pathSegment, widget.id!),
            );
            return;
          }
        }
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        await _preloadEmployees([
          d.applicantId,
          d.purchaserId,
          d.senderId,
          d.receiverId,
        ]);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _supplierId = d.supplierId;
        _warehouseId = d.warehouseId;
        _departmentId = d.departmentId;
        _currencyId = d.currencyId;
        _settlementMethodId = d.settlementMethodId;
        _rate.text = d.exchangeRate?.toString() ?? '1';
        if (d.taxRate != null) _taxRate.text = d.taxRate.toString();
        _applicantId = d.applicantId;
        _purchaserId = d.purchaserId;
        _senderId = d.senderId;
        _receiverId = d.receiverId;
        _needDate = _parseDate(d.needDate);
        _deliverDate = _parseDate(d.deliverDate);
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        final rows = <PurchaseGridRow>[];
        for (final it in d.items) {
          final upstreamItemId =
              it.receiptItemId ?? it.orderItemId ?? it.requestItemId;
          final row = PurchaseGridRow(sourceLocked: upstreamItemId != null)
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(masterNameServiceProvider).goods(it.goodsId),
                  )
            // 优先级与 _linkItemKey 一致（receipt > order > request），保证 round-trip。
            ..upstreamItemId = upstreamItemId
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..unitRate = it.unitRate;
          row.qty.text = it.qty?.toString() ?? '';
          row.weight.text = it.weight?.toString() ?? '';
          row.price.text = it.price?.toString() ?? '';
          row.remark.text = it.remark ?? '';
          rows.add(row);
        }
        if (widget.docType == PurchaseDocType.receipt ||
            widget.docType == PurchaseDocType.returnDoc) {
          await _fillStockPlaces(rows);
        }
        _grid.replaceAll(rows);
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_grid.isEmpty) _grid.addRow(PurchaseGridRow());
    if (mounted) setState(() => _loading = false);
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  /// 新建时币种默认人民币：从币种字典按名称「人民币」解析其 id。
  /// 字典无 code，故按名称匹配；命中不到则保持空，交给用户手选。
  void _prefillDefaultCurrency() {
    if (!_cfg.hasCurrency || _currencyId != null) return;
    final entries = ref.read(masterNameServiceProvider).currencyEntries;
    for (final entry in entries.entries) {
      if (entry.value.contains('人民币')) {
        _currencyId = entry.key;
        return;
      }
    }
  }

  /// 并发按 id 拉 4 个人员字段的名字（picker 的 initial 显示用）。失败静默。
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

  Future<void> _pickGoods(PurchaseGridRow row) async {
    if (row.sourceLocked) return;
    final g = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.material,
    );
    if (g == null) return;
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      ..colorId = g.colorId
      ..unitId = g.unitId
      ..unitRate = 1
      ..stockPlaceNotifier.value = g.stockPlace;
  }

  /// 供应商确定后预填结账方式：上游单据带结账方式时优先（收货/退货沿用来源
  /// 快照），否则用供应商主档默认（V452）。仅预填启用中的方式；不替换单据
  /// 必填校验，也不覆盖用户已选值。
  Future<void> _prefillSettlementForSupplier(
    String? supplierId,
    String? upstreamSettlementId,
  ) async {
    if (!_cfg.hasSettlement || _settlementMethodId != null) return;
    if (supplierId == null || supplierId.isEmpty) return;
    final candidate = (upstreamSettlementId?.isNotEmpty ?? false)
        ? upstreamSettlementId
        : ref
              .read(masterNameServiceProvider)
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

  /// 表头供应商展示名（启用商显名称；编辑旧单遇禁用商标注「已禁用」）。
  String? _supplierHeaderName() {
    final id = _supplierId;
    if (id == null || id.isEmpty) return null;
    final names = ref.read(masterNameServiceProvider);
    final name = names.supplierEntries[id];
    if (name == null || name.isEmpty) return null;
    return names.isSupplierDisabled(id) ? '$name（已禁用）' : name;
  }

  /// 收货/退货实物单据：按货品主档补全各行库位号（选择器已返回的不再二次拉取）。
  Future<void> _fillStockPlaces(Iterable<PurchaseGridRow> rows) async {
    final pending = rows
        .map((r) => r.goods?.id)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    if (pending.isEmpty) return;
    await ref.read(masterNameServiceProvider).loadGoodsDetails(pending);
    if (!mounted) return;
    for (final r in rows) {
      final id = r.goods?.id;
      if (id != null && id.isNotEmpty) {
        r.stockPlaceNotifier.value = ref
            .read(masterNameServiceProvider)
            .goodsInfo(id)
            ?.stockPlace;
      }
    }
  }

  /// 「从上游引入」：弹选择器，把所选 LinkedItem 映射成行追加。
  /// 表头已选供应商 → 面板锁定该供应商；表头未选 → 引入后以上游单据供应商回填。
  Future<void> _importFromUpstream() async {
    // 上游为申请单（仅 linkToRequestItem）时无供应商概念，不锁定也不回填。
    final upstreamIsRequest =
        _cfg.linkToRequestItem &&
        !_cfg.linkToOrderItem &&
        !_cfg.linkToReceiptItem;
    final result = await showDocLinkPicker(
      context,
      ref,
      _cfg,
      initialSupplierId: upstreamIsRequest ? null : _supplierId,
    );
    if (!mounted) return;
    if (result == null || result.items.isEmpty) return;
    if (!upstreamIsRequest &&
        _supplierId != null &&
        result.supplierId != _supplierId) {
      context.appError('上游单据供应商与表头供应商不一致，已阻止引入');
      return;
    }
    final goodsIds = result.items
        .map((e) => e.goodsId)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    final rows = <PurchaseGridRow>[];
    for (final li in result.items) {
      if (li.goodsId.isEmpty) continue;
      final goods = GoodsOption(
        id: li.goodsId,
        name: ref.read(masterNameServiceProvider).goods(li.goodsId),
      );
      rows.add(PurchaseGridRow.fromLinked(li, goods));
    }
    if (widget.docType == PurchaseDocType.receipt ||
        widget.docType == PurchaseDocType.returnDoc) {
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
    // 表头未选供应商 → 以上游单据供应商回填；结账方式未选时按上游单据结账方式
    // （收货/退货引入订货）或供应商默认（V452）预填。
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
      context.appError('请选择供应商');
      return;
    }
    if (_cfg.warehouseRequired && _warehouseId == null) {
      context.appError('请选择仓库');
      return;
    }
    if (_cfg.settlementRequired && _settlementMethodId == null) {
      setState(() => _settlementError = '请选择结账方式');
      context.appError('请选择结账方式');
      return;
    }
    double exchangeRate = 1;
    double taxRate = 0;
    if (_cfg.hasCurrency) {
      if (_currencyId == null) {
        context.appError('请选择币种');
        return;
      }
      final parsedRate = double.tryParse(_rate.text.trim());
      if (parsedRate == null || parsedRate <= 0) {
        context.appError('汇率必须大于 0');
        return;
      }
      final parsedTax = double.tryParse(_taxRate.text.trim());
      if (parsedTax == null || parsedTax < 0 || parsedTax > 100) {
        context.appError('税率必须填写 0 至 100 之间的百分比');
        return;
      }
      exchangeRate = parsedRate;
      taxRate = parsedTax;
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text) ?? 0;
      if (qty <= 0) {
        context.appError('${r.goods!.name} 的数量必须大于 0');
        return;
      }
      if (widget.docType != PurchaseDocType.receipt &&
          r.maxQty != null &&
          qty > r.maxQty! + 0.0000001) {
        context.appError('${r.goods!.name} 的数量不能超过上游剩余量 ${r.maxQty}');
        return;
      }
      final price = double.tryParse(r.price.text);
      final weightText = r.weight.text.trim();
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      if (weightText.isNotEmpty && (weight == null || weight <= 0)) {
        context.appError('${r.goods!.name} 的实际重量必须大于 0');
        return;
      }
      final remarkText = r.remark.text.trim();
      itemsBody.add({
        'goodsId': r.goods!.id,
        'qty': qty,
        if (price case final price?) ...{
          'price': price,
          'amountOriginal': qty * price,
          'amountLocal': qty * price * exchangeRate,
        },
        if (r.upstreamItemId != null) ..._linkItemKey(r.upstreamItemId!),
        // 来源单据编号谱系（到货登记=来源订货单号），与委外进仓口径一致。
        if (r.sourceDocNo?.isNotEmpty == true) 'sourceDocNo': r.sourceDocNo,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        if (r.unitRate != null) 'unitRate': r.unitRate,
        'weight': ?weight,
        if (remarkText.isNotEmpty) 'remark': remarkText,
      });
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      if (_cfg.hasSupplier && _supplierId != null) 'supplierId': _supplierId,
      if (_cfg.hasWarehouse && _warehouseId != null)
        'warehouseId': _warehouseId,
      if (_cfg.hasDepartment) 'departmentId': _departmentId,
      if (_cfg.hasCurrency && _currencyId != null) 'currencyId': _currencyId,
      if (_cfg.hasCurrency) 'exchangeRate': exchangeRate,
      if (_cfg.hasCurrency) 'taxRate': taxRate,
      if (_cfg.hasSettlement && _settlementMethodId != null)
        'settlementMethodId': _settlementMethodId,
      if (_cfg.hasApplicant && _applicantId != null)
        'applicantId': _applicantId,
      if (_cfg.hasPurchaser) 'purchaserId': _purchaserId,
      if (_cfg.hasSender && _senderId != null) 'senderId': _senderId,
      if (_cfg.hasReceiver && _receiverId != null) 'receiverId': _receiverId,
      if (_cfg.hasNeedDate && _needDate != null) 'needDate': _fmt(_needDate!),
      if (_cfg.hasDeliverDate && _deliverDate != null)
        'deliverDate': _fmt(_deliverDate!),
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(purchaseRepositoryProvider(widget.docType));
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(switch (widget.docType) {
        PurchaseDocType.order => '订货单已保存', // 防御分支：订货已走专属编辑页
        PurchaseDocType.receipt => '采购收货单已保存；下一步请在单据详情点击「审核」',
        PurchaseDocType.returnDoc => '采购退货单已保存；下一步请在单据详情点击「审核」',
        PurchaseDocType.request => widget.id == null ? '已创建' : '已保存',
      });
      bumpListRefresh(ref, _cfg.refreshKey);
      // 保存/更新成功后，指向本单据的通知对当前用户自动已读。
      unawaited(
        markNoticesReadByRoute(
          ProviderScope.containerOf(context, listen: false),
          [RoutePath.purchaseDocDetail(_cfg.type.pathSegment, d.id)],
        ),
      );
      context.replace(RoutePath.purchaseDocDetail(_cfg.type.pathSegment, d.id));
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 按 cfg 的链路开关把 upstreamItemId 映射到对应 key。
  /// 优先级与 doc_link_picker 的 _upstreamType 一致（收货 > 订货 > 申请），
  /// 保证 round-trip 一致：returnDoc（同时 linkToOrder/Receipt）走 receiptItemId。
  Map<String, dynamic> _linkItemKey(String upstreamItemId) {
    if (_cfg.linkToReceiptItem) return {'receiptItemId': upstreamItemId};
    if (_cfg.linkToOrderItem) return {'orderItemId': upstreamItemId};
    if (_cfg.linkToRequestItem) return {'requestItemId': upstreamItemId};
    return const {};
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 新建态 AppBar 右上角「草稿(N)」入口。
  ///
  /// 管理卡 skipListOnCreate 直达新建页，从 hub 打不开列表；本按钮是用户回到自己
  /// 草稿的唯一入口（点击进列表并预选草稿段）。编辑既有单据时不显示。
  List<Widget>? get _draftsAction {
    if (widget.id != null || !_cfg.skipListOnCreate) return null;
    final kind = _cfg.draftKind;
    if (kind == null) return null;
    return [UtenDraftsButton(kind: kind, listLocation: _cfg.listLocation)];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final List<ReferenceMethodOption> settlementMethods =
        ref.watch(settlementMethodOptionsProvider).valueOrNull ??
        const <ReferenceMethodOption>[];
    final settlementEntries = <String, String>{
      for (final method in settlementMethods)
        method.id: '${method.name}(${method.code})',
    };
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.purchase),
        ),
        actions: _draftsAction,
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
                    // 底部多留一个悬浮动作组的高度，否则明细表最后一行被「取消/保存」压住。
                    padding: const EdgeInsets.fromLTRB(
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      UtenSpacing.s12,
                      88,
                    ),
                    children: [
                      if (widget.docType == PurchaseDocType.receipt) ...[
                        _receiptArrivalBanner(theme),
                        const SizedBox(height: UtenSpacing.s12),
                      ],
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
                                    errorBuilder: utenTextFieldErrorBuilder,
                                    readOnly: true,
                                    controller: _billNo,
                                    decoration: UtenInputDecoration(
                                      InputDecoration(
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
                                  // 收货/退货：表头单一供应商（订货单行级条款已走专属页）。
                                  // 选商走右侧滑入面板（同销售订货单「客户」交互）：
                                  // 分类树+搜索+分页+可内联新建，仅列启用供应商。
                                  if (_cfg.hasSupplier)
                                    SupplierPickerField(
                                      initialId: _supplierId,
                                      initialName: _supplierHeaderName(),
                                      required: _cfg.supplierRequired,
                                      onChanged: (v) {
                                        setState(() => _supplierId = v);
                                        unawaited(
                                          _prefillSettlementForSupplier(
                                            v,
                                            null,
                                          ),
                                        );
                                      },
                                      onPick: () =>
                                          showUtenSupplierPicker(context, ref),
                                    ),
                                  if (_cfg.hasWarehouse)
                                    // 到货登记模式也不锁仓：入库仓库在收货时确定，
                                    // 预计到货任务可能不再携带仓库（订货单不带仓库）。
                                    // V476：仓库下拉带主/子层级（父仓置灰分组，单据落具体仓）。
                                    UtenDropdownField(
                                      label: '仓库',
                                      value: _warehouseId,
                                      required: _cfg.warehouseRequired,
                                      items: warehouseHierarchyItems(
                                        names.warehouseHierarchy,
                                        currentValue: _warehouseId,
                                      ),
                                      onChanged: (v) =>
                                          setState(() => _warehouseId = v),
                                    ),
                                  if (_cfg.hasDepartment)
                                    UtenDepartmentPicker(
                                      mode: UtenDepartmentPickerMode.single,
                                      label: '申请部门',
                                      initialSelection: _departmentId == null
                                          ? const []
                                          : [
                                              DeptSelection(
                                                id: _departmentId!,
                                                name: '',
                                                fullPath: '',
                                                level: '',
                                              ),
                                            ],
                                      onChanged: (selection) => setState(
                                        () => _departmentId = selection.isEmpty
                                            ? null
                                            : selection.first.id,
                                      ),
                                    ),
                                  if (_cfg.hasCurrency) ...[
                                    _dropdown(
                                      '币种',
                                      _currencyId,
                                      names.currencyEntries,
                                      (v) => setState(() => _currencyId = v),
                                      required: true,
                                    ),
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
                                  if (_cfg.hasSettlement)
                                    _dropdown(
                                      '结账方式',
                                      _settlementMethodId,
                                      settlementEntries,
                                      (value) => setState(() {
                                        _settlementMethodId = value;
                                        _settlementError = null;
                                      }),
                                      required: _cfg.settlementRequired,
                                      allowClear: !_cfg.settlementRequired,
                                      errorMessage: _settlementError,
                                    ),
                                  // 人员字段（按 config 显隐）
                                  if (_cfg.hasApplicant)
                                    _employeePicker(
                                      label: '申请人',
                                      currentId: _applicantId,
                                      onChanged: (id) =>
                                          setState(() => _applicantId = id),
                                    ),
                                  if (_cfg.hasPurchaser)
                                    _employeePicker(
                                      label: '采购员',
                                      currentId: _purchaserId,
                                      defaultDeptCode: kDeptCodePurchase,
                                      onChanged: (id) =>
                                          setState(() => _purchaserId = id),
                                    ),
                                  if (_cfg.hasSender)
                                    _employeePicker(
                                      label: '交货人',
                                      currentId: _senderId,
                                      onChanged: (id) =>
                                          setState(() => _senderId = id),
                                    ),
                                  if (_cfg.hasReceiver)
                                    _employeePicker(
                                      label: '收货人',
                                      currentId: _receiverId,
                                      onChanged: (id) =>
                                          setState(() => _receiverId = id),
                                    ),
                                  // 日期字段（按 config 显隐，统一 UtenDateField）
                                  if (_cfg.hasNeedDate)
                                    UtenDateField(
                                      label: '需求日期',
                                      value: _needDate,
                                      onChanged: (d) =>
                                          setState(() => _needDate = d),
                                    ),
                                  if (_cfg.hasDeliverDate)
                                    UtenDateField(
                                      label: '交货日期',
                                      value: _deliverDate,
                                      onChanged: (d) =>
                                          setState(() => _deliverDate = d),
                                    ),
                                ],
                              ),
                              const SizedBox(height: UtenSpacing.s12),
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
                      // 「明细 (N)」标题行 2026-09-11 撤除（全站同改）：只留右对齐引入入口。
                      Row(
                        children: [
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
                            purchaseDocGridColumnPrefsProvider,
                          )[widget.docType.name];
                          return UtenEditableGrid<PurchaseGridRow>(
                            controller: _grid,
                            showColumnSettings: true,
                            initialColumnOrder: columnPrefs?.order,
                            initialHiddenColumnKeys: columnPrefs?.hidden,
                            onColumnSettingsChanged: (order, hidden) => ref
                                .read(
                                  purchaseDocGridColumnPrefsProvider.notifier,
                                )
                                .updateFor(widget.docType.name, order, hidden),
                            columns: purchaseGridColumns(
                              _pickGoods,
                              context: context,
                              unitEntries: names.unitEntries,
                              // 收货/退货是实物出入库单据：显示库位号列（主档带出，上架/拣货指引）。
                              showStockPlace:
                                  widget.docType == PurchaseDocType.receipt ||
                                  widget.docType == PurchaseDocType.returnDoc,
                              // 每行末尾备注列（随行提交 remark）。
                              showRemark: true,
                            ),
                            createBlankRow: () => PurchaseGridRow(),
                            cloneRow: (r) => r.clone(),
                            // 合计条挂在明细表下方（原来挂在页面底部操作条里，
                            // 2026-09-11 底部条改右下角悬浮后合计跟着回到表尾）：
                            // 数量按单位分组绝不相加，金额币种取表头。
                            footer: EditableGridTotalsBar<PurchaseGridRow>(
                              key: const Key('purchase-edit-totals'),
                              controller: _grid,
                              showDivider: false,
                              watchOf: (row) => [row.qty],
                              entriesBuilder: (rows) => [
                                utenQuantityTotalEntry(
                                  rows
                                      .where((row) => row.goods != null)
                                      .map(
                                        (row) => MeasuredAmount(
                                          value:
                                              double.tryParse(
                                                row.qty.text.trim(),
                                              ) ??
                                              0,
                                          unitId: row.unitId,
                                          unitName:
                                              names.unitEntries[row.unitId],
                                        ),
                                      ),
                                ),
                                UtenTotalEntry(
                                  utenAmountTotalLabel(
                                    _cfg.hasCurrency
                                        ? financeCurrencyDisplayLabel(
                                            name: names.currency(_currencyId),
                                          )
                                        : null,
                                  ),
                                  _grid.totalListenable.value.toStringAsFixed(
                                    2,
                                  ),
                                  danger: true,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
      ),
      // 加载中不给保存入口（表单还没填回来，此时保存会把空值提交上去）。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _loading
          ? null
          : UtenEditFloatingActions(
              onCancel: () =>
                  popOrBackTo(context, defaultPath: RouteName.purchase),
              onSave: _save,
              saving: _saving,
              // 订货已走专属编辑页；本页三类单据统一「保存，下一步审核/保存」文案。
              saveLabel: purchaseSaveActionLabel(
                widget.docType,
                submitFinance: false,
              ),
            ),
    );
  }

  Widget _receiptArrivalBanner(ThemeData theme) {
    return Semantics(
      container: true,
      label:
          '请按实际到货数量登记；需要重量统计的货品同时填写实称总重量。'
          '超出财务批准剩余量时不会直接入库，'
          '系统会隔离并通知财务审核组审批。',
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
                      '请按实际到货数量和实称重量登记',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '请选择本次入库仓库，并按实际到货数量和实称重量登记。'
                      '如果实到数量超过财务批准剩余量，仍可如实填写。'
                      '超出部分不会入库、不会生成应付：保存后审核时系统会自动隔离，'
                      '并通知财务审核组审批——财务可批准实到数量进入后续流程，'
                      '或要求退货(生成供应商退货任务)。',
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
  }) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
      enabled: enabled,
      allowClear: allowClear,
      errorMessage: errorMessage,
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
