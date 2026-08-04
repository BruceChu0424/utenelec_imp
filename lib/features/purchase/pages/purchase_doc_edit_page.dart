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
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../repositories/purchase_repository.dart';
import '../widgets/doc_link_picker.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import '../widgets/purchase_grid_columns.dart';

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
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  DateTime _billDate = ChinaDateTime.today();
  String? _supplierId;
  String? _warehouseId;
  String? _currencyId;

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
  String? _sourceRequestBillNo;

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
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    if (widget.id == null) {
      // 仓库预填「本类型最近一张单的仓库」（与销售 D1 同款），减少手选。
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
      _prefillReceiptFromExpectation();
    }
    if (widget.id == null && widget.docType == PurchaseDocType.order) {
      await _prefillFromRequest();
    }
    if (widget.id != null) {
      try {
        final d = await ref
            .read(purchaseRepositoryProvider(widget.docType))
            .detail(widget.id!);
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
        _currencyId = d.currencyId;
        _rate.text = d.exchangeRate?.toString() ?? '1';
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
            ..unitId = it.unitId;
          row.qty.text = it.qty?.toString() ?? '';
          row.price.text = it.price?.toString() ?? '';
          rows.add(row);
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
        );
        rows.add(
          PurchaseGridRow.fromLinked(
            linked,
            GoodsOption(id: item.goodsId, name: names.goods(item.goodsId)),
          ),
        );
      }
      if (rows.isEmpty) throw StateError('所选采购申请明细缺少有效物料');
      _grid.replaceAll(rows);
      final dates =
          open
              .map((line) => _parseDate(line.needDate))
              .whereType<DateTime>()
              .toList()
            ..sort();
      _deliverDate = dates.isEmpty ? null : dates.first;
      final warehouses = open
          .map((line) => line.warehouseId)
          .whereType<String>()
          .toSet();
      if (warehouses.length == 1) _warehouseId = warehouses.single;
      _sourceRequestBillNo = open
          .map((line) => line.sourceDocumentNo)
          .where((number) => number.isNotEmpty)
          .toSet()
          .join('、');
    } on StateError catch (error) {
      if (mounted) context.appError(error.message);
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message);
    } catch (_) {
      if (mounted) context.appError('读取采购申请失败，请返回任务中心重新选择');
    }
  }

  void _prefillReceiptFromExpectation() {
    final prefill = widget.receiptPrefill;
    if (prefill == null) return;
    if (prefill.orderType != ProcurementInboundOrderType.purchase) {
      context.appError('预计到货来源与采购收货单不一致，请返回任务中心重试');
      return;
    }
    _supplierId = prefill.supplierId;
    _warehouseId = prefill.warehouseId;
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
        ..colorId = item.colorId
        ..unitId = item.unitId
        ..approvedQty = item.approvedRemainingQty;
      // 预填批准剩余量但不设置 maxQty；仓库必须能如实填写超量实到数，
      // 是否隔离由服务端审核动作权威判定。
      row.qty.text = procurementQty(item.approvedRemainingQty);
      rows.add(row);
    }
    if (rows.isNotEmpty) _grid.replaceAll(rows);
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
    final names = ref.read(masterNameServiceProvider);
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      ..colorId = names.colorIdByLegacy(g.colorLegacyId)
      ..unitId = names.unitIdByLegacy(g.unitLegacyId);
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
    _grid.addRows(rows);
    // 表头未选供应商 → 以上游单据供应商回填。
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
      context.appError('请选择供应商');
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
      if (widget.docType != PurchaseDocType.receipt &&
          r.maxQty != null &&
          qty > r.maxQty! + 0.0000001) {
        context.appError('${r.goods!.name} 的数量不能超过上游剩余量 ${r.maxQty}');
        return;
      }
      final price = double.tryParse(r.price.text);
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
          'amountLocal': qty * price,
        },
        if (r.upstreamItemId != null) ..._linkItemKey(r.upstreamItemId!),
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
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
      if (_warehouseId != null) 'warehouseId': _warehouseId,
      if (_cfg.hasCurrency && _currencyId != null) 'currencyId': _currencyId,
      if (_cfg.hasCurrency) 'exchangeRate': double.tryParse(_rate.text) ?? 1,
      if (_cfg.hasApplicant && _applicantId != null)
        'applicantId': _applicantId,
      if (_cfg.hasPurchaser && _purchaserId != null)
        'purchaserId': _purchaserId,
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
          context.appWarning('已生成 ${created.length} 张订货单，部分未提交财务：$financeError');
        } else {
          context.appSuccess(
            created.length > 1
                ? '已按供应商拆分为 ${created.length} 张订货单并提交财务'
                : '订货单已提交财务审核',
          );
        }
        if (created.length == 1) {
          context.replace(
            RoutePath.purchaseDocDetail(_cfg.type.pathSegment, created.first.id),
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
      if (widget.docType == PurchaseDocType.order) {
        try {
          d = await repo.submitFinance(d.id);
        } on ApiException catch (e) {
          if (!mounted) return;
          context.appWarning('订货单已保存，但未能提交财务：${e.message}');
          bumpListRefresh(ref, _cfg.refreshKey);
          context.replace(
            RoutePath.purchaseDocDetail(_cfg.type.pathSegment, d.id),
          );
          return;
        }
      }
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
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
                                  if (_cfg.hasSupplier)
                                    _dropdown(
                                      '供应商',
                                      _supplierId,
                                      names.supplierEntries,
                                      (v) => setState(() => _supplierId = v),
                                      required: _cfg.supplierRequired,
                                      // 到货登记模式：供应商来自预计到货任务，锁定防手滑改坏来源关联。
                                      enabled: !_isArrivalMode,
                                    ),
                                  _dropdown(
                                    '仓库',
                                    _warehouseId,
                                    names.warehouseEntries,
                                    (v) => setState(() => _warehouseId = v),
                                    required: _cfg.warehouseRequired,
                                    // 到货登记模式：入库仓库由任务指定，锁定。
                                    enabled: !_isArrivalMode,
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
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      decoration: const InputDecoration(
                                        labelText: '汇率',
                                      ),
                                    ),
                                  ],
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
                      if (_sourceRequestBillNo != null) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        Container(
                          padding: const EdgeInsets.all(UtenSpacing.s8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: .35),
                            borderRadius: UtenRadius.smAll,
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(
                                alpha: .35,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.link_rounded, size: 18),
                              const SizedBox(width: UtenSpacing.s8),
                              Expanded(
                                child: Text(
                                  '已从采购申请 $_sourceRequestBillNo 引入 ${_grid.length} 行；'
                                  '请补充供应商、交货日期和价格后提交财务审核。',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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
                        columns: purchaseGridColumns(
                          _pickGoods,
                          arrivalMode: _isArrivalMode,
                          // 订货单：明细可逐行选供应商，保存时按供应商自动拆单。
                          supplierEntries:
                              widget.docType == PurchaseDocType.order
                              ? names.supplierEntries
                              : const {},
                          headerSupplierId:
                              widget.docType == PurchaseDocType.order
                              ? _supplierId
                              : null,
                          onSupplierChanged: (_) => setState(() {}),
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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
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
              const SizedBox(width: UtenSpacing.s16),
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => context.pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: UtenSpacing.s12),
              UtenButton(
                isLoading: _saving,
                icon: widget.docType == PurchaseDocType.order
                    ? Icons.send_outlined
                    : Icons.save_outlined,
                onPressed: _saving ? null : _save,
                child: Text(
                  widget.docType == PurchaseDocType.order ? '保存并提交财务' : '保存',
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
    return Semantics(
      container: true,
      label: '请按实际到货数量登记。超出财务批准剩余量时不会直接入库，'
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
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '${source == null ? '' : '来源订货单：$source。'}'
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
