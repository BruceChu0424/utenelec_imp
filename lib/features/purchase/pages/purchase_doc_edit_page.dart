// 采购单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细行编辑器（货品选择/数量/单价→金额自动）+ 保存。
//
// 差异由 config 驱动：供应商/币种/仓库下拉按 has* 显隐；
// 人员（申请人/采购员/交货人/收货人）按 has* 显隐 UtenEmployeePicker；
// 日期（需求日期/交货日期）按 has* 显隐 showDatePicker；
// 「从上游引入」按 hasUpstreamLink 显隐（收货/退货/订货）。
// 保存组装 body 调 create/update，成功后跳详情。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../employee/repositories/employee_repository.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';
import '../widgets/doc_link_picker.dart';
import '../widgets/goods_picker_dialog.dart';

class PurchaseDocEditPage extends ConsumerStatefulWidget {
  const PurchaseDocEditPage({super.key, required this.docType, this.id});
  final PurchaseDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<PurchaseDocEditPage> createState() => _PurchaseDocEditPageState();
}

class _ItemRow {
  _ItemRow();
  GoodsOption? goods;
  final qty = TextEditingController();
  final price = TextEditingController();
  /// 上游明细 id（引入时回填，保存时按 cfg.linkTo* 映射为
  /// requestItemId/orderItemId/receiptItemId）。
  String? upstreamItemId;
  String? colorId;
  String? unitId;

  /// 从上游引入项构造（货品/数量/单价/upstream/颜色/单位 预填）。
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
  }
}

class _PurchaseDocEditPageState extends ConsumerState<PurchaseDocEditPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);
  final _billNo = TextEditingController();
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
    for (final r in _items) {
      r.dispose();
    }
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
        final goodsIds =
            d.items.map((e) => e.goodsId).whereType<String>().toSet();
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
        for (final it in d.items) {
          final row = _ItemRow()
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(masterNameServiceProvider).goods(it.goodsId))
            ..qty.text = it.qty?.toString() ?? ''
            ..price.text = it.price?.toString() ?? ''
            // 优先级与 _linkItemKey 一致（receipt > order > request），保证 round-trip。
            // TODO(multi-link): 单字段设计下，returnDoc 行的 orderItemId 在保存时会被
            // 覆写为 receiptItemId（已知限制，需要双字段时再扩 _ItemRow）。
            ..upstreamItemId = it.receiptItemId ?? it.orderItemId ?? it.requestItemId
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

  /// 「从上游引入」：弹选择器，把所选 _LinkedItem 映射成 _ItemRow 追加。
  Future<void> _importFromUpstream() async {
    final picked = await showDocLinkPicker(context, ref, _cfg);
    if (picked == null || picked.isEmpty) return;
    final goodsIds = picked.map((e) => e.goodsId).where((id) => id.isNotEmpty).toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    setState(() {
      for (final li in picked) {
        if (li.goodsId.isEmpty) continue;
        final goods = GoodsOption(
          id: li.goodsId,
          name: ref.read(masterNameServiceProvider).goods(li.goodsId),
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
      context.appError('请选择供应商');
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
        if (r.upstreamItemId != null) ..._linkItemKey(r.upstreamItemId!),
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
      });
    }
    final body = <String, dynamic>{
      'billNo': _billNo.text.trim(),
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
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(title: widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}'),
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
                        child: Column(children: [
                          TextField(
                            controller: _billNo,
                            decoration: const InputDecoration(labelText: '单据号 *'),
                          ),
                          const SizedBox(height: UtenSpacing.s8),
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
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                          // 日期字段（按 config 显隐）
                          if (_cfg.hasNeedDate)
                            ListTile(
                              contentPadding: const EdgeInsets.only(top: UtenSpacing.s8),
                              title: const Text('需求日期'),
                              subtitle: Text(_needDate == null
                                  ? '未选择'
                                  : _fmt(_needDate!)),
                              trailing: const Icon(Icons.event_outlined, size: 18),
                              onTap: () => _pickDate(
                                current: _needDate,
                                onPicked: (d) => _needDate = d,
                              ),
                            ),
                          if (_cfg.hasDeliverDate)
                            ListTile(
                              contentPadding: const EdgeInsets.only(top: UtenSpacing.s8),
                              title: const Text('交货日期'),
                              subtitle: Text(_deliverDate == null
                                  ? '未选择'
                                  : _fmt(_deliverDate!)),
                              trailing: const Icon(Icons.event_outlined, size: 18),
                              onTap: () => _pickDate(
                                current: _deliverDate,
                                onPicked: (d) => _deliverDate = d,
                              ),
                            ),
                          TextField(
                            controller: _remark,
                            decoration: const InputDecoration(labelText: '备注'),
                            maxLines: 2,
                          ),
                        ]),
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
                          onPressed: () => setState(() => _items.add(_ItemRow())),
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
            border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('合计 ¥${_total.toStringAsFixed(2)}',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
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
        decoration: InputDecoration(labelText: required ? '$label *' : label),
        items: [
          const DropdownMenuItem<String?>(child: Text('— 不选 —')),
          for (final e in entries.entries)
            DropdownMenuItem<String?>(
              value: e.key,
              child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _itemEditor(ThemeData theme, _ItemRow row, int i) {
    final amount =
        (double.tryParse(row.qty.text) ?? 0) * (double.tryParse(row.price.text) ?? 0);
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
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '数量', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: TextField(
                controller: row.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '单价', isDense: true),
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

