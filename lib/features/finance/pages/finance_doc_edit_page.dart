// 钱流单据编辑页（新建/编辑，全页路由，按 docType 参数化）。
//
// 主表头表单 + 明细行编辑器（3 种模式）+ 保存。
// - settle（receipt/payment）：明细 = AR/AP 核销行，用「从应收应付引入」对话框选台账行回填；
// - allocate（expense/otherIncome）：明细 = 分摊行（项目下拉 + 金额 + 摘要）；
// - transfer（bankTransfer）：明细 = 转入行（转入账户 + 日期 + 金额）。
// 差异由 config 驱动；保存组装 body 调 create/update，成功后跳详情。
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
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/ar_ap_picker_dialog.dart';

class FinanceDocEditPage extends ConsumerStatefulWidget {
  const FinanceDocEditPage({super.key, required this.docType, this.id});
  final FinanceDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<FinanceDocEditPage> createState() => _FinanceDocEditPageState();
}

class _ItemRow {
  _ItemRow();
  // settle
  String? appliedLedgerId;
  String? appliedBillNo;
  // allocate
  String? styleId; // expense/income 项目
  String? departmentId;
  // transfer
  String? inAccountId;
  String? occurDate;
  // 公共
  final qty = TextEditingController();
  final price = TextEditingController();
  final amount = TextEditingController(); // 本次/分摊/转入金额（本币）

  factory _ItemRow.fromApplied(AppliedArAp a) {
    final r = _ItemRow()
      ..appliedLedgerId = a.ledgerId
      ..appliedBillNo = a.appliedBillNo;
    r.amount.text = a.amountLocal.toStringAsFixed(2);
    return r;
  }

  void dispose() {
    qty.dispose();
    price.dispose();
    amount.dispose();
  }
}

class _FinanceDocEditPageState extends ConsumerState<FinanceDocEditPage> {
  FinanceDocConfig get _cfg => FinanceDocConfig.by(widget.docType);
  final _billNo = TextEditingController();
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _bankFee = TextEditingController();
  final _otherFee = TextEditingController();
  final _invoiceNo = TextEditingController();
  DateTime _billDate = DateTime.now();

