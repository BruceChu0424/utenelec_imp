// 销售单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 差异由 config 驱动（与采购 edit 页同形）：
//  - 客户/仓库/币种下拉按 has* 显隐；
//  - 业务员/发货人按 has* 显隐 UtenEmployeePicker；
//  - 有效期（报价）/交货日（订货）按 has* 显隐 UtenDateField（outlined，与其它字段同款）；
//  - 合同信息（订货）/发货信息（出货类）/出库类型（其它出货）按 has* 显隐；
//  - 「从上游引入」按 hasUpstreamLink 显隐（出货→订货，退货→出货）。
//  - 明细改 Excel 表：货品/颜色/单位/数量/单价→金额自动 + V66 报表补列 + 添加行/添加多行 + 行尾删除。
//
// 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// 保存组装 body 调 create/update，成功后跳详情。
// 路由用 SalesRoutePath 字面量（route_names.dart 由上层统一加 sales_*）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
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
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../employee/repositories/employee_repository.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_doc_link_picker.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../widgets/sales_grid_columns.dart';

class SalesDocEditPage extends ConsumerStatefulWidget {
  const SalesDocEditPage({super.key, required this.docType, this.id});
  final SalesDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<SalesDocEditPage> createState() => _SalesDocEditPageState();
}

class _SalesDocEditPageState extends ConsumerState<SalesDocEditPage> {
  SalesDocConfig get _cfg => SalesDocConfig.by(widget.docType);
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
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

  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

  final _grid = UtenEditableGridController<SalesGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loading = false;

  /// 必填校验未通过的表头字段 key（client/warehouse/currency/deliverDate/items），
  /// 对应输入框描红；字段改值即时清除。
  final Set<String> _errors = {};

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
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(salesMasterNameServiceProvider).ensureLoaded();
    if (widget.id == null && _cfg.hasWarehouse) {
      // D1（王浩然）：新建出库单按「本人类型最近一张单的仓库」预填，减少手选。
      try {
        final last = await ref
            .read(salesRepositoryProvider(widget.docType))
            .list(size: 1);
        if (last.items.isNotEmpty && last.items.first.warehouseId != null) {
          _warehouseId = last.items.first.warehouseId;
        }
      } catch (_) {
        /* 预填失败静默，用户手选 */
      }
    }
    if (widget.id != null) {
      try {
        final d = await ref
            .read(salesRepositoryProvider(widget.docType))
            .detail(widget.id!);
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
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
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        final rows = <SalesGridRow>[];
        for (final it in d.items) {
          final row = SalesGridRow()
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref
                        .read(salesMasterNameServiceProvider)
                        .goods(it.goodsId),
                  )
            ..orderItemId = it.orderItemId
            ..outItemId = it.outItemId
            ..colorId = it.colorId
            ..unitId = it.unitId;
          row.qty.text = it.qty?.toString() ?? '';
          row.price.text = it.price?.toString() ?? '';
          // V66 补列回填（按 docType 仅填该单据类型对应字段；其余保持空）。
          if (it.machiningPrice != null) {
            row.machiningPrice.text = it.machiningPrice.toString();
          }
          if (it.circumference != null) {
            row.circumference.text = it.circumference.toString();
          }
          if (it.inboundQty != null) {
            row.inboundQty.text = it.inboundQty.toString();
          }
          if (it.materialPrice != null) {
            row.materialPrice.text = it.materialPrice.toString();
          }
          if (it.dieCastPrice != null) {
            row.dieCastPrice.text = it.dieCastPrice.toString();
          }
          if (it.discount != null) {
            row.discount.text = it.discount.toString();
          }
          row.remark.text = it.remark ?? '';
          rows.add(row);
        }
        _grid.replaceAll(rows);
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_grid.isEmpty) _grid.addRow(SalesGridRow());
    if (mounted) setState(() => _loading = false);
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  /// 并发按 id 拉人员字段的名字（picker 的 initial 显示用）。失败静默。
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

  Future<void> _pickGoods(SalesGridRow row) async {
    final g = await showUtenGoodsPicker(context, ref);
    if (g == null) return;
    final names = ref.read(salesMasterNameServiceProvider);
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      // 颜色/单位按货品主档自动回填（legacy id → 新库 UUID），单元格只读显示。
      ..colorId = names.colorIdByLegacy(g.colorLegacyId)
      ..unitId = names.unitIdByLegacy(g.unitLegacyId);
  }

