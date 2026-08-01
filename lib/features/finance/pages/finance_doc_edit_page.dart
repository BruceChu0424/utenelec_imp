// 钱流单据编辑页（新建/编辑，全页路由，按 docType 参数化）。
//
// 主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
// - settle（receipt/payment）：明细 = AR/AP 核销行，用「从应收应付引入」对话框选台账行回填；
// - allocate（expense/otherIncome）：明细 = 分摊行（项目下拉 + 数量/单价→金额自动 + 部门）；
// - transfer（bankTransfer）：明细 = 转入行（转入账户 + 日期 + 金额）。
// 差异由 config 驱动（isSettle/isAllocate/isTransfer），列集由 financeGridColumns(mode) 返回。
//
// 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）；
// 发票号（invoiceNo）仍由用户手工录入（未弃用）。日期统一用 UtenDateField。
// 保存组装 body 调 create/update，成功后跳详情。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/buttons/uten_button.dart';
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
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/ar_ap_picker_dialog.dart';
import '../widgets/finance_grid_columns.dart';

class FinanceDocEditPage extends ConsumerStatefulWidget {
  const FinanceDocEditPage({super.key, required this.docType, this.id});
  final FinanceDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<FinanceDocEditPage> createState() => _FinanceDocEditPageState();
}

class _FinanceDocEditPageState extends ConsumerState<FinanceDocEditPage> {
  FinanceDocConfig get _cfg => FinanceDocConfig.by(widget.docType);
  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _bankFee = TextEditingController();
  final _otherFee = TextEditingController();
  final _invoiceNo = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();

