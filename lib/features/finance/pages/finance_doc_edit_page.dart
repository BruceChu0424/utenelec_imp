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
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_import_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../../shared/widgets/sales_order_picker.dart';
import '../../basic_data/models/client_node.dart';
import '../../basic_data/models/reference_method_option.dart';
import '../../basic_data/repositories/reference_method_repository.dart';
import '../../basic_data/widgets/uten_client_picker.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_decimal.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/customer_prepayment_repository.dart';
import '../repositories/finance_repository.dart';
import '../widgets/ar_ap_picker_dialog.dart';
import '../widgets/customer_prepayment_apply_panel.dart';
import '../widgets/customer_prepayment_receipt_fields.dart';
import '../widgets/finance_grid_columns.dart';

const _receiptKindArSettlement = 'AR_SETTLEMENT';
const _receiptKindCustomerPrepayment = 'CUSTOMER_PREPAYMENT';
const _settlementChannelDirect = 'DIRECT_ACCOUNT';
const _settlementChannelAgent = 'TRADE_AGENT_CONVERSION';
const _rateSourceBank = 'BANK_STATEMENT';
const _rateSourceAgent = 'TRADE_AGENT_STATEMENT';
const _feeModeNone = 'NONE';
const _feeModeDeducted = 'DEDUCTED_FROM_PROCEEDS';
const _feeModeSeparate = 'PAID_SEPARATELY';

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
  final _rate = TextEditingController();
  final _amountOriginal = TextEditingController();
  final _accountAmount = TextEditingController();
  final _bankFee = TextEditingController();
  final _otherFee = TextEditingController();
  final _invoiceNo = TextEditingController();
  final _bankReference = TextEditingController();
  final _agentStatementNo = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();
  DateTime _exchangeRateEffectiveAt = ChinaDateTime.now();
  DateTime _bankBookedAt = ChinaDateTime.now();

  String? _accountId;
  String? _partyId; // clientId / supplierId
  String? _currencyId;
  String? _otherFeeStyleId;
  String? _settlementAgentSupplierId;
  String? _feePaymentAccountId;
  String? _financePaymentMethodId;
  String? _operatorId;
  String _settlementChannel = _settlementChannelDirect;
  String _exchangeRateSource = _rateSourceBank;
  String _feeSettlementMode = _feeModeNone;
  final String _createIdempotencyKey = const Uuid().v4();
  int? _expectedVersion;
  String _receiptKind = _receiptKindArSettlement;
  String? _receiptSalesOrderId;
  String? _receiptSalesOrderBillNo;
  int _clientPickerRevision = 0;
  final Map<String, UtenEmployeePickerItem> _empCache = {};

  final _grid = UtenEditableGridController<FinanceGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loading = true;
  String? _initializationError;
  String? _paymentCurrencyError;
  String? _paymentRateError;
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

  bool get _isCustomerPrepayment =>
      _cfg.type == FinanceDocType.receipt &&
      _receiptKind == _receiptKindCustomerPrepayment;

  @override
  void initState() {
    super.initState();
    // 付款汇率必须由财务明确填写，其他旧单据保留原有默认值。
    if (_cfg.type != FinanceDocType.payment) _rate.text = '1';
    _rate.addListener(_syncReceiptRateToRows);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _billNo.dispose();
    _remark.dispose();
    _rate.dispose();
    _amountOriginal.dispose();
    _accountAmount.dispose();
    _bankFee.dispose();
    _otherFee.dispose();
    _invoiceNo.dispose();
    _bankReference.dispose();
    _agentStatementNo.dispose();
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _initializationError = null;
    });
    try {
      final names = ref.read(financeNameServiceProvider);
      await names.ensureLoaded(refreshAccounts: true);
      if (_cfg.isAllocate || _cfg.type == FinanceDocType.receipt) {
        await ref
            .read(financeNameServiceProvider)
            .loadStyleCategory(
              _cfg.type == FinanceDocType.otherIncome ? 'INCOME' : 'EXPENSE',
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
        final d = await ref
            .read(financeRepositoryProvider(widget.docType))
            .detail(widget.id!);
        final writable =
            d.status == kFinanceStatusDraft &&
            await loadDocumentOwnerCanWrite(
              ref,
              DocumentDataScope.finance,
              d.makerId,
            );
        if (!mounted) return;
        if (!writable) {
          context.appWarning(documentScopeReadOnlyMessage, force: true);
          context.replace(
            RoutePath.financeDocDetail(_cfg.type.pathSegment, widget.id!),
          );
          return;
        }
        await _preloadEmployees([d.operatorId]);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        _bankFee.text = d.bankFeeAccountAmountText ?? d.bankFeeText ?? '';
        _otherFee.text = d.otherFeeAccountAmountText ?? d.otherFeeText ?? '';
        _invoiceNo.text = d.invoiceNo ?? '';
        _accountAmount.text = d.accountAmountText ?? '';
        _bankReference.text = d.bankReference ?? '';
        _agentStatementNo.text = d.agentStatementNo ?? '';
        _expectedVersion = d.version;
        _settlementChannel = d.settlementChannel ?? _settlementChannelDirect;
        _settlementAgentSupplierId = d.settlementAgentSupplierId;
        _exchangeRateSource =
            d.exchangeRateSource ??
            (_settlementChannel == _settlementChannelAgent
                ? _rateSourceAgent
                : _rateSourceBank);
        _exchangeRateEffectiveAt =
            ChinaDateTime.tryParse(d.exchangeRateEffectiveAt) ??
            _exchangeRateEffectiveAt;
        _bankBookedAt = ChinaDateTime.tryParse(d.bankBookedAt) ?? _bankBookedAt;
        _feeSettlementMode = d.feeSettlementMode ?? _feeModeNone;
        _feePaymentAccountId = d.feePaymentAccountId;
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        if (_cfg.type == FinanceDocType.receipt) {
          _receiptKind =
              d.receiptKind ??
              (d.items.isEmpty
                  ? _receiptKindCustomerPrepayment
                  : _receiptKindArSettlement);
          _receiptSalesOrderId = d.salesOrderId;
          if (d.salesOrderId case final orderId?) {
            try {
              final summary = await ref
                  .read(customerPrepaymentRepositoryProvider)
                  .salesOrderSummary(orderId);
              _receiptSalesOrderBillNo = summary.orderBillNo;
            } catch (_) {
              // UUID 保持可见；资金卡自身提供重试，不用可变单号回查。
            }
          }
        }
        _accountId = d.accountId ?? d.outAccountId;
        _partyId = d.clientId ?? d.supplierId;
        _currencyId = d.currencyId;
        _otherFeeStyleId = d.otherFeeStyleId;
        _financePaymentMethodId =
            _cfg.type == FinanceDocType.receipt ||
                _cfg.type == FinanceDocType.otherIncome
            ? d.receiptMethodId
            : d.paymentMethodId;
        _rate.text =
            d.exchangeRateText ??
            d.items.firstOrNull?.exchangeRateText ??
            (_cfg.type == FinanceDocType.payment ? '' : '1');
        _amountOriginal.text =
            d.amountOriginalText ?? d.amountOriginal?.toString() ?? '';
        _operatorId = d.operatorId;
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        final rows = <FinanceGridRow>[];
        for (final it in d.items) {
          final row = FinanceGridRow(mode: _cfg.itemMode)
            ..appliedLedgerId = it.appliedLedgerId
            ..appliedBillNo = it.appliedBillNo
            ..authoritativeSalesOrderId = it.salesOrderId
            ..salesOrderIds = it.salesOrderId == null
                ? const []
                : [it.salesOrderId!]
            ..currencyId =
                it.currencyId ??
                (_cfg.type == FinanceDocType.payment ? d.currencyId : null)
            ..balanceOriginal = it.balanceBeforeOriginal
            ..balanceOriginalText = it.balanceBeforeOriginalText
            ..styleId = it.expenseStyleId ?? it.incomeStyleId
            ..inAccountId = it.inAccountId
            ..occurDate = it.occurDate;
          row.department.text = it.departmentId ?? '';
          row.qty.text = it.qty?.toString() ?? '';
          row.price.text = it.price?.toString() ?? '';
          row.amount.text = _cfg.isSettle
              ? it.amountOriginalText ?? it.amountLocal?.toString() ?? ''
              : it.amountLocal?.toString() ?? '';
          row.exchangeRate.text = _cfg.type == FinanceDocType.receipt
              ? _rate.text
              : (it.exchangeRateText ?? '');
          row.writeOff.text = d.settlementAuthorityVersion == 1
              ? '0'
              : (it.writeOffAmountText ?? '0');
          row.remark.text = it.remark ?? '';
          rows.add(row);
        }
        _grid.replaceAll(rows);
        _syncReceiptRateToRows();
      }
      if (_grid.isEmpty && !_cfg.isSettle) {
        _grid.addRow(FinanceGridRow(mode: _cfg.itemMode));
      }
    } on ApiException catch (e) {
      _initializationError = e.message;
    } catch (_) {
      _initializationError = '无法读取完整单据数据，请检查网络或权限后重试';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
            employeeCode: p.code,
            departmentName: p.departmentName,
          );
        } catch (_) {
          /* 静默 */
        }
      }),
    );
  }

  void _syncReceiptRateToRows() {
    if (_cfg.type != FinanceDocType.receipt) return;
    final value = _rate.text.trim();
    for (final row in _grid.rows) {
      if (row.exchangeRate.text != value) {
        row.exchangeRate.text = value;
      }
      if (row.writeOff.text != '0') row.writeOff.text = '0';
    }
  }

  /// 「从应收应付引入」：弹核销选择器，把所选 AppliedArAp 映射成行追加。
  Future<void> _importFromArAp() async {
    if (_partyId == null || _partyId!.isEmpty) {
      context.appError('请先选择${_cfg.partyLabel}');
      return;
    }
    final direction = _cfg.isClient ? 'AR' : 'AP';
    String? lockedCurrencyId;
    if (_cfg.isSettle) {
      final detailCurrencies = _grid.rows
          .map((row) => row.currencyId)
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet();
      if (detailCurrencies.length > 1) {
        context.appError(
          '当前${_cfg.isClient ? '应收' : '应付'}核销明细存在多币种，请删除冲突明细后再引用',
        );
        return;
      }
      lockedCurrencyId = detailCurrencies.isEmpty
          ? _currencyId
          : detailCurrencies.single;
      if (_currencyId != null &&
          lockedCurrencyId != null &&
          _currencyId != lockedCurrencyId) {
        context.appError('${_cfg.isClient ? '收款' : '付款'}头币种与已选明细不一致，请先修正当前单据');
        return;
      }
    }
    final picked = await showArApPickerDialog(
      context,
      ref,
      direction: direction,
      partyId: _partyId,
      lockedCurrencyId: lockedCurrencyId,
    );
    if (!mounted) return;
    if (picked == null || picked.isEmpty) return;
    final existing = _grid.rows
        .map((row) => row.appliedLedgerId)
        .whereType<String>()
        .toSet();
    final additions = picked
        .where((item) => existing.add(item.ledgerId))
        .toList();
    if (additions.isEmpty) {
      context.appError('所选${_cfg.isClient ? '应收' : '应付'}已在当前明细中，无需重复引用');
      return;
    }
    if (_cfg.isSettle) {
      final pickedCurrencies = additions
          .map((item) => item.currencyId)
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet();
      if (pickedCurrencies.length != 1 ||
          additions.any(
            (item) => item.currencyId == null || item.currencyId!.isEmpty,
          )) {
        context.appError('所选${_cfg.isClient ? '应收' : '应付'}明细必须使用同一个已核验币种');
        return;
      }
      final pickedCurrencyId = pickedCurrencies.single;
      if (lockedCurrencyId != null && pickedCurrencyId != lockedCurrencyId) {
        context.appError('所选${_cfg.isClient ? '应收' : '应付'}明细币种与本批币种不一致');
        return;
      }
      setState(() {
        _currencyId = pickedCurrencyId;
        _paymentCurrencyError = null;
      });
    }
    _grid.addRows(
      additions.map((a) => FinanceGridRow.fromApplied(_cfg.itemMode, a)),
    );
    _syncReceiptRateToRows();
    if (_cfg.type == FinanceDocType.receipt) {
      _alignReceiptChannelWithAccount();
    }
  }

  void _alignReceiptChannelWithAccount() {
    if (_cfg.type != FinanceDocType.receipt) return;
    final names = ref.read(financeNameServiceProvider);
    final accountCurrencyId = names.accountCurrencyId(_accountId);
    final settlementCurrencyId = _currencyId;
    if (accountCurrencyId == null || settlementCurrencyId == null) return;
    setState(() {
      if (accountCurrencyId == settlementCurrencyId) {
        _settlementChannel = _settlementChannelDirect;
        _exchangeRateSource = _rateSourceBank;
        _settlementAgentSupplierId = null;
      } else if (names.accountIsBaseCurrency(_accountId) == true) {
        _settlementChannel = _settlementChannelAgent;
        _exchangeRateSource = _rateSourceAgent;
      }
    });
  }

  Future<void> _applyCustomerPrepayment() async {
    final clientId = _partyId;
    if (clientId == null || clientId.isEmpty) {
      context.appWarning('请先选择客户，再应用该客户的预收');
      return;
    }
    if (!_grid.isEmpty) {
      context.appWarning('当前已有引用应收明细；请先清空后再应用预收，避免使用过期余额');
      return;
    }
    final result = await showCustomerPrepaymentApplyPanel(
      context,
      clientId: clientId,
    );
    if (!mounted || result == null) return;
    bumpListRefresh(ref, _cfg.refreshKey);
    context.appSuccess(
      result.status == 'REVERSED'
          ? '预收抵销批次已反转，应收余额已刷新'
          : '预收抵销已完成，批次 ${result.batchId}',
    );
  }

  Future<bool> _confirmReceiptClientChange() async {
    if (_grid.isEmpty) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更换客户'),
        content: const Text('更换客户会清空已引用的应收明细，是否继续？'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续更换'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<ClientListItem?> _pickReceiptClient() async {
    final selected = await showUtenClientPicker(context, ref);
    if (!mounted || selected == null || selected.id == _partyId) {
      return selected;
    }
    if (!await _confirmReceiptClientChange()) return null;
    _grid.clear();
    return selected;
  }

  Future<void> _onReceiptClientChanged(String? nextId) async {
    if (nextId == _partyId) return;
    // 选择新客户在 picker 返回前已确认；清除按钮则从这里补做确认。
    if (nextId == null && !_grid.isEmpty) {
      if (!await _confirmReceiptClientChange()) {
        if (mounted) setState(() => _clientPickerRevision++);
        return;
      }
      _grid.clear();
    }
    if (mounted) setState(() => _partyId = nextId);
  }

  void _onReceiptKindChanged(String? next) {
    if (next == null || next == _receiptKind) return;
    if (next == _receiptKindCustomerPrepayment && !_grid.isEmpty) {
      context.appWarning('切换为客户预收前，请先删除全部已引用应收明细');
      return;
    }
    setState(() {
      _receiptKind = next;
      _receiptSalesOrderId = null;
      _receiptSalesOrderBillNo = null;
      _currencyId = null;
      _rate.clear();
      _amountOriginal.clear();
      if (next == _receiptKindCustomerPrepayment) {
        _grid.clear();
        _bankFee.clear();
        _otherFee.clear();
        _otherFeeStyleId = null;
      }
    });
  }

  void _onPrepaymentOrderSelected(SalesDocListItem order) {
    if (order.status != kSalesStatusApproved || order.stopped || order.closed) {
      context.appWarning('客户订单预收只能绑定已审核、未中止且未结案的销售订单');
      return;
    }
    final clientId = order.clientId;
    final currencyId = order.currencyId;
    if (clientId == null ||
        clientId.isEmpty ||
        currencyId == null ||
        currencyId.isEmpty) {
      context.appWarning('所选销售订单缺少客户或币种，不能登记客户预收');
      return;
    }
    setState(() {
      _receiptSalesOrderId = order.id;
      _receiptSalesOrderBillNo = order.billNo;
      _partyId = clientId;
      _currencyId = currencyId;
      _rate.clear();
      _amountOriginal.clear();
      _grid.clear();
      _bankFee.clear();
      _otherFee.clear();
      _otherFeeStyleId = null;
    });
    _alignReceiptChannelWithAccount();
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
    if (_cfg.type != FinanceDocType.bankTransfer &&
        _financePaymentMethodId == null) {
      context.appError(
        '请选择${_cfg.type == FinanceDocType.receipt || _cfg.type == FinanceDocType.otherIncome ? '收款' : '付款'}方式',
      );
      return;
    }
    String? paymentRate;
    if (_cfg.type == FinanceDocType.payment) {
      if (_currencyId == null || _currencyId!.isEmpty) {
        setState(() => _paymentCurrencyError = '请选择付款币种');
        context.appError('请选择付款币种');
        return;
      }
      final paymentRateUnits = financeExactDecimalUnits(
        _rate.text.trim(),
        scale: 6,
      );
      if (paymentRateUnits == null || paymentRateUnits <= BigInt.zero) {
        setState(() => _paymentRateError = '请填写大于 0 的付款汇率');
        context.appError('请填写大于 0 的付款汇率');
        return;
      }
      paymentRate = financeExactDecimalFromUnits(paymentRateUnits, scale: 6);
    }
    if (_isCustomerPrepayment) {
      if (_receiptSalesOrderId == null) {
        context.appError('请选择要登记预收的已审核销售订单');
        return;
      }
      if (_partyId == null || _currencyId == null) {
        context.appError('销售订单缺少客户或币种，请重新选择订单');
        return;
      }
      if (!_grid.isEmpty) {
        context.appError('客户预收不能包含普通应收核销明细');
        return;
      }
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in _grid.rows) {
      if (_cfg.type == FinanceDocType.receipt) {
        final ledgerId = r.appliedLedgerId;
        if (ledgerId == null || ledgerId.isEmpty) {
          context.appError('销售收款明细必须引用应收单');
          return;
        }
        final amountUnits = financeExactDecimalUnits(r.amount.text.trim());
        if (amountUnits == null || amountUnits <= BigInt.zero) {
          context.appError('请填写大于 0 的本批 AR 核销原币金额');
          return;
        }
        final amountOriginal = financeExactDecimalFromUnits(amountUnits);
        final currencyId = r.currencyId;
        if (currencyId == null || currencyId.isEmpty) {
          context.appError('引用的应收币别缺失，请重新引用应收');
          return;
        }
        if (_currencyId != null && currencyId != _currencyId) {
          context.appError('同一收款批次只能核销同一原币的应收');
          return;
        }
        final exchangeRate = _rate.text.trim();
        final rateUnits = financeExactDecimalUnits(exchangeRate, scale: 6);
        if (rateUnits == null || rateUnits <= BigInt.zero) {
          context.appError('请填写大于 0、最多 6 位小数的当前批次实际汇率');
          return;
        }
        final lineRemark = r.remark.text.trim();
        itemsBody.add({
          'appliedLedgerId': ledgerId,
          'appliedBillNo': r.appliedBillNo,
          'clientId': _partyId,
          'currencyId': currencyId,
          'exchangeRate': financeExactDecimalFromUnits(rateUnits, scale: 6),
          'amountOriginal': amountOriginal,
          'writeOffAmount': '0.0000',
          'remark': lineRemark.isEmpty ? null : lineRemark,
        });
        continue;
      }

      if (_cfg.type == FinanceDocType.payment) {
        final ledgerId = r.appliedLedgerId;
        if (ledgerId == null || ledgerId.isEmpty) {
          context.appError('采购付款核销明细必须引用应付单');
          return;
        }
        if (r.currencyId == null || r.currencyId!.isEmpty) {
          context.appError('引用的应付币别缺失，请重新引用应付');
          return;
        }
        if (r.currencyId != _currencyId) {
          context.appError('应付核销明细币种必须与付款头币种一致');
          return;
        }
        final amountUnits = financeExactDecimalUnits(r.amount.text.trim());
        if (amountUnits == null || amountUnits <= BigInt.zero) {
          context.appError('请填写大于 0、最多 4 位小数的本次付款原币金额');
          return;
        }
        final amountOriginal = financeExactDecimalFromUnits(amountUnits);
        final lineRemark = r.remark.text.trim();
        itemsBody.add({
          'appliedLedgerId': ledgerId,
          'appliedBillNo': r.appliedBillNo,
          'amountOriginal': amountOriginal,
          'remark': lineRemark.isEmpty ? null : lineRemark,
        });
        continue;
      }

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
    if (_cfg.type == FinanceDocType.receipt &&
        !_isCustomerPrepayment &&
        itemsBody.isEmpty) {
      context.appError('请至少引用一条应收明细');
      return;
    }
    final receiptAuthorityBody = _cfg.type == FinanceDocType.receipt
        ? _buildReceiptAuthorityBody(itemsBody)
        : null;
    if (_cfg.type == FinanceDocType.receipt && receiptAuthorityBody == null) {
      return;
    }
    if (_cfg.type == FinanceDocType.payment && itemsBody.isEmpty) {
      context.appError('供应商预付资产、应用和退款链尚未开放；请先引用已入账应付');
      return;
    }
    // 采购付款必须引用已入账 AP；供应商预付链交付前失败关闭。
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
      if (_cfg.type == FinanceDocType.receipt) 'receiptKind': _receiptKind,
      if (_isCustomerPrepayment) 'salesOrderId': _receiptSalesOrderId,
      if (_cfg.type == FinanceDocType.receipt) ...receiptAuthorityBody!,
      if (_cfg.type == FinanceDocType.payment && widget.id == null)
        'createIdempotencyKey': _createIdempotencyKey,
      if (_cfg.type == FinanceDocType.payment &&
          widget.id != null &&
          _expectedVersion != null)
        'expectedVersion': _expectedVersion,
      if (_cfg.hasCurrency &&
          _cfg.type != FinanceDocType.receipt &&
          _currencyId != null)
        'currencyId': _currencyId,
      if (_cfg.hasCurrency && _cfg.type != FinanceDocType.receipt)
        'exchangeRate': _cfg.type == FinanceDocType.payment
            ? paymentRate
            : double.tryParse(_rate.text) ?? 1,
      if (_cfg.hasOtherFee && _otherFeeStyleId != null)
        'otherFeeStyleId': _otherFeeStyleId,
      if (_cfg.hasInvoiceNo && _invoiceNo.text.trim().isNotEmpty)
        'invoiceNo': _invoiceNo.text.trim(),
      if (_operatorId != null) 'operatorId': _operatorId,
      if (_financePaymentMethodId != null &&
          (_cfg.type == FinanceDocType.receipt ||
              _cfg.type == FinanceDocType.otherIncome))
        'receiptMethodId': _financePaymentMethodId,
      if (_financePaymentMethodId != null &&
          (_cfg.type == FinanceDocType.payment ||
              _cfg.type == FinanceDocType.expense))
        'paymentMethodId': _financePaymentMethodId,
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

  Map<String, dynamic>? _buildReceiptAuthorityBody(
    List<Map<String, dynamic>> items,
  ) {
    final names = ref.read(financeNameServiceProvider);
    final accountId = _accountId;
    if (accountId == null) return null;
    if (names.accountLoadError != null) {
      context.appError('账户币种资料未加载成功，请刷新后再保存');
      return null;
    }
    final accountCurrencyId = names.accountCurrencyId(accountId);
    if (accountCurrencyId == null || accountCurrencyId.isEmpty) {
      context.appError('收款账户缺少币种 UUID，请修复账户资料后再保存');
      return null;
    }
    final accountStatus = names.accountStatus(accountId);
    if (accountStatus != null && accountStatus != '使用') {
      context.appError('收款账户已停用，不能登记新到账');
      return null;
    }
    final settlementCurrencyId = _currencyId;
    if (settlementCurrencyId == null || settlementCurrencyId.isEmpty) {
      context.appError('本批应收/预收原币缺失，请重新引用应收或订单');
      return null;
    }
    final rateUnits = financeExactDecimalUnits(_rate.text.trim(), scale: 6);
    if (rateUnits == null || rateUnits <= BigInt.zero) {
      context.appError('请填写大于 0、最多 6 位小数的当前批次实际汇率');
      return null;
    }
    final normalizedRate = financeExactDecimalFromUnits(rateUnits, scale: 6);

    BigInt settlementUnits;
    if (_isCustomerPrepayment) {
      final units = financeExactDecimalUnits(_amountOriginal.text.trim());
      if (units == null || units <= BigInt.zero) {
        context.appError('请填写大于 0、最多 4 位小数的本批预收原币金额');
        return null;
      }
      settlementUnits = units;
    } else {
      settlementUnits = BigInt.zero;
      for (final item in items) {
        final units = financeExactDecimalUnits(
          item['amountOriginal']?.toString(),
        );
        if (units == null || units <= BigInt.zero) {
          context.appError('AR 分配金额精度无效，请重新输入');
          return null;
        }
        settlementUnits += units;
      }
      if (settlementUnits <= BigInt.zero) {
        context.appError('本批 AR 核销原币合计必须大于 0');
        return null;
      }
    }
    final settlementAmount = financeExactDecimalFromUnits(settlementUnits);
    final accountIsBase = names.accountIsBaseCurrency(accountId) == true;
    final sameCurrency = accountCurrencyId == settlementCurrencyId;
    if (!accountIsBase && !sameCurrency) {
      context.appError('暂不支持第三币种收款：收款账户必须是人民币账户或与应收原币相同');
      return null;
    }
    if (_settlementChannel == _settlementChannelAgent) {
      if (!accountIsBase || sameCurrency) {
        context.appError('外贸代理结汇仅支持外币应收结汇进入人民币账户');
        return null;
      }
      if (_settlementAgentSupplierId == null ||
          _settlementAgentSupplierId!.isEmpty) {
        context.appError('请选择实际代收结汇的外贸代理公司');
        return null;
      }
      if (_exchangeRateSource != _rateSourceAgent) {
        context.appError('外贸代理结汇的汇率来源必须是外贸代理结算单');
        return null;
      }
      if (_agentStatementNo.text.trim().isEmpty) {
        context.appError('请填写外贸代理结算单号');
        return null;
      }
    } else if (_exchangeRateSource != _rateSourceBank) {
      context.appError('直接到账的汇率来源必须是银行回单');
      return null;
    }
    if (_bankReference.text.trim().isEmpty) {
      context.appError('请填写真实银行入账流水号');
      return null;
    }

    final grossAccountUnits = sameCurrency
        ? settlementUnits
        : financeExactProductUnits(settlementAmount, normalizedRate);
    if (grossAccountUnits == null || grossAccountUnits <= BigInt.zero) {
      context.appError('按当前批次汇率计算的账户币种毛额无效');
      return null;
    }
    final accountAmountUnits = financeExactDecimalUnits(
      _accountAmount.text.trim(),
    );
    if (accountAmountUnits == null || accountAmountUnits <= BigInt.zero) {
      context.appError('请填写真实收款账户大于 0、最多 4 位小数的实际入账金额');
      return null;
    }
    final bankFeeUnits = financeExactDecimalUnits(
      _bankFee.text.trim().isEmpty ? '0' : _bankFee.text.trim(),
    );
    final otherFeeUnits = financeExactDecimalUnits(
      _otherFee.text.trim().isEmpty ? '0' : _otherFee.text.trim(),
    );
    if (bankFeeUnits == null ||
        otherFeeUnits == null ||
        bankFeeUnits < BigInt.zero ||
        otherFeeUnits < BigInt.zero) {
      context.appError('手续费必须为非负数，最多 4 位小数');
      return null;
    }
    final feeUnits = bankFeeUnits + otherFeeUnits;
    if (otherFeeUnits > BigInt.zero && _otherFeeStyleId == null) {
      context.appError('填写其它费用时请选择其它费用项目');
      return null;
    }

    BigInt expectedAccountAmount;
    switch (_feeSettlementMode) {
      case _feeModeNone:
        if (feeUnits != BigInt.zero) {
          context.appError('存在手续费时，费用结算方式不能选择“无费用”');
          return null;
        }
        expectedAccountAmount = grossAccountUnits;
        break;
      case _feeModeDeducted:
        if (feeUnits == BigInt.zero) {
          context.appError('从到账扣除费用时，请填写实际扣除的手续费');
          return null;
        }
        expectedAccountAmount = grossAccountUnits - feeUnits;
        if (expectedAccountAmount <= BigInt.zero) {
          context.appError('扣除费用后的真实账户净入必须大于 0');
          return null;
        }
        break;
      case _feeModeSeparate:
        if (feeUnits == BigInt.zero) {
          context.appError('费用另付时，请填写实际另付的手续费');
          return null;
        }
        final feeAccountId = _feePaymentAccountId;
        if (feeAccountId == null || feeAccountId.isEmpty) {
          context.appError('费用另付时必须选择真实费用付款账户');
          return null;
        }
        final feeAccountCurrencyId = names.accountCurrencyId(feeAccountId);
        final feeAccountAllowed =
            names.accountIsBaseCurrency(feeAccountId) == true ||
            feeAccountCurrencyId == settlementCurrencyId;
        if (feeAccountCurrencyId == null || !feeAccountAllowed) {
          context.appError('费用付款账户必须是人民币账户或与应收原币同币种，第三币种暂不支持');
          return null;
        }
        final feeAccountStatus = names.accountStatus(feeAccountId);
        if (feeAccountStatus != null && feeAccountStatus != '使用') {
          context.appError('费用付款账户已停用');
          return null;
        }
        expectedAccountAmount = grossAccountUnits;
        break;
      default:
        context.appError('请选择费用结算方式');
        return null;
    }
    if (accountAmountUnits != expectedAccountAmount) {
      final currency = names.accountCurrency(accountId) ?? '账户币种';
      context.appError(
        '真实账户入账应为 $currency '
        '${financeExactUnitsMoneyDisplay(expectedAccountAmount)}，'
        '请按毛额和费用重新核对',
      );
      return null;
    }

    return <String, dynamic>{
      'settlementAuthorityVersion': 1,
      if (widget.id == null) 'createIdempotencyKey': _createIdempotencyKey,
      if (widget.id != null && _expectedVersion != null)
        'expectedVersion': _expectedVersion,
      'settlementChannel': _settlementChannel,
      'settlementAgentSupplierId': _settlementChannel == _settlementChannelAgent
          ? _settlementAgentSupplierId
          : null,
      'exchangeRateSource': _exchangeRateSource,
      'exchangeRateEffectiveAt': ChinaDateTime.wallTimeToUtc(
        _exchangeRateEffectiveAt,
      ).toIso8601String(),
      'bankBookedAt': ChinaDateTime.wallTimeToUtc(_bankBookedAt)
          .toIso8601String(),
      'bankReference': _bankReference.text.trim(),
      'agentStatementNo': _settlementChannel == _settlementChannelAgent
          ? _agentStatementNo.text.trim()
          : null,
      'currencyId': settlementCurrencyId,
      'exchangeRate': normalizedRate,
      'amountOriginal': settlementAmount,
      'accountCurrencyId': accountCurrencyId,
      'accountAmount': financeExactDecimalFromUnits(accountAmountUnits),
      'bankFeeAccountAmount': financeExactDecimalFromUnits(bankFeeUnits),
      'otherFeeAccountAmount': financeExactDecimalFromUnits(otherFeeUnits),
      'feeSettlementMode': _feeSettlementMode,
      'feeBearer': _feeSettlementMode == _feeModeNone ? 'NONE' : 'COMPANY',
      'feePaymentAccountId': _feeSettlementMode == _feeModeSeparate
          ? _feePaymentAccountId
          : null,
    };
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Widget _sectionHeading(
    ThemeData theme, {
    required String title,
    required IconData icon,
    String? description,
  }) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(
          top: UtenSpacing.s12,
          bottom: UtenSpacing.s8,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (description != null)
                    Text(
                      description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _receiptAuthoritySections(ThemeData theme, FinanceNameService names) {
    final accountCurrency = names.accountCurrency(_accountId) ?? '账户币种';
    final feeAccountId = _feeSettlementMode == _feeModeSeparate
        ? _feePaymentAccountId
        : _accountId;
    final feeCurrency = names.accountCurrency(feeAccountId) ?? '费用账户币种';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeading(
          theme,
          title: '银行到账与汇率',
          icon: Icons.account_balance_outlined,
          description: '先记录真实到账账户与净入金额，再用同一批次汇率核销原币应收。',
        ),
        UtenFormGrid(
          children: [
            _dropdown(
              '结算渠道',
              _settlementChannel,
              const {
                _settlementChannelDirect: '真实账户直接到账',
                _settlementChannelAgent: '外贸代理代收结汇',
              },
              (value) {
                if (value == null) return;
                setState(() {
                  _settlementChannel = value;
                  _exchangeRateSource = value == _settlementChannelAgent
                      ? _rateSourceAgent
                      : _rateSourceBank;
                  if (value != _settlementChannelAgent) {
                    _settlementAgentSupplierId = null;
                    _agentStatementNo.clear();
                  }
                });
              },
              required: true,
            ),
            if (_settlementChannel == _settlementChannelAgent)
              _dropdown(
                '外贸代理公司',
                _settlementAgentSupplierId,
                names.supplierEntries,
                (value) => setState(() => _settlementAgentSupplierId = value),
                required: true,
              ),
            _dropdown('真实收款账户', _accountId, names.accountEntries, (value) {
              setState(() => _accountId = value);
              _alignReceiptChannelWithAccount();
            }, required: true),
            InputDecorator(
              decoration: const InputDecoration(labelText: '应收/预收原币(锁定)'),
              child: Text(
                _currencyId == null
                    ? '随应收或销售订单锁定'
                    : names.currency(_currencyId),
              ),
            ),
            _requiredPositiveNumberField(
              key: const ValueKey('finance-receipt-exchange-rate'),
              label: '当前批次实际汇率',
              controller: _rate,
              helperMessage: '最多 6 位小数；同一收款批次的全部 AR 分配共用该汇率',
              onChanged: (_) {},
            ),
            _dropdown(
              '汇率来源',
              _exchangeRateSource,
              const {_rateSourceBank: '银行回单', _rateSourceAgent: '外贸代理结算单'},
              (value) {
                if (value != null) setState(() => _exchangeRateSource = value);
              },
              required: true,
            ),
            _instantField(
              label: '汇率生效时间',
              value: _exchangeRateEffectiveAt,
              onChanged: (value) =>
                  setState(() => _exchangeRateEffectiveAt = value),
            ),
            _instantField(
              label: '银行入账时间',
              value: _bankBookedAt,
              onChanged: (value) => setState(() => _bankBookedAt = value),
            ),
            _requiredPositiveNumberField(
              key: const ValueKey('finance-receipt-account-amount'),
              label: '真实账户实际入账($accountCurrency)',
              controller: _accountAmount,
              helperMessage: '必须与银行流水一致；扣费时填扣费后的净入，另付时填本批毛额',
              onChanged: (_) {},
            ),
            TextField(
              key: const ValueKey('finance-receipt-bank-reference'),
              controller: _bankReference,
              decoration: const InputDecoration(
                labelText: '银行入账流水号',
                helper: UtenFieldMessage.helper('用于银行对账和审计追溯'),
              ),
            ),
            if (_settlementChannel == _settlementChannelAgent)
              TextField(
                key: const ValueKey('finance-receipt-agent-statement-no'),
                controller: _agentStatementNo,
                decoration: const InputDecoration(labelText: '外贸代理结算单号'),
              ),
          ],
        ),
        _sectionHeading(
          theme,
          title: '费用',
          icon: Icons.receipt_long_outlined,
          description: '费用与 AR 核销分开记录；有费用时承担方固定为本公司。客户或外贸公司承担须走应收/索赔，不能混记费用。',
        ),
        UtenFormGrid(
          children: [
            _dropdown(
              '费用结算方式',
              _feeSettlementMode,
              const {
                _feeModeNone: '无费用',
                _feeModeDeducted: '从本批到账中扣除',
                _feeModeSeparate: '由其它真实账户另付',
              },
              (value) {
                if (value == null) return;
                setState(() {
                  _feeSettlementMode = value;
                  if (value != _feeModeSeparate) _feePaymentAccountId = null;
                  if (value == _feeModeNone) {
                    _bankFee.clear();
                    _otherFee.clear();
                    _otherFeeStyleId = null;
                  }
                });
              },
              required: true,
            ),
            if (_feeSettlementMode == _feeModeSeparate)
              _dropdown(
                '费用付款账户',
                _feePaymentAccountId,
                names.accountEntries,
                (value) => setState(() => _feePaymentAccountId = value),
                required: true,
              ),
            TextField(
              key: const ValueKey('finance-receipt-bank-fee-account-amount'),
              controller: _bankFee,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(labelText: '银行手续费($feeCurrency)'),
            ),
            TextField(
              key: const ValueKey('finance-receipt-other-fee-account-amount'),
              controller: _otherFee,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(labelText: '其它费用($feeCurrency)'),
            ),
            _dropdown('其它费用项目', _otherFeeStyleId, {
              for (final style in names.stylesFor('EXPENSE'))
                style.id: style.name ?? style.id,
            }, (value) => setState(() => _otherFeeStyleId = value)),
          ],
        ),
      ],
    );
  }

  Widget _instantField({
    required String label,
    required DateTime value,
    required ValueChanged<DateTime> onChanged,
  }) {
    return Semantics(
      button: true,
      label: '$label，${ChinaDateTime.formatDateTime(value)}',
      child: InkWell(
        borderRadius: UtenRadius.mdAll,
        onTap: _saving
            ? null
            : () async {
                final selected = await _pickWallDateTime(value);
                if (selected != null && mounted) onChanged(selected);
              },
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: const Icon(Icons.schedule_outlined),
          ),
          child: Text(ChinaDateTime.formatDateTime(value)),
        ),
      ),
    );
  }

  Future<DateTime?> _pickWallDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
    );
    if (time == null) return null;
    return ChinaDateTime.wallTime(
      year: date.year,
      month: date.month,
      day: date.day,
      hour: time.hour,
      minute: time.minute,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    final methodDirection =
        _cfg.type == FinanceDocType.receipt ||
            _cfg.type == FinanceDocType.otherIncome
        ? 'RECEIPT'
        : 'PAYMENT';
    final List<ReferenceMethodOption> financeMethods =
        _cfg.type == FinanceDocType.bankTransfer
        ? const <ReferenceMethodOption>[]
        : ref
                  .watch(financePaymentMethodOptionsProvider(methodDirection))
                  .valueOrNull ??
              const <ReferenceMethodOption>[];
    final isReceipt = _cfg.type == FinanceDocType.receipt;
    final compact = context.breakpoint.isCompact;
    final permissions = ref.watch(currentPermissionsProvider);
    final canApplyCustomerPrepayment =
        isReceipt &&
        permissions.contains(Perm.financeViewAll) &&
        permissions.contains(Perm.customerPrepaymentView) &&
        permissions.contains(Perm.customerPrepaymentApply);
    final canRegisterCustomerPrepayment =
        isReceipt &&
        permissions.contains(Perm.financeViewAll) &&
        permissions.contains(Perm.customerPrepaymentView) &&
        permissions.contains(Perm.financeReceiptCreate);
    return Scaffold(
      appBar: UtenAppBar(
        title: _isCustomerPrepayment
            ? '登记订单预收'
            : compact && isReceipt
            ? (widget.id == null ? '新建收款' : '编辑收款')
            : (widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}'),
        // 既可能从列表 push 进（回列表），也可能从 hub 卡片 go 直达新建
        // （栈空，回钱流管理 hub）；故用 popOrBackTo 兼顾两种入口。
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: RouteName.finance),
        ),
        actions:
            !_loading && _initializationError == null && _cfg.skipListOnCreate
            ? compact && isReceipt && !_isCustomerPrepayment
                  ? [
                      PopupMenuButton<String>(
                        key: const ValueKey('receipt-fund-reference-menu'),
                        tooltip: '资金引用',
                        icon: const Icon(Icons.account_balance_wallet_outlined),
                        onSelected: (value) {
                          if (value == 'AR') _importFromArAp();
                          if (value == 'PREPAYMENT') {
                            _applyCustomerPrepayment();
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'AR',
                            child: ListTile(
                              leading: Icon(Icons.receipt_long_outlined),
                              title: Text('引用应收'),
                            ),
                          ),
                          if (canApplyCustomerPrepayment)
                            const PopupMenuItem(
                              value: 'PREPAYMENT',
                              child: ListTile(
                                leading: Icon(Icons.savings_outlined),
                                title: Text('应用预收'),
                              ),
                            ),
                        ],
                      ),
                      IconButton(
                        tooltip: '查看历史',
                        icon: const Icon(Icons.history_rounded),
                        onPressed: () =>
                            context.push('/finance/${_cfg.type.pathSegment}'),
                      ),
                    ]
                  : [
                      if (isReceipt && !_isCustomerPrepayment)
                        UtenImportButton(
                          label: '引用应收',
                          onPressed: _importFromArAp,
                        ),
                      if (canApplyCustomerPrepayment && !_isCustomerPrepayment)
                        UtenButton(
                          type: UtenButtonType.tonal,
                          icon: Icons.savings_outlined,
                          onPressed: _applyCustomerPrepayment,
                          child: const Text('应用预收'),
                        ),
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
            : _initializationError != null
            ? UtenEmpty.error(
                key: const ValueKey('finance-doc-edit-load-error'),
                message: '${_cfg.label}加载失败',
                description:
                    '${_initializationError!}\n当前未加载任何可编辑数据。请重试，或使用左上角返回按钮退出编辑。',
                actionLabel: '重试',
                onAction: _init,
              )
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
                              _sectionHeading(
                                theme,
                                title: '业务依据',
                                icon: Icons.assignment_outlined,
                                description: '销售只确定订单原币；到账账户、汇率和费用由财务在本批收款中记录。',
                              ),
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
                                  if (isReceipt)
                                    UtenDropdownField(
                                      key: const ValueKey(
                                        'finance-receipt-kind',
                                      ),
                                      label: '收款业务',
                                      value: _receiptKind,
                                      allowClear: false,
                                      enabled: canRegisterCustomerPrepayment,
                                      searchable: false,
                                      items: [
                                        const UtenDropdownItem(
                                          value: _receiptKindArSettlement,
                                          label: '普通应收收款',
                                        ),
                                        if (canRegisterCustomerPrepayment ||
                                            _isCustomerPrepayment)
                                          const UtenDropdownItem(
                                            value:
                                                _receiptKindCustomerPrepayment,
                                            label: '登记订单预收',
                                          ),
                                      ],
                                      onChanged: _onReceiptKindChanged,
                                    ),
                                  if (isReceipt && !_isCustomerPrepayment)
                                    ClientPickerField(
                                      key: ValueKey(
                                        'receipt-client-${_partyId ?? 'empty'}-$_clientPickerRevision',
                                      ),
                                      initialId: _partyId,
                                      initialName: _partyId == null
                                          ? null
                                          : names.client(_partyId),
                                      required: true,
                                      onPick: _pickReceiptClient,
                                      onChanged: _onReceiptClientChanged,
                                    )
                                  else if (_cfg.hasParty)
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
                                  if (!isReceipt)
                                    _dropdown(
                                      _cfg.accountLabel,
                                      _accountId,
                                      names.accountEntries,
                                      (v) => setState(() => _accountId = v),
                                      required: true,
                                    ),
                                  if (_cfg.type != FinanceDocType.bankTransfer)
                                    _dropdown(
                                      _cfg.type == FinanceDocType.receipt ||
                                              _cfg.type ==
                                                  FinanceDocType.otherIncome
                                          ? '收款方式'
                                          : '付款方式',
                                      _financePaymentMethodId,
                                      {
                                        for (final method in financeMethods)
                                          method.id:
                                              '${method.code} · ${method.name}',
                                      },
                                      (value) => setState(
                                        () => _financePaymentMethodId = value,
                                      ),
                                      required: true,
                                    ),
                                  if (_cfg.hasCurrency && !isReceipt)
                                    _cfg.type == FinanceDocType.payment
                                        ? ListenableBuilder(
                                            listenable: _grid,
                                            builder: (context, _) {
                                              final locked = !_grid.isEmpty;
                                              final field = _dropdown(
                                                '币种',
                                                _currencyId,
                                                names.currencyEntries,
                                                (v) => setState(() {
                                                  _currencyId = v;
                                                  _paymentCurrencyError = null;
                                                }),
                                                required: true,
                                                enabled: !locked,
                                                errorMessage:
                                                    _paymentCurrencyError,
                                              );
                                              if (!locked) return field;
                                              return Tooltip(
                                                message:
                                                    '已按应付核销明细锁定币种；删除全部明细后可重新选择',
                                                child: Semantics(
                                                  enabled: false,
                                                  hint: '币种已按应付核销明细锁定',
                                                  child: Opacity(
                                                    opacity: 0.65,
                                                    child: field,
                                                  ),
                                                ),
                                              );
                                            },
                                          )
                                        : _dropdown(
                                            '币种',
                                            _currencyId,
                                            names.currencyEntries,
                                            (v) =>
                                                setState(() => _currencyId = v),
                                          ),
                                  if (_cfg.hasCurrency && !isReceipt)
                                    _cfg.type == FinanceDocType.payment
                                        ? _requiredPositiveNumberField(
                                            key: const ValueKey(
                                              'finance-payment-exchange-rate',
                                            ),
                                            label: '付款汇率',
                                            controller: _rate,
                                            errorMessage: _paymentRateError,
                                            onChanged: (_) {
                                              if (_paymentRateError != null) {
                                                setState(
                                                  () =>
                                                      _paymentRateError = null,
                                                );
                                              }
                                            },
                                          )
                                        : TextField(
                                            controller: _rate,
                                            keyboardType:
                                                const TextInputType.numberWithOptions(
                                                  decimal: true,
                                                ),
                                            decoration: const InputDecoration(
                                              labelText: '汇率',
                                            ),
                                          ),
                                  if (_cfg.type == FinanceDocType.payment)
                                    ListenableBuilder(
                                      listenable: _grid,
                                      builder: (context, _) => _grid.isEmpty
                                          ? const InputDecorator(
                                              decoration: InputDecoration(
                                                labelText: '付款原币金额',
                                              ),
                                              child: Text(
                                                '请先引用已入账应付；供应商预付链尚未开放',
                                              ),
                                            )
                                          : const InputDecorator(
                                              decoration: InputDecoration(
                                                labelText: '付款原币金额',
                                              ),
                                              child: Text('由服务端按应付核销明细汇总'),
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
                              if (isReceipt)
                                _receiptAuthoritySections(theme, names),
                              if (isReceipt &&
                                  (_accountId != null ||
                                      names.accountLoadError != null)) ...[
                                const SizedBox(height: UtenSpacing.s12),
                                _receiptAccountCurrencyNotice(theme, names),
                              ],
                              if (_isCustomerPrepayment) ...[
                                _sectionHeading(
                                  theme,
                                  title: '订单预收',
                                  icon: Icons.savings_outlined,
                                  description:
                                      '绑定订单只确定客户与原币；本批实际到账仍按上方账户和费用事实登记。',
                                ),
                                CustomerPrepaymentReceiptFields(
                                  salesOrderId: _receiptSalesOrderId,
                                  salesOrderBillNo: _receiptSalesOrderBillNo,
                                  clientLabel: _partyId == null
                                      ? '随销售订单锁定'
                                      : names.client(_partyId),
                                  currencyLabel: _currencyId == null
                                      ? '随销售订单锁定'
                                      : names.currency(_currencyId),
                                  exchangeRateController: _rate,
                                  amountController: _amountOriginal,
                                  showSettlementFields: false,
                                  enabled: !_saving,
                                  onOrderSelected: _onPrepaymentOrderSelected,
                                ),
                                const SizedBox(height: UtenSpacing.s8),
                                UtenFormGrid(
                                  children: [
                                    _requiredPositiveNumberField(
                                      key: const ValueKey(
                                        'customer-prepayment-receipt-amount',
                                      ),
                                      label: '本批预收原币金额',
                                      controller: _amountOriginal,
                                      helperMessage:
                                          '最多 4 位小数；该金额是客户本批实际支付的订单原币',
                                      onChanged: (_) {},
                                    ),
                                  ],
                                ),
                              ],
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
                      if (!_isCustomerPrepayment) ...[
                        const SizedBox(height: UtenSpacing.s12),
                        Row(
                          children: [
                            Expanded(
                              child: _sectionHeading(
                                theme,
                                title: isReceipt
                                    ? 'AR 分配 (${_grid.length})'
                                    : '明细 (${_grid.length})',
                                icon: Icons.account_tree_outlined,
                                description: isReceipt
                                    ? '每行只记录本批核销原币金额；费用不再写入 AR write-off。'
                                    : null,
                              ),
                            ),
                            if (_cfg.hasArApLink && !isReceipt)
                              UtenImportButton(
                                label: _cfg.type == FinanceDocType.payment
                                    ? '引用应付'
                                    : '从应收应付引入',
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
                            accountBaseCurrency: names.accountIsBaseCurrency(
                              _accountId,
                            ),
                          ),
                          createBlankRow: () =>
                              FinanceGridRow(mode: _cfg.itemMode),
                          showAddRow: !_cfg.isSettle,
                          emptyMessage: isReceipt
                              ? '暂无明细，请点击顶部“引用应收”添加'
                              : _cfg.type == FinanceDocType.payment
                              ? '暂无应付核销明细，请点击顶部“引用应付”添加'
                              : '暂无明细，点击下方按钮添加',
                        ),
                      ],
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: _loading || _initializationError != null
          ? null
          : _bottomBar(theme, isReceipt: isReceipt),
    );
  }

  Widget _bottomBar(ThemeData theme, {required bool isReceipt}) {
    final compact = context.breakpoint.isCompact;
    final names = ref.watch(financeNameServiceProvider);
    final cancel = UtenButton(
      type: UtenButtonType.secondary,
      onPressed: () => context.pop(),
      child: const Text('取消'),
    );
    final save = UtenButton(
      isLoading: _saving,
      icon: Icons.save_outlined,
      onPressed: _saving ? null : _save,
      child: const Text('保存'),
    );

    final Widget content;
    if (compact) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isReceipt)
            _isCustomerPrepayment
                ? _customerPrepaymentHeaderSummary(theme)
                : _receiptSummary(theme, names, compact: true)
          else if (_cfg.type == FinanceDocType.payment)
            _paymentSummary(theme)
          else
            _oldTotal(theme),
          const SizedBox(height: UtenSpacing.s8),
          Row(
            children: [
              Expanded(child: cancel),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(child: save),
            ],
          ),
        ],
      );
    } else {
      content = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: isReceipt
                ? _isCustomerPrepayment
                      ? _customerPrepaymentHeaderSummary(theme)
                      : _receiptSummary(theme, names, compact: false)
                : _cfg.type == FinanceDocType.payment
                ? _paymentSummary(theme)
                : _oldTotal(theme),
          ),
          const SizedBox(width: UtenSpacing.s16),
          cancel,
          const SizedBox(width: UtenSpacing.s12),
          save,
        ],
      );
    }

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: content,
      ),
    );
  }

  Widget _oldTotal(ThemeData theme) => ValueListenableBuilder<double>(
    valueListenable: _grid.totalListenable,
    builder: (_, total, _) => Text(
      '合计 ¥${total.toStringAsFixed(2)}',
      textAlign: TextAlign.center,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
  );

  Widget _paymentSummary(ThemeData theme) => ListenableBuilder(
    listenable: Listenable.merge([
      _grid,
      _grid.totalListenable,
      _amountOriginal,
      _rate,
    ]),
    builder: (context, _) {
      final directAmount = double.tryParse(_amountOriginal.text.trim());
      final original = _grid.isEmpty
          ? (directAmount != null && directAmount.isFinite ? directAmount : 0)
          : _grid.totalListenable.value;
      final rate = double.tryParse(_rate.text.trim());
      final local = rate != null && rate.isFinite && rate > 0
          ? original * rate
          : 0.0;
      return Text(
        '原币合计 ${original.toStringAsFixed(2)} · 预计本币 ¥${local.toStringAsFixed(2)}',
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      );
    },
  );

  Widget _customerPrepaymentHeaderSummary(ThemeData theme) => ListenableBuilder(
    listenable: Listenable.merge([
      _amountOriginal,
      _rate,
      _accountAmount,
      _bankFee,
      _otherFee,
    ]),
    builder: (context, _) {
      final names = ref.read(financeNameServiceProvider);
      final currency = _currencyId == null
          ? '订单币种'
          : names.currency(_currencyId);
      final amount = financeExactMoneyDisplay(_amountOriginal.text.trim());
      final rate = financeExactDecimal(_rate.text.trim()) ?? '—';
      final accountCurrency = names.accountCurrency(_accountId) ?? '账户币种';
      final accountAmount = financeExactMoneyDisplay(
        _accountAmount.text.trim(),
      );
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s4,
        children: [
          Text('本批预收 $currency $amount · 汇率 $rate'),
          Text(
            '真实账户实际入账 $accountCurrency $accountAmount',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    },
  );

  Widget _receiptSummary(
    ThemeData theme,
    FinanceNameService names, {
    required bool compact,
  }) {
    return ListenableBuilder(
      listenable: _grid,
      builder: (context, _) => ListenableBuilder(
        listenable: Listenable.merge([
          _grid.totalListenable,
          _rate,
          _accountAmount,
          _bankFee,
          _otherFee,
          for (final row in _grid.rows) row.amount,
        ]),
        builder: (context, _) {
          var settlementOriginal = BigInt.zero;
          var allocationValid = true;
          for (final row in _grid.rows) {
            final units = financeExactDecimalUnits(row.amount.text.trim());
            if (units == null) {
              allocationValid = false;
            } else {
              settlementOriginal += units;
            }
          }
          final grossLocal = allocationValid
              ? financeExactProductUnits(
                  financeExactDecimalFromUnits(settlementOriginal),
                  _rate.text.trim(),
                )
              : null;
          final accountAmount = financeExactDecimalUnits(
            _accountAmount.text.trim(),
          );
          final bankFee = financeExactDecimalUnits(
            _bankFee.text.trim().isEmpty ? '0' : _bankFee.text.trim(),
          );
          final otherFee = financeExactDecimalUnits(
            _otherFee.text.trim().isEmpty ? '0' : _otherFee.text.trim(),
          );
          final accountCurrency = names.accountCurrency(_accountId) ?? '账户币种';
          final feeAccountId = _feeSettlementMode == _feeModeSeparate
              ? _feePaymentAccountId
              : _accountId;
          final feeCurrency = names.accountCurrency(feeAccountId) ?? '费用账户币种';
          final metrics = [
            _exactSummaryMetric(
              theme,
              '本批结算毛额(人民币)',
              grossLocal ?? BigInt.zero,
              grossLocal != null,
            ),
            _exactCurrencySummaryMetric(
              theme,
              '费用',
              feeCurrency,
              (bankFee ?? BigInt.zero) + (otherFee ?? BigInt.zero),
              bankFee != null && otherFee != null,
            ),
            _exactCurrencySummaryMetric(
              theme,
              '真实账户实际入账',
              accountCurrency,
              accountAmount ?? BigInt.zero,
              accountAmount != null,
              emphasized: true,
            ),
          ];
          return Wrap(
            alignment: compact
                ? WrapAlignment.spaceBetween
                : WrapAlignment.center,
            runAlignment: WrapAlignment.center,
            spacing: compact ? UtenSpacing.s8 : UtenSpacing.s16,
            runSpacing: UtenSpacing.s4,
            children: metrics,
          );
        },
      ),
    );
  }

  Widget _receiptAccountCurrencyNotice(
    ThemeData theme,
    FinanceNameService names,
  ) {
    final currency = names.accountCurrency(_accountId);
    final accountCurrencyId = names.accountCurrencyId(_accountId);
    final thirdCurrency =
        accountCurrencyId != null &&
        _currencyId != null &&
        names.accountIsBaseCurrency(_accountId) != true &&
        accountCurrencyId != _currencyId;
    final isCny = names.accountIsBaseCurrency(_accountId) == true;
    final hasError =
        names.accountLoadError != null || currency == null || thirdCurrency;
    final message = names.accountLoadError != null
        ? '账户币种资料加载失败；当前禁止保存，请刷新后重试。'
        : currency == null
        ? '该账户未返回币种 UUID，请修复账户资料后再保存。'
        : thirdCurrency
        ? '暂不支持第三币种到账：该账户币种为 $currency，必须改选人民币账户或与应收原币相同的账户。'
        : isCny
        ? '该收款账户按人民币记账。结汇毛额与实际银行入账分开记录；扣费模式增加净额，另付模式增加毛额。'
        : '该收款账户按 $currency 原币记账。直接到账必须与应收原币同币种；'
              '人民币仅作为本位币折算，不会虚构进入人民币账户。';
    const batchRule =
        '同一张收款单代表一个到账批次，全部明细必须使用同一应收原币和同一实际到账汇率；'
        '不同到账日期或汇率请分别新建收款单。';
    return Semantics(
      container: true,
      label: '收款账户币种说明',
      child: Container(
        key: const ValueKey('finance-receipt-account-currency-notice'),
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s8),
        decoration: BoxDecoration(
          color: hasError
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.primaryContainer.withValues(alpha: 0.38),
          borderRadius: UtenRadius.mdAll,
        ),
        child: Text(
          '$message\n$batchRule',
          style: theme.textTheme.bodySmall?.copyWith(
            color: hasError
                ? theme.colorScheme.onErrorContainer
                : theme.colorScheme.onPrimaryContainer,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _exactSummaryMetric(
    ThemeData theme,
    String label,
    BigInt value,
    bool valid, {
    bool emphasized = false,
  }) {
    final base = emphasized
        ? theme.textTheme.titleSmall
        : theme.textTheme.bodySmall;
    return Text(
      '$label ${valid ? '¥${financeExactUnitsMoneyDisplay(value)}' : '待校验'}',
      style: base?.copyWith(
        fontWeight: emphasized ? FontWeight.w700 : FontWeight.w600,
        color: valid ? null : theme.colorScheme.error,
      ),
    );
  }

  Widget _exactCurrencySummaryMetric(
    ThemeData theme,
    String label,
    String currency,
    BigInt value,
    bool valid, {
    bool emphasized = false,
  }) {
    final base = emphasized
        ? theme.textTheme.titleSmall
        : theme.textTheme.bodySmall;
    return Text(
      '$label $currency '
      '${valid ? financeExactUnitsMoneyDisplay(value) : '待校验'}',
      style: base?.copyWith(
        fontWeight: emphasized ? FontWeight.w700 : FontWeight.w600,
        color: valid ? null : theme.colorScheme.error,
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
    String? errorMessage,
  }) {
    return UtenDropdownField(
      label: label,
      value: value,
      required: required,
      enabled: enabled,
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

  Widget _requiredPositiveNumberField({
    required Key key,
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    String? helperMessage,
    String? errorMessage,
  }) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        key: key,
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: onChanged,
        decoration: applyRequiredEmpty(
          InputDecoration(
            label: requiredLabel(
              label,
              theme,
              required: true,
              base: theme.inputDecorationTheme.labelStyle,
            ),
            helper: utenFieldHelper(helperMessage),
            error: utenFieldError(errorMessage),
          ),
          theme,
          requiredEmpty: errorMessage == null && value.text.trim().isEmpty,
        ),
      ),
    );
  }
}