  /// 「从上游引入」：弹选择器，把所选 SalesLinkedItem 映射成行追加。
  Future<void> _importFromUpstream() async {
    final picked = await showSalesDocLinkPicker(context, ref, _cfg);
    if (picked == null || picked.isEmpty) return;
    final goodsIds = picked
        .map((e) => e.goodsId)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (goodsIds.isNotEmpty) {
      await ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds);
    }
    if (!mounted) return;
    final rows = <SalesGridRow>[];
    for (final li in picked) {
      if (li.goodsId.isEmpty) continue;
      final goods = GoodsOption(
        id: li.goodsId,
        name: ref.read(salesMasterNameServiceProvider).goods(li.goodsId),
      );
      rows.add(SalesGridRow.fromLinked(li, goods));
    }
    _grid.addRows(rows);
  }

  /// 必填校验：返回第一条错误文案；并把未填的表头字段记入 [_errors]（红框）、
  /// 不合格明细行打红标。通过则返回 null（并清除旧标记）。
  String? _validate() {
    final errs = <String>{};
    String? first;
    void fail(String key, String msg) {
      errs.add(key);
      first ??= msg;
    }

    if (_cfg.clientRequired && _clientId == null) fail('client', '请选择客户');
    if (_cfg.hasWarehouse && _warehouseId == null) fail('warehouse', '请选择仓库');
    if (_cfg.hasCurrency && _currencyId == null) fail('currency', '请选择币种');
    if (_cfg.hasDeliverDate && _deliverDate == null) {
      fail('deliverDate', '请选择交货日期');
    }
    final allRows = _grid.rows;
    final rows = allRows.where((r) => r.goods != null).toList();
    // 填了内容但没选货品的行：不能静默丢弃，拦下提示（货品格描红）。
    var noGoodsRow = 0;
    for (var i = 0; i < allRows.length; i++) {
      final r = allRows[i];
      if (r.goods != null) continue;
      final touched =
          r.qty.text.trim().isNotEmpty ||
          r.price.text.trim().isNotEmpty ||
          r.remark.text.trim().isNotEmpty;
      if (touched) {
        r.invalidNotifier.value = true;
        noGoodsRow = noGoodsRow == 0 ? i + 1 : noGoodsRow;
      }
    }
    if (noGoodsRow > 0) {
      fail('items', '第 $noGoodsRow 行明细：请选择货品');
    } else if (rows.isEmpty) {
      fail('items', '请至少添加一条明细（选择货品）');
    } else {
      final priceRequired = widget.docType != SalesDocType.otherShipment;
      var badRow = 0;
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final qtyOk = (double.tryParse(r.qty.text.trim()) ?? 0) > 0;
        final priceOk =
            !priceRequired ||
            (r.price.text.trim().isNotEmpty &&
                double.tryParse(r.price.text.trim()) != null);
        if (!qtyOk || !priceOk) {
          r.invalidNotifier.value = true;
          badRow = badRow == 0 ? i + 1 : badRow;
        }
      }
      if (badRow > 0) {
        fail('items', '第 $badRow 行明细：数量须大于 0${priceRequired ? '，单价必填' : ''}');
      }
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(errs);
    });
    return first;
  }

  /// 字段修改后即时清除对应红框。
  void _clearError(String key) {
    if (_errors.contains(key)) setState(() => _errors.remove(key));
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      context.appError(err);
      return;
    }
    final rows = _grid.rows;
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text) ?? 0;
      final price = double.tryParse(r.price.text);
      // V66 补列：按 docType 序列化对应字段（空文本不传，后端按 nullable 处理）。
      double? parseExtra(TextEditingController c) {
        final t = c.text.trim();
        return t.isEmpty ? null : double.tryParse(t);
      }

      final body = <String, dynamic>{
        'goodsId': r.goods!.id,
        'qty': qty,
        if (price != null) 'price': price,
        if (price != null) 'amountOriginal': qty * price,
        if (price != null) 'amountLocal': qty * price,
        if (r.orderItemId != null) 'orderItemId': r.orderItemId,
        if (r.outItemId != null) 'outItemId': r.outItemId,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        // 行备注：5 类单据通用（空文本不传，后端按 null 处理）。
        if (r.remark.text.trim().isNotEmpty) 'remark': r.remark.text.trim(),
      };
      switch (widget.docType) {
        case SalesDocType.order:
          final mp = parseExtra(r.machiningPrice);
          final circ = parseExtra(r.circumference);
          final inb = parseExtra(r.inboundQty);
          if (mp != null) body['machiningPrice'] = mp;
          if (circ != null) body['circumference'] = circ;
          if (inb != null) body['inboundQty'] = inb;
          break;
        case SalesDocType.shipment:
        case SalesDocType.otherShipment:
          final mat = parseExtra(r.materialPrice);
          final dc = parseExtra(r.dieCastPrice);
          final jp = parseExtra(r.machiningPrice);
          final circ = parseExtra(r.circumference);
          final disc = parseExtra(r.discount);
          if (mat != null) body['materialPrice'] = mat;
          if (dc != null) body['dieCastPrice'] = dc;
          if (jp != null) body['machiningPrice'] = jp;
          if (circ != null) body['circumference'] = circ;
          if (disc != null) body['discount'] = disc;
          break;
        case SalesDocType.returnDoc:
          final disc = parseExtra(r.discount);
          if (disc != null) body['discount'] = disc;
          break;
        case SalesDocType.quote:
          break;
      }
      itemsBody.add(body);
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
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
        if (_signAddr.text.trim().isNotEmpty) 'signAddr': _signAddr.text.trim(),
        if (_shipAddr.text.trim().isNotEmpty) 'shipAddr': _shipAddr.text.trim(),
        if (_deposit.text.trim().isNotEmpty)
          'deposit': double.tryParse(_deposit.text.trim()),
      },
      if (_cfg.hasShipInfo) ...{
        if (_shipAddr.text.trim().isNotEmpty) 'shipAddr': _shipAddr.text.trim(),
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
      context.replace(SalesRoutePath.docDetail(_cfg.type.pathSegment, d.id));
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: SalesRoutePath.hub),
        ),
        actions: _cfg.skipListOnCreate
            ? [
                UtenButton(
                  type: UtenButtonType.tonal,
                  icon: Icons.history_rounded,
                  onPressed: () =>
                      context.push('/sales/${_cfg.type.pathSegment}'),
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
                                  _dropdown(
                                    '客户',
                                    _clientId,
                                    names.clientEntries,
                                    (v) {
                                      setState(() => _clientId = v);
                                      _clearError('client');
                                    },
                                    required: _cfg.clientRequired,
                                    errorText: _errors.contains('client')
                                        ? '请选择客户'
                                        : null,
                                  ),
                                  if (_cfg.hasWarehouse)
                                    _dropdown(
                                      '仓库',
                                      _warehouseId,
                                      names.warehouseEntries,
                                      (v) {
                                        setState(() => _warehouseId = v);
                                        _clearError('warehouse');
                                      },
                                      required: true,
                                      errorText: _errors.contains('warehouse')
                                          ? '请选择仓库'
                                          : null,
                                    ),
                                  if (_cfg.hasCurrency) ...[
                                    _dropdown(
                                      '币种',
                                      _currencyId,
                                      names.currencyEntries,
                                      (v) {
                                        setState(() => _currencyId = v);
                                        _clearError('currency');
                                      },
                                      required: true,
                                      errorText: _errors.contains('currency')
                                          ? '请选择币种'
                                          : null,
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
                                  // 人员字段（按 config 显隐）
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
                                  // 日期字段（按 config 显隐，统一 UtenDateField）
                                  if (_cfg.hasValidUntil)
                                    UtenDateField(
                                      label: '有效期',
                                      value: _validUntil,
                                      onChanged: (d) =>
                                          setState(() => _validUntil = d),
                                    ),
                                  if (_cfg.hasDeliverDate)
                                    UtenDateField(
                                      label: '交货日期',
                                      required: true,
                                      value: _deliverDate,
                                      errorText: _errors.contains('deliverDate')
                                          ? '请选择交货日期'
                                          : null,
                                      onChanged: (d) {
                                        setState(() => _deliverDate = d);
                                        _clearError('deliverDate');
                                      },
                                    ),
                                  if (_cfg.hasContractInfo) ...[
                                    TextField(
                                      controller: _contractNo,
                                      decoration: const InputDecoration(
                                        labelText: '合同号',
                                      ),
                                    ),
                                    TextField(
                                      controller: _linkPhone,
                                      decoration: const InputDecoration(
                                        labelText: '联系电话',
                                      ),
                                    ),
                                    TextField(
                                      controller: _signAddr,
                                      decoration: const InputDecoration(
                                        labelText: '签约地点',
                                      ),
                                    ),
                                    TextField(
                                      controller: _shipAddr,
                                      decoration: const InputDecoration(
                                        labelText: '收货地址',
                                      ),
                                    ),
                                    TextField(
                                      controller: _deposit,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      decoration: const InputDecoration(
                                        labelText: '订金',
                                      ),
                                    ),
                                  ],
                                  if (_cfg.hasShipInfo) ...[
                                    TextField(
                                      controller: _shipAddr,
                                      decoration: const InputDecoration(
                                        labelText: '收货地址',
                                      ),
                                    ),
                                    TextField(
                                      controller: _shipLinkPhone,
                                      decoration: const InputDecoration(
                                        labelText: '联系电话',
                                      ),
                                    ),
                                    TextField(
                                      controller: _parcelCount,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                        labelText: '件数',
                                      ),
                                    ),
                                  ],
                                  if (_cfg.hasOutType)
                                    TextField(
                                      controller: _outType,
                                      decoration: const InputDecoration(
                                        labelText: '出库类型',
                                      ),
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
                      UtenEditableGrid<SalesGridRow>(
                        controller: _grid,
                        columns: salesGridColumns(
                          onPickGoods: _pickGoods,
                          docType: widget.docType,
                          colorEntries: names.colorEntries,
                          unitEntries: names.unitEntries,
                        ),
                        createBlankRow: () => SalesGridRow(),
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
                onPressed: () =>
                    popOrBackTo(context, defaultPath: SalesRoutePath.hub),
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

  Widget _dropdown(
    String label,
    String? value,
    Map<String, String> entries,
    ValueChanged<String?> onChanged, {
    bool required = false,
    String? errorText,
  }) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
      errorText: errorText,
      searchable: true, // 客户/仓库/币种等主档下拉一律支持搜索
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
