// 采购单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 差异由 config 驱动：供应商/币种/仓库下拉按 has* 显隐；
// 人员（申请人/采购员/交货人/收货人）按 has* 显隐 UtenEmployeePicker；
// 日期（单据/需求/交货）统一用 UtenDateField（outlined，与其它字段同款）；
// 「从上游引入」按 hasUpstreamLink 显隐（收货/退货/订货）。
//
// 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// 明细改 Excel 表：货品/数量/单价→金额自动 + 添加行/添加多行 + 行尾删除 + sticky 表头。
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
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../repositories/purchase_repository.dart';
import '../../basic_data/widgets/uten_supplier_picker.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/repositories/task_claim_repository.dart';
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
  const PurchaseDocEditPage({
    super.key,
    required this.docType,
    this.id,
    this.sourceRequestId,
    this.sourceRequestItemIds = const [],
    this.receiptPrefill,
  });
  final PurchaseDocType docType;
  final String? id; // null=新建
  final String? sourceRequestId;
  final List<String> sourceRequestItemIds;
  final ProcurementReceiptPrefill? receiptPrefill;

  @override
  ConsumerState<PurchaseDocEditPage> createState() =>
      _PurchaseDocEditPageState();
}

class _PurchaseDocEditPageState extends ConsumerState<PurchaseDocEditPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);

  bool get _canSubmitFinance => ref
      .read(currentPermissionsProvider)
      .contains(Perm.purchaseOrderSubmitFinance);
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
  // 采购分解订货的并发认领会话（PURCHASE_DECOMPOSE，按申请 id 认领；他人占用时禁用保存）。
  TaskClaimSession? _decomposeClaim;

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
    _decomposeClaim
        ?.releaseAll(); // 离开订货编辑页释放分解认领（fire-and-forget；session 自带 repo）
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
          if (last.items.isNotEmpty && last.items.first.warehouseId != null) {
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
    if (widget.id == null && widget.docType == PurchaseDocType.receipt) {
      await _prefillReceiptFromExpectation();
    }
    if (widget.id == null && widget.docType == PurchaseDocType.order) {
      await _prefillFromRequest();
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
          // 订货单一单一商：明细不落供应商 id，编辑回显按单头供应商回填各行。
          if (widget.docType == PurchaseDocType.order) {
            row.supplierId = d.supplierId;
          }
          row.qty.text = it.qty?.toString() ?? '';
          row.weight.text = it.weight?.toString() ?? '';
          row.price.text = it.price?.toString() ?? '';
          rows.add(row);
        }
        if (widget.docType == PurchaseDocType.receipt ||
            widget.docType == PurchaseDocType.returnDoc) {
          await _fillStockPlaces(rows);
        }
        // 「申请来源」列回显：编辑既有订货单按单头来源申请回填
        //（服务端仅在全单同源时给出；跨申请分解的旧单该列留空）。
        if (widget.docType == PurchaseDocType.order &&
            d.sourceRequestId != null) {
          for (final row in rows) {
            row
              ..sourceRequestId = d.sourceRequestId
              ..sourceRequestNo = d.sourceRequestNo;
          }
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

  Future<void> _prefillFromRequest() async {
    final selectedIds = widget.sourceRequestItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    // 卡片直达新建（无任务中心带入的申请行）：留空白单，由用户「从上游引入」拉取申请明细。
    if (selectedIds.isEmpty) return;
    try {
      final open = await ref
          .read(purchaseRepositoryProvider(PurchaseDocType.request))
          .decompositionPreview(selectedIds);
      if (open.isEmpty) {
        throw StateError('所选申请明细已全部分解，请返回任务中心刷新');
      }
      final goodsIds = open.map((item) => item.goodsId).toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      if (!mounted) return;
      final names = ref.read(masterNameServiceProvider);
      final rows = <PurchaseGridRow>[];
      for (final item in open) {
        final linked = LinkedItem(
          goodsId: item.goodsId,
          qty: item.remainingQty,
          maxQty: item.remainingQty,
          upstreamItemId: item.sourceItemId,
          colorId: item.colorId,
          unitId: item.unitId,
          unitRate: item.unitRate,
        );
        rows.add(
          PurchaseGridRow.fromLinked(
            linked,
            GoodsOption(id: item.goodsId, name: names.goods(item.goodsId)),
          ),
        );
      }
      if (rows.isEmpty) throw StateError('所选采购申请明细缺少有效物料');
      // 「申请来源」列自动回填：任务中心带单按申请行各自的来源单号/单据 id 填。
      for (var i = 0; i < rows.length && i < open.length; i++) {
        rows[i]
          ..sourceRequestNo = open[i].sourceDocumentNo
          ..sourceRequestId = open[i].sourceDocumentId;
      }
      _grid.replaceAll(rows);
      // 引入申请行后按「学习记忆」预填各货品上次订货的供应商，减少逐行手选。
      await _prefillRememberedSuppliers();
      final dates =
          open
              .map((line) => _parseDate(line.needDate))
              .whereType<DateTime>()
              .toList()
            ..sort();
      _deliverDate = dates.isEmpty ? null : dates.first;
      // 订货单不携带仓库（入库仓库到收货登记时再选），不预填申请行仓库。
      // 并发认领（PURCHASE_DECOMPOSE）：按所引入采购申请 id 认领，他人正在分解同一申请时禁用保存。
      // 仅 UX/防碰撞层；后端 decompositionPreview 守卫是正确性底线。认领失败 fail-open。
      final requestIds = open.map((e) => e.sourceDocumentId).toSet();
      if (requestIds.isNotEmpty) {
        _decomposeClaim = TaskClaimSession(
          ref.read(taskClaimRepositoryProvider),
        );
        await _decomposeClaim!.claimAll('PURCHASE_DECOMPOSE', requestIds);
        if (mounted) setState(() {});
      }
    } on StateError catch (error) {
      if (mounted) context.appError(error.message);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('读取采购申请失败，请返回任务中心重新选择');
    }
  }

  Future<void> _prefillReceiptFromExpectation() async {
    final prefill = widget.receiptPrefill;
    if (prefill == null) return;
    if (prefill.orderType != ProcurementInboundOrderType.purchase) {
      context.appError('预计到货来源与采购收货单不一致，请返回任务中心重试');
      return;
    }
    _supplierId = prefill.supplierId;
    _warehouseId = prefill.warehouseId;
    unawaited(_prefillSettlementForSupplier(prefill.supplierId, null));
    if (prefill.purchaserId?.isNotEmpty == true) {
      _purchaserId = prefill.purchaserId;
      await _preloadEmployees([prefill.purchaserId]);
    }
    final rows = <PurchaseGridRow>[];
    for (final item in prefill.items) {
      if (item.orderItemId.isEmpty ||
          item.goodsId.isEmpty ||
          item.approvedRemainingQty <= 0) {
        continue;
      }
      final row = PurchaseGridRow(sourceLocked: true)
        ..goods = GoodsOption(
          id: item.goodsId,
          code: item.goodsCode,
          name: item.goodsName,
        )
        ..upstreamItemId = item.orderItemId
        ..sourceDocNo = prefill.orderBillNo
        ..colorId = item.colorId
        ..unitId = item.unitId
        ..unitRate = item.unitRate.toDouble()
        ..approvedQty = item.approvedRemainingQty;
      // 预填批准剩余量但不设置 maxQty；仓库必须能如实填写超量实到数，
      // 是否隔离由服务端审核动作权威判定。
      row.qty.text = procurementQty(item.approvedRemainingQty);
      // 到货登记不录价：订货单价随行携带（价格列隐藏），服务端审核时权威重算金额。
      if (item.unitPrice != null) {
        row.price.text = procurementQty(item.unitPrice!);
      }
      rows.add(row);
    }
    if (rows.isNotEmpty) {
      await _fillStockPlaces(rows);
      _grid.replaceAll(rows);
    }
  }

  /// 预计到货「登记实际到货」模式：新建收货单且带任务中心预填。
  /// 标题/明细列/表单锁定都按到货登记场景呈现（只登记实到数量，不管价格）。
  bool get _isArrivalMode =>
      widget.id == null &&
      widget.docType == PurchaseDocType.receipt &&
      widget.receiptPrefill != null;

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
    // 订货单：换货品后按「学习记忆」预填该货品上次订货的供应商（不覆盖已选值）。
    if (widget.docType == PurchaseDocType.order) {
      await _prefillRememberedSuppliers();
    }
  }

  /// 行级供应商「学习预填」：按货品查最近一次订货用的供应商（服务端历史归集），
  /// 回填尚未选供应商的行。只回填启用中的供应商；失败静默（记忆是提效加分项）。
  Future<void> _prefillRememberedSuppliers() async {
    if (widget.docType != PurchaseDocType.order) return;
    final pending = _grid.rows
        .where((r) => r.goods != null && r.supplierId == null)
        .map((r) => r.goods!.id)
        .toSet();
    if (pending.isEmpty) return;
    try {
      final remembered = await ref
          .read(purchaseRepositoryProvider(PurchaseDocType.order))
          .lastSuppliersByGoods(pending);
      if (!mounted) return;
      final names = ref.read(masterNameServiceProvider);
      var changed = false;
      for (final r in _grid.rows) {
        final goodsId = r.goods?.id;
        if (goodsId == null || r.supplierId != null) continue;
        final sid = remembered[goodsId];
        if (sid != null && !names.isSupplierDisabled(sid)) {
          r.supplierId = sid;
          changed = true;
        }
      }
      if (changed) setState(() {});
    } catch (_) {
      // 学习预填失败静默：用户可逐行手选或勾选多行统一设置。
    }
  }

  /// 批量设供应商弹窗的「新增供应商」由供应商滑入面板内置（supplier:create 权限）。

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

  /// 多选行统一设供应商（订货单表头不录供应商，行级必填）：打开供应商滑入面板
  /// （分类树+搜索+可内联新建）选一个，把同一供应商填到所有选中行；
  /// 保存时后端按行供应商拆单归集。
  Future<void> _batchSetSuppliers() async {
    final rows = _grid.selectedRows;
    if (rows.isEmpty) return;
    final picked = await showUtenSupplierPicker(context, ref, title: '统一设置供应商');
    if (picked == null || !mounted) return;
    // 既有单据只持久化单头 supplierId，不能在编辑时制造多供应商行。
    final targets = widget.id == null ? rows : _grid.rows;
    for (final r in targets) {
      r.supplierId = picked.id;
    }
    setState(() {});
    unawaited(_prefillSettlementForSupplier(picked.id, null));
  }

  /// 行级供应商选择：打开供应商滑入面板，选中后按多选范围落值
  /// （勾选多行时任一选中行选的供应商联动填到所有选中行；否则只写本行）。
  Future<void> _pickRowSupplier(PurchaseGridRow row) async {
    final picked = await showUtenSupplierPicker(context, ref);
    if (picked == null || !mounted) return;
    _applyRowSupplier(row, picked.id);
  }

  /// 行级供应商选择落值：该行处于多选选中态时，在任一选中行选的供应商
  /// 会联动填到**所有**选中行；未勾选（或点的行不在选中集）则只写本行。
  void _applyRowSupplier(PurchaseGridRow row, String? value) {
    if (widget.id != null) {
      for (final r in _grid.rows) {
        r.supplierId = value;
      }
      context.appInfo('既有订货单保持一单一商，已同步全部明细行');
      setState(() {});
      return;
    }
    final selected = _grid.selectedRows;
    if (selected.contains(row)) {
      for (final r in selected) {
        r.supplierId = value;
      }
      if (selected.length > 1) {
        context.appSuccess('已为 ${selected.length} 行设置同一供应商');
      }
    } else {
      row.supplierId = value;
    }
    setState(() {});
  }

  /// 表头供应商展示名（启用商显名称；编辑旧单遇禁用商标注「已禁用」）。
  String? _supplierHeaderName() {
    final id = _supplierId;
    if (id == null || id.isEmpty) return null;
    final names = ref.read(masterNameServiceProvider);
    final name = names.supplierEntries[id];
    if (name == null || name.isEmpty) return id;
    return names.isSupplierDisabled(id) ? '$name（已禁用）' : name;
  }

  /// 供应商显示名映射：启用中的供应商（禁用商不显示，避免对其新下单）。
  /// 被 [referencedIds] 引用的禁用供应商（编辑旧单/上游预填）补进映射并标「已禁用」，
  /// 保证已选值仍能显示名称；供明细供应商单元格显示用。
  Map<String, String> _supplierDropdownEntries(
    Iterable<String?> referencedIds,
  ) {
    final names = ref.read(masterNameServiceProvider);
    final entries = {...names.supplierActiveEntries};
    for (final id in referencedIds) {
      if (id == null || id.isEmpty || entries.containsKey(id)) continue;
      final name = names.supplierEntries[id];
      if (name == null || name.isEmpty) continue;
      entries[id] = '$name（已禁用）';
    }
    return entries;
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
    // 「申请来源」列自动回填：本次引入所选上游单据（订货单上游=采购申请）的单号/id。
    if (widget.docType == PurchaseDocType.order) {
      for (final r in rows) {
        r
          ..sourceRequestId = result.sourceDocId
          ..sourceRequestNo = result.sourceDocNo;
      }
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
    // 引入行后按「学习记忆」预填各货品上次订货的供应商（订货单行级必填）。
    await _prefillRememberedSuppliers();
  }

  /// 「申请来源」列点击：跳来源采购申请详情（申请为计划下达的只读事实页）。
  void _openSourceRequest(PurchaseGridRow row) {
    final id = row.sourceRequestId;
    if (id == null || id.isEmpty) return;
    context.push(
      RoutePath.purchaseDocDetail(PurchaseDocType.request.pathSegment, id),
    );
  }

  Future<void> _save() async {
    final rows = _grid.rows;
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      context.appError('请至少添加一条明细');
      return;
    }
    if (_cfg.supplierRequired &&
        !_cfg.supplierOnRowOnly &&
        _supplierId == null) {
      context.appError('请选择供应商');
      return;
    }
    if (_cfg.supplierOnRowOnly) {
      // 订货单：供应商在明细行必填（表头不录），勾选多行可「统一设供应商」批量填。
      final missing = rows
          .where((r) => r.goods != null && r.supplierId == null)
          .toList();
      if (missing.isNotEmpty) {
        context.appError(
          '${missing.first.goods!.name} 等 ${missing.length} 行未选择供应商；'
          '可勾选多行后在任一行选择供应商统一填写',
        );
        return;
      }
      // 行供应商全部一致时同步表头（编辑旧单口径；新建按行拆单不用表头）。
      final rowSuppliers = rows
          .where((r) => r.goods != null)
          .map((r) => r.supplierId)
          .toSet();
      if (widget.id != null && rowSuppliers.length != 1) {
        context.appError('既有采购订货单必须保持全部明细为同一供应商');
        return;
      }
      if (rowSuppliers.length == 1) _supplierId = rowSuppliers.first;
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
      if (widget.docType == PurchaseDocType.order &&
          (price == null || price < 0)) {
        context.appError('请填写${r.goods!.name}的有效采购单价');
        return;
      }
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
        // 订货单：明细级供应商（为空时后端按表头供应商回落）；保存时按供应商拆单。
        if (widget.docType == PurchaseDocType.order && r.supplierId != null)
          'supplierId': r.supplierId,
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
      // 订货单新建：按供应商自动拆单（createBatch），逐张提交财务。
      if (widget.docType == PurchaseDocType.order && widget.id == null) {
        final created = await repo.createBatch(body);
        if (!mounted) return;
        String? financeError;
        if (_canSubmitFinance) {
          for (final createdDoc in created) {
            try {
              await repo.submitFinance(createdDoc.id);
            } on ApiException catch (e) {
              financeError ??= e.message;
            }
          }
        }
        if (!mounted) return;
        bumpListRefresh(ref, _cfg.refreshKey);
        if (financeError != null) {
          context.appWarning(
            '已生成 ${created.length} 张订货单，部分未提交财务审核组：$financeError。'
            '请进入对应订货详情重新提交。',
          );
        } else if (_canSubmitFinance) {
          context.appSuccess(
            created.length > 1
                ? '已按供应商拆分为 ${created.length} 张订货单并提交财务审核组；'
                      '下一步由财务在「订货审批任务中心」审核'
                : '订货单已保存并提交财务审核组；下一步由财务在「订货审批任务中心」审核',
          );
        } else {
          context.appSuccess(
            created.length > 1
                ? '已按供应商拆分并保存 ${created.length} 张订货单草稿；'
                      '下一步请由有权限的人员提交财务审核'
                : '订货单草稿已保存；下一步请由有权限的人员提交财务审核',
          );
        }
        if (created.length == 1) {
          context.replace(
            RoutePath.purchaseDocDetail(
              _cfg.type.pathSegment,
              created.first.id,
            ),
          );
        } else {
          context.go('/purchase/${_cfg.type.pathSegment}');
        }
        return;
      }
      var d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      if (widget.docType == PurchaseDocType.order && _canSubmitFinance) {
        try {
          d = await repo.submitFinance(d.id);
        } on ApiException catch (e) {
          if (!mounted) return;
          context.appWarning(
            '订货单已保存，但未能提交财务审核组：${e.message}。'
            '请在订货详情重新提交。',
          );
          bumpListRefresh(ref, _cfg.refreshKey);
          context.replace(
            RoutePath.purchaseDocDetail(_cfg.type.pathSegment, d.id),
          );
          return;
        }
      }
      if (!mounted) return;
      context.appSuccess(switch (widget.docType) {
        PurchaseDocType.order when _canSubmitFinance =>
          '订货单已保存并提交财务审核组；下一步由财务在「订货审批任务中心」审核',
        PurchaseDocType.order => '订货单草稿已保存；下一步请由有权限的人员提交财务审核',
        PurchaseDocType.receipt => '采购收货单已保存；下一步请在单据详情点击「审核」',
        PurchaseDocType.returnDoc => '采购退货单已保存；下一步请在单据详情点击「审核」',
        PurchaseDocType.request => widget.id == null ? '已创建' : '已保存',
      });
      bumpListRefresh(ref, _cfg.refreshKey);
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
        title: _isArrivalMode
            ? '登记实际到货 · ${_cfg.label}'
            : widget.id == null
            ? '新建${_cfg.label}'
            : '编辑${_cfg.label}',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.purchase),
        ),
        actions: _cfg.skipListOnCreate
            ? [
                UtenButton(
                  type: UtenButtonType.tonal,
                  icon: Icons.history_rounded,
                  onPressed: () =>
                      context.push('/purchase/${_cfg.type.pathSegment}'),
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
                                  // 订货单：供应商改在明细行逐行必选（表头不显示），
                                  // 保存按行供应商拆单归集；收货/退货仍走表头。
                                  // 选商走右侧滑入面板（同销售订货单「客户」交互）：
                                  // 分类树+搜索+分页+可内联新建，仅列启用供应商。
                                  if (_cfg.hasSupplier &&
                                      !_cfg.supplierOnRowOnly)
                                    SupplierPickerField(
                                      initialId: _supplierId,
                                      initialName: _supplierHeaderName(),
                                      required: _cfg.supplierRequired,
                                      // 到货登记模式：供应商来自预计到货任务，锁定防手滑改坏来源关联。
                                      enabled: !_isArrivalMode,
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
                                    _dropdown(
                                      '仓库',
                                      _warehouseId,
                                      names.warehouseEntries,
                                      (v) => setState(() => _warehouseId = v),
                                      required: _cfg.warehouseRequired,
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
                      // 并发认领被占用的提示独立常驻（引入总结横幅已由明细
                      // 「申请来源」列取代：来源单号逐行展示、可点跳申请详情）。
                      if (_decomposeClaim?.blocked ?? false)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: UtenSpacing.s8,
                            bottom: UtenSpacing.s4,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lock_outline,
                                size: 18,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(width: UtenSpacing.s8),
                              Expanded(
                                child: Text(
                                  '${_decomposeClaim?.blockedByName ?? '同事'}'
                                  '正在分解此采购申请，保存已禁用，请稍后再试',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
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
                          if (_cfg.hasUpstreamLink &&
                              // 到货登记模式：明细只能来自该预计到货任务，不允许再引入。
                              !_isArrivalMode)
                            UtenImportButton(
                              label: '从上游引入',
                              onPressed: _importFromUpstream,
                            ),
                        ],
                      ),
                      UtenEditableGrid<PurchaseGridRow>(
                        controller: _grid,
                        // 订货单多选行批量操作：统一设供应商（可内联新建供应商）。
                        batchActionsBuilder:
                            widget.docType == PurchaseDocType.order
                            ? (ctx, ctl) => [
                                TextButton.icon(
                                  onPressed: ctl.selectedCount > 0
                                      ? _batchSetSuppliers
                                      : null,
                                  icon: const Icon(
                                    Icons.local_shipping_outlined,
                                    size: 16,
                                  ),
                                  label: Text('统一设供应商 (${ctl.selectedCount})'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Theme.of(
                                      ctx,
                                    ).colorScheme.primary,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 2,
                                    ),
                                    minimumSize: const Size(0, 36),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    textStyle: Theme.of(
                                      ctx,
                                    ).textTheme.titleSmall,
                                  ),
                                ),
                              ]
                            : null,
                        columns: purchaseGridColumns(
                          _pickGoods,
                          arrivalMode: _isArrivalMode,
                          unitEntries: names.unitEntries,
                          // 收货/退货是实物出入库单据：显示库位号列（主档带出，上架/拣货指引）。
                          showStockPlace:
                              widget.docType == PurchaseDocType.receipt ||
                              widget.docType == PurchaseDocType.returnDoc,
                          // 订货单：明细可逐行选供应商，保存时按供应商自动拆单。
                          // 选项与表头同口径：只列启用供应商（行内已引用的禁用商补显）。
                          supplierEntries:
                              widget.docType == PurchaseDocType.order
                              ? _supplierDropdownEntries([
                                  _supplierId,
                                  for (final r in _grid.rows) r.supplierId,
                                ])
                              : const {},
                          // 订货单表头不录供应商：行级必选（列头红 * + 空值红字提示）。
                          supplierRequired:
                              widget.docType == PurchaseDocType.order,
                          headerSupplierId:
                              widget.docType == PurchaseDocType.order
                              ? _supplierId
                              : null,
                          // 行内点选供应商 → 滑入面板（页面按多选范围落值联动）。
                          onPickSupplier: _pickRowSupplier,
                          // 订货单：「申请来源」列——引入行自动回填来源申请单号，点击跳申请详情。
                          showSource: widget.docType == PurchaseDocType.order,
                          onOpenSource: _openSourceRequest,
                        ),
                        createBlankRow: () => PurchaseGridRow(),
                        // 到货登记模式：行来自预计到货任务（带订货明细关联），
                        // 不允许添加无来源行；行尾删除保留（部分到货=该行本次不收）。
                        showAddRow: !_isArrivalMode,
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
              ValueListenableBuilder<double>(
                valueListenable: _grid.totalListenable,
                builder: (_, total, _) => Text(
                  '合计 ¥${total.toStringAsFixed(2)}',
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
              UtenButton(
                isLoading: _saving,
                icon:
                    widget.docType == PurchaseDocType.order && _canSubmitFinance
                    ? Icons.send_outlined
                    : Icons.save_outlined,
                onPressed: (_saving || (_decomposeClaim?.blocked ?? false))
                    ? null
                    : _save,
                child: Text(
                  purchaseSaveActionLabel(
                    widget.docType,
                    submitFinance: _canSubmitFinance,
                  ),
                ),
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
                    if (source?.isNotEmpty == true) ...[
                      const SizedBox(height: UtenSpacing.s4),
                      // 来源订货单：编号可点跳订货详情（展示编号而非 id；
                      // 任务不带权威 id 时退化为纯文本谱系）。
                      InkWell(
                        onTap: sourceOrderId == null
                            ? null
                            : () => context.push(
                                RoutePath.purchaseDocDetail(
                                  PurchaseDocType.order.pathSegment,
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
