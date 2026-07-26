// 销售单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细行编辑器 + 保存。
//
// 差异由 config 驱动（与采购 edit 页同形）：
//  - 客户/仓库/币种下拉按 has* 显隐；
//  - 业务员/发货人按 has* 显隐 UtenEmployeePicker；
//  - 有效期（报价）/交货日（订货）按 has* 显隐 showDatePicker；
//  - 合同信息（订货）/发货信息（出货类）/出库类型（其它出货）按 has* 显隐；
//  - 「从上游引入」按 hasUpstreamLink 显隐（出货→订货，退货→出货）。
//  - 明细行含：货品 picker + 颜色/单位下拉 + 数量/单价（金额自动）。
//
// 保存组装 body 调 create/update，成功后跳详情。
// 路由用 SalesRoutePath 字面量（route_names.dart 由上层统一加 sales_*）。
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
import '../../employee/repositories/employee_repository.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_doc_link_picker.dart';
import '../widgets/sales_goods_picker.dart';

class SalesDocEditPage extends ConsumerStatefulWidget {
  const SalesDocEditPage({super.key, required this.docType, this.id});
  final SalesDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<SalesDocEditPage> createState() => _SalesDocEditPageState();
}

class _ItemRow {
  _ItemRow();
  GoodsOption? goods;
  final qty = TextEditingController();
  final price = TextEditingController();
  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 映射为 orderItemId/outItemId）。
  String? orderItemId;
  String? outItemId;
  String? colorId;
  String? unitId;

  /// 从上游引入项构造（货品/数量/单价/upstream/颜色/单位 预填）。
  factory _ItemRow.fromLinked(SalesLinkedItem li, GoodsOption goods) {
    final r = _ItemRow()
      ..goods = goods
      ..orderItemId = li.orderItemId
      ..outItemId = li.outItemId
      ..colorId = li.colorId
      ..unitId = li.unitId;
    r.qty.text = li.qty.toString();
    if (li.price != null) r.price.text = li.price.toString();
    return r;
  }

  void dispose() {
    qty.dispose();
    price.dispose();
  }
}

class _SalesDocEditPageState extends ConsumerState<SalesDocEditPage> {
  SalesDocConfig get _cfg => SalesDocConfig.by(widget.docType);
  final _billNo = TextEditingController();
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _taxRate = TextEditingController();
  DateTime _billDate = DateTime.now();

  // 合同信息（订货）
  final _contractNo = TextEditingController();
  final _linkPhone = TextEditingController();
  final _signAddr = TextEditingController();
  final _shipAddr = TextEditingController();
  final _deposit = TextEditingController();

  // 出货类发货信息
  final _shipLinkPhone = TextEditingController();
  final _parcelCount = TextEditingController();
  final _outType = TextEditingController();

  String? _clientId;
  String? _warehouseId;
  String? _currencyId;

