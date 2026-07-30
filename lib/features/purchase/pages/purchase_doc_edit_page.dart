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
import '../../employee/repositories/employee_repository.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../providers/master_name_provider.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../repositories/purchase_repository.dart';
import '../widgets/doc_link_picker.dart';
import '../widgets/purchase_grid_columns.dart';

class PurchaseDocEditPage extends ConsumerStatefulWidget {
  const PurchaseDocEditPage({super.key, required this.docType, this.id});
  final PurchaseDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<PurchaseDocEditPage> createState() => _PurchaseDocEditPageState();
}

class _PurchaseDocEditPageState extends ConsumerState<PurchaseDocEditPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  DateTime _billDate = DateTime.now();
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
    if (widget.id != null) {
      try {
        final d = await ref
            .read(purchaseRepositoryProvider(widget.docType))
            .detail(widget.id!);
        final goodsIds = d.items.map((e) => e.goodsId).whereType<String>().toSet();
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
          final row = PurchaseGridRow()
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(masterNameServiceProvider).goods(it.goodsId))
            // 优先级与 _linkItemKey 一致（receipt > order > request），保证 round-trip。
            ..upstreamItemId = it.receiptItemId ?? it.orderItemId ?? it.requestItemId
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

  /// 并发按 id 拉 4 个人员字段的名字（picker 的 initial 显示用）。失败静默。
  Future<void> _preloadEmployees(Iterable<String?> ids) async {
    final uniq = ids.whereType<String>().where((id) => id.isNotEmpty).toSet();
    if (uniq.isEmpty) return;
    final repo = ref.read(employeeRepositoryProvider);
    await Future.wait(uniq.map((id) async {
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
    }));
  }

  Future<void> _pickGoods(PurchaseGridRow row) async {
    final g = await showUtenGoodsPicker(context, ref);
    if (g == null) return;
    final names = ref.read(masterNameServiceProvider);
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      ..colorId = names.colorIdByLegacy(g.colorLegacyId)
      ..unitId = names.unitIdByLegacy(g.unitLegacyId);
  }

  /// 「从上游引入」：弹选择器，把所选 LinkedItem 映射成行追加。
  Future<void> _importFromUpstream() async {
    final picked = await showDocLinkPicker(context, ref, _cfg);
    if (picked == null || picked.isEmpty) return;
    final goodsIds = picked.map((e) => e.goodsId).where((id) => id.isNotEmpty).toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    final rows = <PurchaseGridRow>[];
    for (final li in picked) {
      if (li.goodsId.isEmpty) continue;
      final goods = GoodsOption(
        id: li.goodsId,
        name: ref.read(masterNameServiceProvider).goods(li.goodsId),
      );
      rows.add(PurchaseGridRow.fromLinked(li, goods));
    }
    _grid.addRows(rows);
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
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text) ?? 0;
      final price = double.tryParse(r.price.text);
      itemsBody.add({
        'goodsId': r.goods!.id,
        'qty': qty,
        if (price != null) 'price': price,
        if (price != null) 'amountOriginal': qty * price,
        if (price != null) 'amountLocal': qty * price,
        if (r.upstreamItemId != null) ..._linkItemKey(r.upstreamItemId!),
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
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
      if (_cfg.hasApplicant && _applicantId != null) 'applicantId': _applicantId,
      if (_cfg.hasPurchaser && _purchaserId != null) 'purchaserId': _purchaserId,
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
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
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
          title: widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}',
          showBackButton: true,
          actions: _cfg.skipListOnCreate
              ? [
                  UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.history_rounded,
                    onPressed: () => context.push('/purchase/${_cfg.type.pathSegment}'),
                    child: const Text('查看历史'),
                  ),
                ]
              : null),
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
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            UtenFormGrid(children: [
                              // 单据号：系统自动生成，只读显示。
                              TextFormField(
                                readOnly: true,
                                controller: _billNo,
                                decoration: InputDecoration(
                                  labelText: '单据号',
                                  hintText:
                                      _billNo.text.isEmpty ? '保存后自动生成' : null,
                                  filled: _billNo.text.isEmpty,
                                  suffixIcon: _billNo.text.isEmpty
                                      ? const Icon(Icons.autorenew_outlined, size: 18)
                                      : const Icon(Icons.lock_outline, size: 16),
                                ),
                              ),
                              // 制单员/制单时间：服务端权威，只读展示（责任制）。
                              ...utenMakerAuditCells(ref,
                                  makerName: _makerName, createdAt: _createdAt),
                              UtenDateField(
                                label: '单据日期',
                                required: true,
                                value: _billDate,
                                onChanged: (d) => setState(() => _billDate = d),
                              ),
                              if (_cfg.hasSupplier)
                                _dropdown('供应商', _supplierId, names.supplierEntries,
                                    (v) => setState(() => _supplierId = v),
                                    required: _cfg.supplierRequired),
                              _dropdown('仓库', _warehouseId, names.warehouseEntries,
                                  (v) => setState(() => _warehouseId = v)),
                              if (_cfg.hasCurrency) ...[
                                _dropdown('币种', _currencyId, names.currencyEntries,
                                    (v) => setState(() => _currencyId = v)),
                                TextField(
                                  controller: _rate,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: '汇率'),
                                ),
                              ],
                              // 人员字段（按 config 显隐）
                              if (_cfg.hasApplicant)
                                _employeePicker(
                                  label: '申请人',
                                  currentId: _applicantId,
                                  onChanged: (id) => setState(() => _applicantId = id),
                                ),
                              if (_cfg.hasPurchaser)
                                _employeePicker(
                                  label: '采购员',
                                  currentId: _purchaserId,
                                  onChanged: (id) => setState(() => _purchaserId = id),
                                ),
                              if (_cfg.hasSender)
                                _employeePicker(
                                  label: '交货人',
                                  currentId: _senderId,
                                  onChanged: (id) => setState(() => _senderId = id),
                                ),
                              if (_cfg.hasReceiver)
                                _employeePicker(
                                  label: '收货人',
                                  currentId: _receiverId,
                                  onChanged: (id) => setState(() => _receiverId = id),
                                ),
                              // 日期字段（按 config 显隐，统一 UtenDateField）
                              if (_cfg.hasNeedDate)
                                UtenDateField(
                                  label: '需求日期',
                                  value: _needDate,
                                  onChanged: (d) => setState(() => _needDate = d),
                                ),
                              if (_cfg.hasDeliverDate)
                                UtenDateField(
                                  label: '交货日期',
                                  value: _deliverDate,
                                  onChanged: (d) => setState(() => _deliverDate = d),
                                ),
                            ]),
                            const SizedBox(height: UtenSpacing.s12),
                            TextField(
                              controller: _remark,
                              decoration: const InputDecoration(labelText: '备注'),
                              maxLines: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    Row(
                      children: [
                        Text('明细 (${_grid.length})',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        if (_cfg.hasUpstreamLink)
                          UtenImportButton(
                            label: '从上游引入',
                            onPressed: _importFromUpstream,
                          ),
                      ],
                    ),
                    UtenEditableGrid<PurchaseGridRow>(
                      controller: _grid,
                      columns: purchaseGridColumns(_pickGoods),
                      createBlankRow: () => PurchaseGridRow(),
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
            border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: _grid.totalListenable,
                builder: (_, total, _) => Text(
                  '合计 ¥${total.toStringAsFixed(2)}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
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

  /// 人员选择器：用 EmployeeRepository.list 模糊搜索作为 loader，按 id 取缓存作为 initial。
  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
  }) {
    return UtenEmployeePicker(
      key: ValueKey('${label}_$currentId'),
      label: label,
      initial: currentId == null ? null : _empCache[currentId],
      loader: (kw) async {
        final res = await ref
            .read(employeeRepositoryProvider)
            .list(size: 30, search: kw);
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

  Widget _dropdown(String label, String? value, Map<String, String> entries,
      ValueChanged<String?> onChanged,
      {bool required = false}) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
      items: [
        for (final e in entries.entries) UtenDropdownItem(value: e.key, label: e.value),
        if (value != null && value.isNotEmpty && !entries.containsKey(value))
          UtenDropdownItem(value: value, label: value),
      ],
      onChanged: onChanged,
    );
  }
}