  String? _accountId;
  String? _partyId; // clientId / supplierId
  String? _currencyId;
  String? _operatorId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

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
    _bankFee.dispose();
    _otherFee.dispose();
    _invoiceNo.dispose();
    for (final r in _items) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(financeNameServiceProvider).ensureLoaded();
    if (_cfg.isAllocate) {
      await ref.read(financeNameServiceProvider).loadStyleCategory(
          _cfg.type == FinanceDocType.expense ? 'EXPENSE' : 'INCOME');
    }
    if (widget.id != null) {
      try {
        final d = await ref
            .read(financeRepositoryProvider(widget.docType))
            .detail(widget.id!);
        await _preloadEmployees([d.operatorId]);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        _bankFee.text = d.bankFee?.toString() ?? '';
        _otherFee.text = d.otherFee?.toString() ?? '';
        _invoiceNo.text = d.invoiceNo ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _accountId = d.accountId ?? d.outAccountId;
        _partyId = d.clientId ?? d.supplierId;
        _currencyId = d.currencyId;
        _rate.text = d.exchangeRate?.toString() ?? '1';
        _operatorId = d.operatorId;
        for (final it in d.items) {
          final row = _ItemRow()
            ..appliedLedgerId = it.appliedLedgerId
            ..appliedBillNo = it.appliedBillNo
            ..styleId = it.expenseStyleId ?? it.incomeStyleId
            ..departmentId = it.departmentId
            ..inAccountId = it.inAccountId
            ..occurDate = it.occurDate;
          row.qty.text = it.qty?.toString() ?? '';
          row.price.text = it.price?.toString() ?? '';
          row.amount.text = it.amountLocal?.toString() ?? '';
          _items.add(row);
        }
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_items.isEmpty && !_cfg.isSettle) _items.add(_ItemRow());
    if (mounted) setState(() => _loading = false);
  }

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
      } catch (_) {/* 静默 */}
    }));
  }

  double get _total => _items.fold<double>(
      0, (s, r) => s + (double.tryParse(r.amount.text) ?? 0));

  /// 「从应收应付引入」：弹核销选择器，把所选 AppliedArAp 映射成 _ItemRow 追加。
  Future<void> _importFromArAp() async {
    if (_partyId == null || _partyId!.isEmpty) {
      context.appError('请先选择${_cfg.partyLabel}');
      return;
    }
    final direction = _cfg.isClient ? 'AR' : 'AP';
    final picked = await showArApPickerDialog(
      context, ref,
      direction: direction,
      partyId: _partyId,
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      for (final a in picked) {
        _items.add(_ItemRow.fromApplied(a));
      }
    });
  }

  Future<void> _save() async {
    if (_billNo.text.trim().isEmpty) {
      context.appError('请填写单据号');
      return;
    }
    if (_accountId == null) {
      context.appError('请选择${_cfg.accountLabel}');
      return;
    }
    if (_cfg.hasParty && _partyId == null) {
      context.appError('请选择${_cfg.partyLabel}');
      return;
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in _items) {
      final amt = double.tryParse(r.amount.text);
      if (amt == null || amt <= 0) continue;
      final item = <String, dynamic>{
        'amountLocal': amt,
        'amountOriginal': amt,
      };
      if (_cfg.isSettle) {
        if (r.appliedLedgerId != null) {
          item['appliedLedgerId'] = r.appliedLedgerId;
        }
        if (r.appliedBillNo != null) {
          item['appliedBillNo'] = r.appliedBillNo;
        }
        if (_cfg.isClient) {
          item['clientId'] = _partyId;
        }
      } else if (_cfg.isAllocate) {
        if (r.styleId != null) {
          if (_cfg.type == FinanceDocType.expense) {
            item['expenseStyleId'] = r.styleId;
          } else {
            item['incomeStyleId'] = r.styleId;
          }
        }
        if (r.departmentId != null && r.departmentId!.isNotEmpty) {
          item['departmentId'] = r.departmentId;
        }
        final qty = double.tryParse(r.qty.text);
        final price = double.tryParse(r.price.text);
        if (qty != null) item['qty'] = qty;
        if (price != null) item['price'] = price;
      } else if (_cfg.isTransfer) {
        if (r.inAccountId != null) item['inAccountId'] = r.inAccountId;
        if (r.occurDate != null) item['occurDate'] = r.occurDate;
      }
      itemsBody.add(item);
    }
    // settle 单允许无明细（直接收款，客户预付）；allocate/transfer 建议至少一行。
    if (!_cfg.isSettle && itemsBody.isEmpty) {
      context.appError('请至少添加一条明细');
      return;
    }

    final body = <String, dynamic>{
      'billNo': _billNo.text.trim(),
      'billDate': _fmt(_billDate),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      // 账户字段名按单据类型：bankTransfer=outAccountId，其余=accountId。
      _cfg.type == FinanceDocType.bankTransfer ? 'outAccountId' : 'accountId':
          _accountId,
      if (_cfg.hasParty)
        _cfg.isClient ? 'clientId' : 'supplierId': _partyId,
      if (_cfg.hasCurrency && _currencyId != null) 'currencyId': _currencyId,
      if (_cfg.hasCurrency) 'exchangeRate': double.tryParse(_rate.text) ?? 1,
      if (_cfg.hasBankFee && _bankFee.text.isNotEmpty)
        'bankFee': double.tryParse(_bankFee.text) ?? 0,
      if (_cfg.hasOtherFee && _otherFee.text.isNotEmpty)
        'otherFee': double.tryParse(_otherFee.text) ?? 0,
      if (_cfg.hasInvoiceNo && _invoiceNo.text.trim().isNotEmpty)
        'invoiceNo': _invoiceNo.text.trim(),
      if (_operatorId != null) 'operatorId': _operatorId,
      'items': itemsBody,
    };

    setState(() => _saving = true);
    try {
      final repo = ref.read(financeRepositoryProvider(widget.docType));
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      context
          .replace('/finance/${_cfg.type.pathSegment}/${d.id}');
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
    final names = ref.watch(financeNameServiceProvider);
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
                              if (_cfg.hasParty)
                                _dropdown(
                                    _cfg.partyLabel,
                                    _partyId,
                                    _cfg.isClient
                                        ? names.clientEntries
                                        : names.supplierEntries,
                                    (v) => setState(() {
                                          _partyId = v;
                                          // 切换往来方后清空已引入的核销行（避免错配）。
                                          _items.clear();
                                        }),
                                    required: true),
                              _dropdown(_cfg.accountLabel, _accountId,
                                  names.accountEntries, (v) => setState(() => _accountId = v),
                                  required: true),
                              if (_cfg.hasCurrency)
                                _dropdown('币种', _currencyId, names.currencyEntries,
                                    (v) => setState(() => _currencyId = v)),
                              if (_cfg.hasCurrency)
                                TextField(
                                  controller: _rate,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: '汇率'),
                                ),
                              if (_cfg.hasBankFee)
                                TextField(
                                  controller: _bankFee,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: '银行手续费'),
                                ),
                              if (_cfg.hasOtherFee)
                                TextField(
                                  controller: _otherFee,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: '其它手续费'),
                                ),
                              if (_cfg.hasInvoiceNo)
                                TextField(
                                  controller: _invoiceNo,
                                  decoration: const InputDecoration(labelText: '发票号'),
                                ),
                              _employeePicker(
                                label: '经办人',
                                currentId: _operatorId,
                                onChanged: (id) => setState(() => _operatorId = id),
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
                        Text('明细 (${_items.length})',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        if (_cfg.hasArApLink)
                          TextButton.icon(
                            onPressed: _importFromArAp,
                            icon: const Icon(Icons.link_rounded, size: 18),
                            label: const Text('从应收应付引入'),
                          ),
                        if (!_cfg.isSettle)
                          TextButton.icon(
                            onPressed: () =>
                                setState(() => _items.add(_ItemRow())),
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('添加行'),
                          ),
                      ],
                    ),
                    for (final row in _items) _itemEditor(theme, names, row),
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

  Widget _itemEditor(ThemeData theme, FinanceNameService names, _ItemRow row) {
    if (_cfg.isSettle) return _settleEditor(theme, row);
    if (_cfg.isAllocate) return _allocateEditor(theme, names, row);
    return _transferEditor(theme, names, row);
  }

  /// 核销行：单据号(只读，来自引入) + 本次金额 + 删除。
  Widget _settleEditor(ThemeData theme, _ItemRow row) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(row.appliedBillNo ?? '直接收款（未指定核销）',
                  style: TextStyle(
                      color: row.appliedBillNo == null
                          ? theme.colorScheme.onSurfaceVariant
                          : null)),
            ),
            Expanded(
              child: TextField(
                controller: row.amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    isDense: true, labelText: '本次金额'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() {
                _items.remove(row);
                row.dispose();
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// 分摊行：项目下拉 + 部门(UUID 文本，TODO 升级 picker) + 数量/单价 + 金额 + 删除。
  Widget _allocateEditor(ThemeData theme, FinanceNameService names, _ItemRow row) {
    final cat = _cfg.type == FinanceDocType.expense ? 'EXPENSE' : 'INCOME';
    final styles = names.stylesFor(cat);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: row.styleId,
                  isExpanded: true,
                  decoration: InputDecoration(
                      isDense: true,
                      labelText: _cfg.type == FinanceDocType.expense
                          ? '费用项目'
                          : '收入项目'),
                  items: [
                    const DropdownMenuItem<String?>(child: Text('— 不选 —')),
                    for (final s in styles)
                      DropdownMenuItem<String?>(
                        value: s.id,
                        child: Text(s.name ?? s.id,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => row.styleId = v),
                ),
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
            // TODO(finance): 升级为部门 picker（当前先用 UUID 文本输入）。
            TextField(
              decoration: const InputDecoration(
                  isDense: true, labelText: '分摊部门ID（可空）'),
              onChanged: (v) => row.departmentId =
                  v.trim().isEmpty ? null : v.trim(),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: row.qty,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(isDense: true, labelText: '数量'),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextField(
                  controller: row.price,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(isDense: true, labelText: '单价'),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextField(
                  controller: row.amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(isDense: true, labelText: '金额 *'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  /// 转入行：转入账户下拉 + 日期 + 金额 + 删除。
  Widget _transferEditor(ThemeData theme, FinanceNameService names, _ItemRow row) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: row.inAccountId,
                  isExpanded: true,
                  decoration:
                      const InputDecoration(isDense: true, labelText: '转入账户'),
                  items: [
                    const DropdownMenuItem<String?>(child: Text('— 不选 —')),
                    for (final e in names.accountEntries.entries)
                      DropdownMenuItem<String?>(
                        value: e.key,
                        child: Text(e.value,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => row.inAccountId = v),
                ),
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
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('日期'),
                  subtitle: Text(row.occurDate == null
                      ? '未选择'
                      : row.occurDate!.substring(0, 10)),
                  trailing:
                      const Icon(Icons.event_outlined, size: 18),
                  onTap: () => _pickDate(
                    current: row.occurDate == null
                        ? null
                        : DateTime.tryParse(row.occurDate!),
                    onPicked: (d) =>
                        setState(() => row.occurDate = _fmt(d)),
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: TextField(
                  controller: row.amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(isDense: true, labelText: '金额 *'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
