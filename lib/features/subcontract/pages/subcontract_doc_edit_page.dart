// 委外单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细行编辑器 + 保存。
//
// 差异由 SubcontractDocConfig 驱动：
//  - 委外商(supplier)/仓库/币种+汇率/税率 下拉按 has* / *Required 显隐；
//  - 人员（采购员/交货人/经办人）按 hasPurchaser/hasSender/hasWorker 显隐 UtenEmployeePicker；
//  - 日期（交货日/lastDate）按 hasDeliverDate/hasLastDate 显隐；
//  - 材料退的 bStyle(int)、损耗的 totalWeight 按 hasBStyle/hasTotalWeight 显隐；
//  - 「从上游引入」按 hasUpstreamLink 显隐（订货→申请；进仓→订货；退货→进仓/订货；
//    发料→订货；材料退→发料/订货；损耗→发料）。
//  - 明细行：货品(复用采购 goods_picker_dialog)；数量；单价(仅 itemHasPrice)；金额自动；
//    重量(itemHasWeight)；损耗特有 ending/standard/waste_rate/cause(itemHasWasteFields)。
//    发料/材料退的 parent 父件字段本期不维护（可选，留空）。
// 保存组装 body 调 create/update，成功后跳详情。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../features/purchase/providers/master_name_provider.dart'
    show GoodsOption;
import '../../employee/repositories/employee_repository.dart';
import '../../purchase/widgets/goods_picker_dialog.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';
import '../repositories/subcontract_repository.dart';
import '../widgets/subcontract_link_picker.dart';
import '../../../features/purchase/providers/master_name_provider.dart'
    as mn;

class SubcontractDocEditPage extends ConsumerStatefulWidget {
  const SubcontractDocEditPage({super.key, required this.docType, this.id});
  final SubcontractDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<SubcontractDocEditPage> createState() =>
      _SubcontractDocEditPageState();
}

class _ItemRow {
  _ItemRow();
  GoodsOption? goods;
  final qty = TextEditingController();
  final price = TextEditingController();
  final weight = TextEditingController();
  // 损耗特有
  final endingQty = TextEditingController();
  final standardQty = TextEditingController();
  final wasteRate = TextEditingController();
  final cause = TextEditingController();
  /// 上游明细 id（引入时回填，保存时按 cfg 映射为对应 *ItemId）。
  String? upstreamItemId;
  String? colorId;
  String? unitId;

  factory _ItemRow.fromLinked(LinkedItem li, GoodsOption goods) {
    final r = _ItemRow()
      ..goods = goods
      ..upstreamItemId = li.upstreamItemId
      ..colorId = li.colorId
      ..unitId = li.unitId;
    r.qty.text = li.qty.toString();
    if (li.price != null) r.price.text = li.price.toString();
    return r;
  }

  void dispose() {
    qty.dispose();
    price.dispose();
    weight.dispose();
    endingQty.dispose();
    standardQty.dispose();
    wasteRate.dispose();
    cause.dispose();
  }
}