  String? _accountId;
  String? _partyId; // clientId / supplierId
  String? _currencyId;
  String? _operatorId;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  final _grid = UtenEditableGridController<FinanceGridRow>();
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
    _bankFee.dispose();
    _otherFee.dispose();
    _invoiceNo.dispose();
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(financeNameServiceProvider).ensureLoaded();
    if (_cfg.isAllocate) {
      await ref
          .read(financeNameServiceProvider)
          .loadStyleCategory(
            _cfg.type == FinanceDocType.expense ? 'EXPENSE' : 'INCOME',
          );
    }
    if (widget.id == null) {
      // 经办人默认当前登录人，界面上可改。
      final meId = ref.read(sessionProvider).user?.employeeId;
      if (meId != null && meId.isNotEmpty) {
        _operatorId = meId;
        await _preloadEmployees([meId]);
      }
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
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        final rows = <FinanceGridRow>[];
        for (final it in d.items) {
          final row = FinanceGridRow(mode: _cfg.itemMode)
            ..appliedLedgerId = it.appliedLedgerId
            ..appliedBillNo = it.appliedBillNo
            ..styleId = it.expenseStyleId ?? it.incomeStyleId
            ..inAccountId = it.inAccountId
            ..occurDate = it.occurDate;
          row.department.text = it.departmentId ?? '';
          row.qty.text = it.qty?.toString() ?? '';
          row.price.text = it.price?.toString() ?? '';
          row.amount.text = it.amountLocal?.toString() ?? '';
          rows.add(row);
        }
        _grid.replaceAll(rows);
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_grid.isEmpty && !_cfg.isSettle) {
      _grid.addRow(FinanceGridRow(mode: _cfg.itemMode));
    }
    if (mounted) setState(() => _loading = false);
  }

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
          /* 静默 */
        }
      }),
    );
  }

  /// 「从应收应付引入」：弹核销选择器，把所选 AppliedArAp 映射成行追加。
  Future<void> _importFromArAp() async {
    if (_partyId == null || _partyId!.isEmpty) {
      context.appError('请先选择${_cfg.partyLabel}');
      return;
    }
    final direction = _cfg.isClient ? 'AR' : 'AP';
    final picked = await showArApPickerDialog(
      context,
      ref,
      direction: direction,
      partyId: _partyId,
    );
    if (picked == null || picked.isEmpty) return;
    _grid.addRows(
      picked.map((a) => FinanceGridRow.fromApplied(_cfg.itemMode, a)),
    );
  }

  Future<void> _save() async {
    if (_accountId == null) {
      context.appError('请选择${_cfg.accountLabel}');
      return;
    }
    if (_cfg.hasParty && _partyId == null) {
      context.appError('请选择${_cfg.partyLabel}');
      return;
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in _grid.rows) {
      // amountNotifier 是所有模式的「金额」真相源：
      // allocate = qty*price；settle/transfer = amount.text 同步。无效输入 → 0 → 跳过。
      final amt = r.amountNotifier.value;
      if (amt <= 0) continue;
      final item = <String, dynamic>{'amountLocal': amt, 'amountOriginal': amt};
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
        final dept = r.department.text.trim();
        if (dept.isNotEmpty) item['departmentId'] = dept;
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

    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'billDate': _fmt(_billDate),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      // 账户字段名按单据类型：bankTransfer=outAccountId，其余=accountId。
      _cfg.type == FinanceDocType.bankTransfer ? 'outAccountId' : 'accountId':
          _accountId,
      if (_cfg.hasParty) _cfg.isClient ? 'clientId' : 'supplierId': _partyId,
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
      bumpListRefresh(ref, _cfg.refreshKey);
      context.replace('/finance/${_cfg.type.pathSegment}/${d.id}');
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
    final names = ref.watch(financeNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}',
        // 既可能从列表 push 进（回列表），也可能从 hub 卡片 go 直达新建
        // （栈空，回钱流管理 hub）；故用 popOrBackTo 兼顾两种入口。
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: RouteName.finance),
        ),
        actions: _cfg.skipListOnCreate
            ? [
                UtenButton(
                  type: UtenButtonType.tonal,
                  icon: Icons.history_rounded,
                  onPressed: () =>
                      context.push('/finance/${_cfg.type.pathSegment}'),
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
                                        _grid.clear();
                                      }),
                                      required: true,
                                    ),
                                  _dropdown(
                                    _cfg.accountLabel,
                                    _accountId,
                                    names.accountEntries,
                                    (v) => setState(() => _accountId = v),
                                    required: true,
                                  ),
                                  if (_cfg.hasCurrency)
                                    _dropdown(
                                      '币种',
                                      _currencyId,
                                      names.currencyEntries,
                                      (v) => setState(() => _currencyId = v),
                                    ),
                                  if (_cfg.hasCurrency)
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
                                  if (_cfg.hasBankFee)
                                    TextField(
                                      controller: _bankFee,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      decoration: const InputDecoration(
                                        labelText: '银行手续费',
                                      ),
                                    ),
                                  if (_cfg.hasOtherFee)
                                    TextField(
                                      controller: _otherFee,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      decoration: const InputDecoration(
                                        labelText: '其它手续费',
                                      ),
                                    ),
                                  if (_cfg.hasInvoiceNo)
                                    TextField(
                                      controller: _invoiceNo,
                                      decoration: const InputDecoration(
                                        labelText: '发票号',
                                      ),
                                    ),
                                  _employeePicker(
                                    label: '经办人',
                                    currentId: _operatorId,
                                    defaultDeptCode: kDeptCodeFinance,
                                    onChanged: (id) =>
                                        setState(() => _operatorId = id),
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
                          if (_cfg.hasArApLink)
                            UtenImportButton(
                              label: '从应收应付引入',
                              onPressed: _importFromArAp,
                            ),
                        ],
                      ),
                      UtenEditableGrid<FinanceGridRow>(
                        controller: _grid,
                        columns: financeGridColumns(
                          _cfg.itemMode,
                          names: names,
                          type: _cfg.type,
                        ),
                        createBlankRow: () =>
                            FinanceGridRow(mode: _cfg.itemMode),
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
