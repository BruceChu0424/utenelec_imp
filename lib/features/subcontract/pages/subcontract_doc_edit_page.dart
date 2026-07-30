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
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/master_name_provider.dart'
    show GoodsOption;
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';
import '../repositories/subcontract_repository.dart';
import '../widgets/subcontract_grid_columns.dart';
import '../widgets/subcontract_link_picker.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;

class SubcontractDocEditPage extends ConsumerStatefulWidget {
  const SubcontractDocEditPage({super.key, required this.docType, this.id});
  final SubcontractDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<SubcontractDocEditPage> createState() =>
      _SubcontractDocEditPageState();
}

/// 结帐方式字典（源老库 B_PStyle，与后端 SubcontractSettlementStyle 对齐）。
const Map<int, String> kSubcontractSettlementStyles = {
  1: '现金',
  2: '提货',
  3: '代付',
  4: '支票',
  6: '月结',
  7: '垫付',
  8: '汇款',
  10: '代收',
};

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
  DateTime _billDate = DateTime.now();

  // 结帐方式（进仓/退货；B_PStyle 字典码）
  int? _settlementStyle;

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
        _purchaserId = d.purchaserId;
        _senderId = d.senderId;
        _workerId = d.workerId;
        _deliverDate = _parseDate(d.deliverDate);
        _lastDate = _parseDate(d.lastDate);
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        final rows = <SubcontractGridRow>[];
        for (final it in d.items) {
          final row = SubcontractGridRow()
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
            // 优先级与 _linkItemKey 一致（receipt > materialIssue > order > application）
            ..upstreamItemId =
                it.receiptItemId ??
                it.materialIssueItemId ??
                it.orderItemId ??
                it.applicationItemId
            ..colorId = it.colorId
            ..unitId = it.unitId;
          row.endingQty.text = it.endingQty?.toString() ?? '';
          row.standardQty.text = it.standardQty?.toString() ?? '';
          row.wasteRate.text = it.wasteRate?.toString() ?? '';
          row.cause.text = it.cause ?? '';
          row.girth.text = it.girthQty?.toString() ?? '';
          row.boxQty.text = it.boxQty?.toString() ?? '';
          rows.add(row);
        }
        _grid.replaceAll(rows);
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_grid.isEmpty) _grid.addRow(SubcontractGridRow());
    if (mounted) setState(() => _loading = false);
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

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

  Future<void> _pickGoods(SubcontractGridRow row) async {
    final g = await showUtenGoodsPicker(context, ref);
    if (g == null) return;
    final names = ref.read(mn.masterNameServiceProvider);
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      ..colorId = names.colorIdByLegacy(g.colorLegacyId)
      ..unitId = names.unitIdByLegacy(g.unitLegacyId);
  }

  /// 「从上游引入」：弹选择器，把所选 LinkedItem 映射成行追加。
  Future<void> _importFromUpstream() async {
    final picked = await showSubcontractLinkPicker(context, ref, _cfg);
    if (picked == null || picked.isEmpty) return;
    final goodsIds = picked
        .map((e) => e.goodsId)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    final rows = <SubcontractGridRow>[];
    for (final li in picked) {
      if (li.goodsId.isEmpty) continue;
      final goods = GoodsOption(
        id: li.goodsId,
        name: ref.read(mn.masterNameServiceProvider).goods(li.goodsId),
      );
      rows.add(SubcontractGridRow.fromLinked(li, goods));
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
      final price = double.tryParse(r.price.text);
      final w = double.tryParse(r.weight.text);
      final ending = double.tryParse(r.endingQty.text);
      final std = double.tryParse(r.standardQty.text);
      final wr = double.tryParse(r.wasteRate.text);
      final line = <String, dynamic>{
        'goodsId': r.goods!.id,
        'qty': qty,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
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
      };
      itemsBody.add(line);
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      if (_cfg.hasSupplier && _supplierId != null) 'supplierId': _supplierId,
      if (_warehouseId != null) 'warehouseId': _warehouseId,
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
      if (_cfg.hasSettlement) 'settlementStyleLegacy': _settlementStyle,
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(subcontractRepositoryProvider(widget.docType));
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
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
    if (_cfg.linkToApplicationItem)
      return {'applicationItemId': upstreamItemId};
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
                      UtenEditableGrid<SubcontractGridRow>(
                        controller: _grid,
                        columns: subcontractGridColumns(_pickGoods, _cfg),
                        createBlankRow: () => SubcontractGridRow(),
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

  Widget _headerCard(ThemeData theme) {
    final names = ref.watch(mn.masterNameServiceProvider);
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
                  ),
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
                  DropdownButtonFormField<int?>(
                    initialValue: _settlementStyle,
                    decoration: const InputDecoration(labelText: '结帐方式'),
                    items: [
                      const DropdownMenuItem<int?>(child: Text('— 不选 —')),
                      for (final e in kSubcontractSettlementStyles.entries)
                        DropdownMenuItem<int?>(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      if (_settlementStyle != null &&
                          !kSubcontractSettlementStyles.containsKey(
                            _settlementStyle,
                          ))
                        DropdownMenuItem<int?>(
                          value: _settlementStyle,
                          child: Text('$_settlementStyle'),
                        ),
                    ],
                    onChanged: (v) => setState(() => _settlementStyle = v),
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

  Widget _dropdown(
    String label,
    String? value,
    Map<String, String> entries,
    ValueChanged<String?> onChanged, {
    bool required = false,
  }) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
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