class _SubcontractDocEditPageState
    extends ConsumerState<SubcontractDocEditPage> {
  SubcontractDocConfig get _cfg => SubcontractDocConfig.by(widget.docType);
  final _billNo = TextEditingController();
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _taxRate = TextEditingController();
  final _bStyle = TextEditingController();
  final _totalWeight = TextEditingController();
  DateTime _billDate = DateTime.now();

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

  final _items = <_ItemRow>[];
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
    for (final r in _items) {
      r.dispose();
    }
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
        final goodsIds =
            d.items.map((e) => e.goodsId).whereType<String>().toSet();
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
        _purchaserId = d.purchaserId;
        _senderId = d.senderId;
        _workerId = d.workerId;
        _deliverDate = _parseDate(d.deliverDate);
        _lastDate = _parseDate(d.lastDate);
        for (final it in d.items) {
          final row = _ItemRow()
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(mn.masterNameServiceProvider).goods(it.goodsId))
            ..qty.text = it.qty?.toString() ?? ''
            ..price.text = it.price?.toString() ?? ''
            ..weight.text = it.weight?.toString() ?? ''
            // 优先级与 _linkItemKey 一致（receipt > materialIssue > order > application）
            ..upstreamItemId = it.receiptItemId ??
                it.materialIssueItemId ??
                it.orderItemId ??
                it.applicationItemId
            ..colorId = it.colorId
            ..unitId = it.unitId;
          row.endingQty.text = it.endingQty?.toString() ?? '';
          row.standardQty.text = it.standardQty?.toString() ?? '';
          row.wasteRate.text = it.wasteRate?.toString() ?? '';
          row.cause.text = it.cause ?? '';
          _items.add(row);
        }
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_items.isEmpty) _items.add(_ItemRow());
    if (mounted) setState(() => _loading = false);
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

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
        // 静默
      }
    }));
  }

  double get _total => _items.fold<double>(
      0,
      (s, r) =>
          s +
          (double.tryParse(r.qty.text) ?? 0) *
              (double.tryParse(r.price.text) ?? 0));

  Future<void> _pickGoods(_ItemRow row) async {
    final g = await showGoodsPickerDialog(context, ref);
    if (g != null) setState(() => row.goods = g);
  }

  Future<void> _importFromUpstream() async {
    final picked = await showSubcontractLinkPicker(context, ref, _cfg);
    if (picked == null || picked.isEmpty) return;
    final goodsIds =
        picked.map((e) => e.goodsId).where((id) => id.isNotEmpty).toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    setState(() {
      for (final li in picked) {
        if (li.goodsId.isEmpty) continue;
        final goods = GoodsOption(
          id: li.goodsId,
          name: ref.read(mn.masterNameServiceProvider).goods(li.goodsId),
        );
        _items.add(_ItemRow.fromLinked(li, goods));
      }
    });
  }

  Future<void> _save() async {
    if (_billNo.text.trim().isEmpty) {
      context.appError('请填写单据号');
      return;
    }
    if (_items.isEmpty || _items.every((r) => r.goods == null)) {
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
    for (final r in _items) {
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
        if (_cfg.itemHasPrice && price != null)
          'amountOriginal': qty * price,
        if (_cfg.itemHasPrice && price != null) 'amountLocal': qty * price,
        if (_cfg.itemHasWeight && w != null) 'weight': w,
        if (_cfg.itemHasWasteFields && ending != null) 'endingQty': ending,
        if (_cfg.itemHasWasteFields && std != null) 'standardQty': std,
        if (_cfg.itemHasWasteFields && wr != null) 'wasteRate': wr,
        if (_cfg.itemHasWasteFields && r.cause.text.trim().isNotEmpty)
          'cause': r.cause.text.trim(),
        if (r.upstreamItemId != null) ..._linkItemKey(r.upstreamItemId!),
      };
      itemsBody.add(line);
    }
    final body = <String, dynamic>{
      'billNo': _billNo.text.trim(),
      'billDate': _fmt(_billDate),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      if (_cfg.hasSupplier && _supplierId != null) 'supplierId': _supplierId,
      if (_warehouseId != null) 'warehouseId': _warehouseId,
      if (_cfg.hasCurrency && _currencyId != null) 'currencyId': _currencyId,
      if (_cfg.hasCurrency) 'exchangeRate': double.tryParse(_rate.text) ?? 1,
      if (_cfg.hasTaxRate) 'taxRate': double.tryParse(_taxRate.text),
      if (_cfg.hasPurchaser && _purchaserId != null) 'purchaserId': _purchaserId,
      if (_cfg.hasSender && _senderId != null) 'senderId': _senderId,
      if (_cfg.hasWorker && _workerId != null) 'workerId': _workerId,
      if (_cfg.hasDeliverDate && _deliverDate != null)
        'deliverDate': _fmt(_deliverDate!),
      if (_cfg.hasLastDate && _lastDate != null) 'lastDate': _fmt(_lastDate!),
      if (_cfg.hasBStyle) 'bStyle': int.tryParse(_bStyle.text),
      if (_cfg.hasTotalWeight) 'totalWeight': double.tryParse(_totalWeight.text),
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
    if (_cfg.linkToApplicationItem) return {'applicationItemId': upstreamItemId};
    return const {};
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate({
    required DateTime? current,
    required ValueChanged<DateTime> onPicked,
  }) async {
    final p = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2010),
      lastDate: DateTime(2100),
    );
    if (p != null) setState(() => onPicked(p));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
          title: widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}'),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : UtenContentContainer(
                child: ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    _headerCard(theme),
                    const SizedBox(height: UtenSpacing.s12),
                    Row(
                      children: [
                        Text('明细 (${_items.length})',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        if (_cfg.hasUpstreamLink)
                          TextButton.icon(
                            onPressed: _importFromUpstream,
                            icon: const Icon(Icons.link_rounded, size: 18),
                            label: const Text('从上游引入'),
                          ),
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => _items.add(_ItemRow())),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('添加行'),
                        ),
                      ],
                    ),
                    for (var i = 0; i < _items.length; i++)
                      _itemEditor(theme, _items[i], i),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border:
                Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_cfg.hasAmount)
                Text('合计 ¥${_total.toStringAsFixed(2)}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700))
              else if (_cfg.hasTotalWeight)
                Text('总重 ${_totalWeight.text.isEmpty ? "0.00" : _totalWeight.text}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700))
              else
                Text('${_items.where((r) => r.goods != null).length} 行',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
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
                child: Text(widget.id == null ? '存草稿' : '保存'),
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
            UtenFormGrid(children: [
              TextField(
                controller: _billNo,
                decoration: const InputDecoration(labelText: '单据号 *'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('单据日期'),
                subtitle: Text(_fmt(_billDate)),
                trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                onTap: () => _pickDate(
                  current: _billDate,
                  onPicked: (d) => _billDate = d,
                ),
              ),
              if (_cfg.hasSupplier)
                _dropdown('委外商', _supplierId, names.supplierEntries,
                    (v) => setState(() => _supplierId = v),
                    required: _cfg.supplierRequired),
              _dropdown(
                  _cfg.warehouseRequired ? '仓库 *' : '仓库',
                  _warehouseId,
                  names.warehouseEntries, (v) => setState(() => _warehouseId = v)),
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
              if (_cfg.hasTaxRate)
                TextField(
                  controller: _taxRate,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: '税率(%)'),
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
              if (_cfg.hasWorker)
                _employeePicker(
                  label: '经办人',
                  currentId: _workerId,
                  onChanged: (id) => setState(() => _workerId = id),
                ),
              if (_cfg.hasDeliverDate)
                ListTile(
                  contentPadding: const EdgeInsets.only(top: UtenSpacing.s8),
                  title: const Text('交货日期'),
                  subtitle: Text(
                      _deliverDate == null ? '未选择' : _fmt(_deliverDate!)),
                  trailing: const Icon(Icons.event_outlined, size: 18),
                  onTap: () => _pickDate(
                    current: _deliverDate,
                    onPicked: (d) => _deliverDate = d,
                  ),
                ),
              if (_cfg.hasLastDate)
                ListTile(
                  contentPadding: const EdgeInsets.only(top: UtenSpacing.s8),
                  title: const Text('最后交货日'),
                  subtitle:
                      Text(_lastDate == null ? '未选择' : _fmt(_lastDate!)),
                  trailing: const Icon(Icons.event_outlined, size: 18),
                  onTap: () => _pickDate(
                    current: _lastDate,
                    onPicked: (d) => _lastDate = d,
                  ),
                ),
              if (_cfg.hasBStyle)
                TextField(
                  controller: _bStyle,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'bStyle（业务类型）'),
                ),
              if (_cfg.hasTotalWeight)
                TextField(
                  controller: _totalWeight,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: '总重'),
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
    );
  }

  Widget _employeePicker({
    required String label,
    required String? currentId,
    required ValueChanged<String?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: UtenEmployeePicker(
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
      ),
    );
  }

  Widget _dropdown(String label, String? value, Map<String, String> entries,
      ValueChanged<String?> onChanged,
      {bool required = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: DropdownButtonFormField<String?>(
        initialValue: value,
        decoration: InputDecoration(labelText: required ? '$label *' : label),
        items: [
          const DropdownMenuItem<String?>(child: Text('— 不选 —')),
          for (final e in entries.entries)
            DropdownMenuItem<String?>(
              value: e.key,
              child: Text(e.value,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _itemEditor(ThemeData theme, _ItemRow row, int i) {
    final amount = (double.tryParse(row.qty.text) ?? 0) *
        (double.tryParse(row.price.text) ?? 0);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: InkWell(
                onTap: () => _pickGoods(row),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '货品',
                    isDense: true,
                    suffixIcon: Icon(Icons.search_rounded, size: 18),
                  ),
                  child: Text(row.goods?.name ?? '点击选择',
                      style: TextStyle(
                          color: row.goods == null
                              ? theme.colorScheme.onSurfaceVariant
                              : null)),
                ),
              ),
            ),
            if (row.upstreamItemId != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.link_rounded,
                    size: 16, color: theme.colorScheme.primary),
              ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() {
                _items.remove(row);
                row.dispose();
              }),
            ),
          ]),
          const SizedBox(height: UtenSpacing.s8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: row.qty,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: '数量 *', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (_cfg.itemHasPrice) ...[
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextField(
                  controller: row.price,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: '单价', isDense: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              SizedBox(
                width: 90,
                child: Text('¥${amount.toStringAsFixed(2)}',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
            if (_cfg.itemHasWeight && !_cfg.itemHasPrice) ...[
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextField(
                  controller: row.weight,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: '重量', isDense: true),
                ),
              ),
            ],
          ]),
          if (_cfg.itemHasWeight && _cfg.itemHasPrice) ...[
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: row.weight,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: '重量', isDense: true),
            ),
          ],
          if (_cfg.itemHasWasteFields) ...[
            const SizedBox(height: UtenSpacing.s8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: row.standardQty,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: '标准用量', isDense: true),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextField(
                  controller: row.endingQty,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: '结存数', isDense: true),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextField(
                  controller: row.wasteRate,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: '损耗率%', isDense: true),
                ),
              ),
            ]),
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: row.cause,
              decoration: const InputDecoration(
                  labelText: '损耗原因', isDense: true),
              maxLines: 2,
            ),
          ],
        ]),
      ),
    );
  }
}