  // 人员字段（id + 给 picker 的 initial 项缓存）
  String? _sellerId;
  String? _senderId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  // 日期字段
  DateTime? _validUntil; // 报价有效期
  DateTime? _deliverDate; // 订货交货日

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
    _contractNo.dispose();
    _linkPhone.dispose();
    _signAddr.dispose();
    _shipAddr.dispose();
    _deposit.dispose();
    _shipLinkPhone.dispose();
    _parcelCount.dispose();
    _outType.dispose();
    for (final r in _items) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(salesMasterNameServiceProvider).ensureLoaded();
    if (widget.id != null) {
      try {
        final d = await ref
            .read(salesRepositoryProvider(widget.docType))
            .detail(widget.id!);
        final goodsIds =
            d.items.map((e) => e.goodsId).whereType<String>().toSet();
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
        _rate.text = d.exchangeRate?.toString() ?? '1';
        _taxRate.text = d.taxRate?.toString() ?? '';
        _sellerId = d.sellerId;
        _senderId = d.senderId;
        _validUntil = _parseDate(d.validUntil);
        _deliverDate = _parseDate(d.deliverDate);
        _contractNo.text = d.contractNo ?? '';
        _linkPhone.text = d.linkPhone ?? '';
        _signAddr.text = d.signAddr ?? '';
        _shipAddr.text = d.shipAddr ?? '';
        _deposit.text = d.deposit?.toString() ?? '';
        _shipLinkPhone.text = d.linkPhone ?? '';
        _parcelCount.text = d.parcelCount?.toString() ?? '';
        _outType.text = d.outType ?? '';
        for (final it in d.items) {
          final row = _ItemRow()
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(salesMasterNameServiceProvider).goods(it.goodsId))
            ..qty.text = it.qty?.toString() ?? ''
            ..price.text = it.price?.toString() ?? ''
            ..orderItemId = it.orderItemId
            ..outItemId = it.outItemId
            ..colorId = it.colorId
            ..unitId = it.unitId;
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

  /// 并发按 id 拉人员字段的名字（picker 的 initial 显示用）。失败静默。
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
    final g = await showSalesGoodsPickerDialog(context, ref);
    if (g != null) setState(() => row.goods = g);
  }

  /// 「从上游引入」：弹选择器，把所选 SalesLinkedItem 映射成 _ItemRow 追加。
  Future<void> _importFromUpstream() async {
    final picked = await showSalesDocLinkPicker(context, ref, _cfg);
    if (picked == null || picked.isEmpty) return;
    final goodsIds =
        picked.map((e) => e.goodsId).where((id) => id.isNotEmpty).toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    setState(() {
      for (final li in picked) {
        if (li.goodsId.isEmpty) continue;
        final goods = GoodsOption(
          id: li.goodsId,
          name: ref.read(salesMasterNameServiceProvider).goods(li.goodsId),
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
    if (_cfg.clientRequired && _clientId == null) {
      context.appError('请选择客户');
      return;
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in _items) {
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text) ?? 0;
      final price = double.tryParse(r.price.text);
      itemsBody.add({
        'goodsId': r.goods!.id,
        'qty': qty,
        if (price != null) 'price': price,
        if (price != null) 'amountOriginal': qty * price,
        if (price != null) 'amountLocal': qty * price,
        if (r.orderItemId != null) 'orderItemId': r.orderItemId,
        if (r.outItemId != null) 'outItemId': r.outItemId,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
      });
    }
    final body = <String, dynamic>{
      'billNo': _billNo.text.trim(),
      'billDate': _fmt(_billDate),
      if (_clientId != null) 'clientId': _clientId,
      if (_cfg.hasWarehouse && _warehouseId != null)
        'warehouseId': _warehouseId,
      if (_cfg.hasCurrency && _currencyId != null) 'currencyId': _currencyId,
      if (_cfg.hasCurrency) 'exchangeRate': double.tryParse(_rate.text) ?? 1,
      if (_cfg.hasCurrency && _taxRate.text.isNotEmpty)
        'taxRate': double.tryParse(_taxRate.text),
      if (_cfg.hasSeller && _sellerId != null) 'sellerId': _sellerId,
      if (_cfg.hasSender && _senderId != null) 'senderId': _senderId,
      if (_cfg.hasValidUntil && _validUntil != null)
        'validUntil': _fmt(_validUntil!),
      if (_cfg.hasDeliverDate && _deliverDate != null)
        'deliverDate': _fmt(_deliverDate!),
      if (_cfg.hasContractInfo) ...{
        if (_contractNo.text.trim().isNotEmpty)
          'contractNo': _contractNo.text.trim(),
        if (_linkPhone.text.trim().isNotEmpty)
          'linkPhone': _linkPhone.text.trim(),
        if (_signAddr.text.trim().isNotEmpty)
          'signAddr': _signAddr.text.trim(),
        if (_shipAddr.text.trim().isNotEmpty)
          'shipAddr': _shipAddr.text.trim(),
        if (_deposit.text.trim().isNotEmpty)
          'deposit': double.tryParse(_deposit.text.trim()),
      },
      if (_cfg.hasShipInfo) ...{
        if (_shipAddr.text.trim().isNotEmpty)
          'shipAddr': _shipAddr.text.trim(),
        if (_shipLinkPhone.text.trim().isNotEmpty)
          'linkPhone': _shipLinkPhone.text.trim(),
        if (_parcelCount.text.trim().isNotEmpty)
          'parcelCount': int.tryParse(_parcelCount.text.trim()),
      },
      if (_cfg.hasOutType && _outType.text.trim().isNotEmpty)
        'outType': _outType.text.trim(),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
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
      context.replace(
          SalesRoutePath.docDetail(_cfg.type.pathSegment, d.id));
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
    final names = ref.watch(salesMasterNameServiceProvider);
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
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            UtenFormGrid(children: [
                              TextField(
                                controller: _billNo,
                                decoration:
                                    const InputDecoration(labelText: '单据号 *'),
                              ),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('单据日期'),
                                subtitle: Text(_fmt(_billDate)),
                                trailing: const Icon(Icons.calendar_today_outlined,
                                    size: 18),
                                onTap: () => _pickDate(
                                  current: _billDate,
                                  onPicked: (d) => _billDate = d,
                                ),
                              ),
                              _dropdown('客户', _clientId, names.clientEntries,
                                  (v) => setState(() => _clientId = v),
                                  required: _cfg.clientRequired),
                              if (_cfg.hasWarehouse)
                                _dropdown('仓库', _warehouseId, names.warehouseEntries,
                                    (v) => setState(() => _warehouseId = v)),
                              if (_cfg.hasCurrency) ...[
                                _dropdown(
                                    '币种',
                                    _currencyId,
                                    names.currencyEntries,
                                    (v) => setState(() => _currencyId = v)),
                                TextField(
                                  controller: _rate,
                                  keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true),
                                  decoration:
                                      const InputDecoration(labelText: '汇率'),
                                ),
                                TextField(
                                  controller: _taxRate,
                                  keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true),
                                  decoration:
                                      const InputDecoration(labelText: '税率(%)'),
                                ),
                              ],
                              if (_cfg.hasSeller)
                                _employeePicker(
                                  label: '业务员',
                                  currentId: _sellerId,
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
                              if (_cfg.hasValidUntil)
                                ListTile(
                                  contentPadding:
                                      const EdgeInsets.only(top: UtenSpacing.s8),
                                  title: const Text('有效期'),
                                  subtitle: Text(_validUntil == null
                                      ? '未选择'
                                      : _fmt(_validUntil!)),
                                  trailing: const Icon(Icons.event_outlined,
                                      size: 18),
                                  onTap: () => _pickDate(
                                    current: _validUntil,
                                    onPicked: (d) => _validUntil = d,
                                  ),
                                ),
                              if (_cfg.hasDeliverDate)
                                ListTile(
                                  contentPadding:
                                      const EdgeInsets.only(top: UtenSpacing.s8),
                                  title: const Text('交货日期'),
                                  subtitle: Text(_deliverDate == null
                                      ? '未选择'
                                      : _fmt(_deliverDate!)),
                                  trailing: const Icon(Icons.event_outlined,
                                      size: 18),
                                  onTap: () => _pickDate(
                                    current: _deliverDate,
                                    onPicked: (d) => _deliverDate = d,
                                  ),
                                ),
                              if (_cfg.hasContractInfo) ...[
                                TextField(
                                  controller: _contractNo,
                                  decoration: const InputDecoration(
                                      labelText: '合同号'),
                                ),
                                TextField(
                                  controller: _linkPhone,
                                  decoration: const InputDecoration(
                                      labelText: '联系电话'),
                                ),
                                TextField(
                                  controller: _signAddr,
                                  decoration: const InputDecoration(
                                      labelText: '签约地点'),
                                ),
                                TextField(
                                  controller: _shipAddr,
                                  decoration: const InputDecoration(
                                      labelText: '收货地址'),
                                ),
                                TextField(
                                  controller: _deposit,
                                  keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true),
                                  decoration:
                                      const InputDecoration(labelText: '订金'),
                                ),
                              ],
                              if (_cfg.hasShipInfo) ...[
                                TextField(
                                  controller: _shipAddr,
                                  decoration: const InputDecoration(
                                      labelText: '收货地址'),
                                ),
                                TextField(
                                  controller: _shipLinkPhone,
                                  decoration: const InputDecoration(
                                      labelText: '联系电话'),
                                ),
                                TextField(
                                  controller: _parcelCount,
                                  keyboardType: TextInputType.number,
                                  decoration:
                                      const InputDecoration(labelText: '件数'),
                                ),
                              ],
                              if (_cfg.hasOutType)
                                TextField(
                                  controller: _outType,
                                  decoration: const InputDecoration(
                                      labelText: '出库类型'),
                                ),
                            ]),
                            const SizedBox(height: UtenSpacing.s12),
                            TextField(
                              controller: _remark,
                              decoration:
                                  const InputDecoration(labelText: '备注'),
                              maxLines: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
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
                      _itemEditor(theme, names, _items[i], i),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('合计 ¥${_total.toStringAsFixed(2)}',
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

  /// 人员选择器：用 EmployeeRepository.list 模糊搜索作为 loader，按 id 取缓存作为 initial。
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
        decoration:
            InputDecoration(labelText: required ? '$label *' : label),
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

  Widget _itemEditor(
      ThemeData theme, SalesMasterNameService names, _ItemRow row, int i) {
    final amount = (double.tryParse(row.qty.text) ?? 0) *
        (double.tryParse(row.price.text) ?? 0);
    final linked = row.orderItemId != null || row.outItemId != null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
            if (linked)
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
            // 颜色下拉
            Expanded(
              child: DropdownButtonFormField<String?>(
                key: ValueKey('color_${i}_${row.colorId ?? ''}'),
                initialValue: row.colorId,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: '颜色', isDense: true),
                items: [
                  const DropdownMenuItem<String?>(child: Text('—')),
                  for (final e in names.colorEntries.entries)
                    DropdownMenuItem<String?>(
                      value: e.key,
                      child: Text(e.value,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => row.colorId = v),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            // 单位下拉
            Expanded(
              child: DropdownButtonFormField<String?>(
                key: ValueKey('unit_${i}_${row.unitId ?? ''}'),
                initialValue: row.unitId,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: '单位', isDense: true),
                items: [
                  const DropdownMenuItem<String?>(child: Text('—')),
                  for (final e in names.unitEntries.entries)
                    DropdownMenuItem<String?>(
                      value: e.key,
                      child: Text(e.value,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => row.unitId = v),
              ),
            ),
          ]),
          const SizedBox(height: UtenSpacing.s8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: row.qty,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: '数量', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: TextField(
                controller: row.price,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: '单价', isDense: true),
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
          ]),
        ]),
      ),
    );
  }
}
