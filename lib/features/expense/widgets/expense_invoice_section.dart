// 报销单发票登记区（V608）：结构化发票要素表格 + 登记/编辑弹窗（图片识别回填 +
// 查重即时提示）。DRAFT/REJECTED 且本人可维护（编辑/删除走行菜单）；审批/打款
// 侧与只读访客仅浏览。防重复报销（财会〔2020〕6 号）由「代码+号码」库级唯一
// 索引兜底，本区的前端预检只是提示层。
// 文档：docs/03-页面/报销详情页.md §发票登记

import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/utils/rmb_amount.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/attachments/attachment.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../models/expense_invoice.dart';
import '../providers/expense_providers.dart';
import '../providers/expense_settings_provider.dart';
import '../repositories/expense_repository.dart';
import 'expense_submission_revision.dart';

class ExpenseInvoiceSection extends ConsumerWidget {
  const ExpenseInvoiceSection({
    super.key,
    required this.claim,
    required this.editable,
    this.canVerify = false,
    this.stickyHeaderPinned,
  });

  final ExpenseClaim claim;

  /// DRAFT/REJECTED 且本人 → 可登记/编辑/删除。
  final bool editable;
  final bool canVerify;

  /// 发票要素表的表头吸顶信号（详情页滚动流内表头随页滚走会与数据脱节，
  /// 2026-09-22 全站表格滚动口径）。可空；不传则表头随页滚动（旧行为）。
  final ValueNotifier<bool>? stickyHeaderPinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final invoices = claim.invoices;
    final revision = ExpenseSubmissionRevision.fromClaim(claim);
    final total = invoices.fold<double>(
      0,
      (sum, invoice) => sum + invoice.totalAmount,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Text(
              '发票登记 (${invoices.length})',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (invoices.isNotEmpty) ...[
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '价税合计 ¥ ${total.toStringAsFixed(2)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (editable)
              UtenButton(
                key: const Key('expense-invoice-add'),
                type: UtenButtonType.tonal,
                size: UtenButtonSize.small,
                icon: Icons.add_rounded,
                onPressed: () => _openForm(context, ref),
                child: const Text('登记发票'),
              ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (revision != null)
          ExpenseSubmissionInvoiceTable(
            key: const Key('expense-invoice-revision-table'),
            revision: revision,
            claim: claim,
            stickyHeaderPinned: stickyHeaderPinned,
          )
        else if (invoices.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              vertical: UtenSpacing.s16,
              horizontal: UtenSpacing.s12,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: UtenRadius.lgAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Text(
              editable
                  ? '尚未登记发票。上传发票影像后点「登记发票」，支持图片识别自动回填票面要素。'
                  : '申请人未登记发票要素，请核对附件影像后联系补登。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          )
        else
          MasterDataTableView<ExpenseClaimInvoice>(
            key: const Key('expense-invoice-table'),
            columns: [
              ..._columns,
              MasterColumnDef<ExpenseClaimInvoice>(
                key: 'attachment',
                label: '凭证原件',
                width: 180,
                value: (invoice) =>
                    claim.attachments
                        .where(
                          (attachment) => attachment.id == invoice.attachmentId,
                        )
                        .map((attachment) => attachment.originalName)
                        .firstOrNull ??
                    '—',
              ),
            ],
            items: invoices,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            embedded: true,
            stickyHeaderPinned: stickyHeaderPinned,
            onRowTap: canVerify
                ? (invoice) => showDialog<bool>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) =>
                        _InvoiceVerifyDialog(claim: claim, invoice: invoice),
                  )
                : null,
            rowMenuBuilder: editable || canVerify
                ? (invoice) => _rowMenu(context, ref, invoice)
                : null,
          ),
        if (canVerify && invoices.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              for (final invoice in invoices)
                UtenButton(
                  type: UtenButtonType.tonal,
                  size: UtenButtonSize.small,
                  icon: invoice.checkState == ExpenseInvoiceCheckState.verified
                      ? Icons.fact_check
                      : Icons.fact_check_outlined,
                  onPressed: () => showDialog<bool>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) =>
                        _InvoiceVerifyDialog(claim: claim, invoice: invoice),
                  ),
                  child: Text(
                    '${AppLocalizations.of(context).expenseFlowVerify} #${invoice.lineNo}'
                    '${revision == null ? '' : ' · ${invoice.checkState.label}'}',
                  ),
                ),
            ],
          ),
        ],
        if (revision != null && !canVerify && invoices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final invoice in invoices)
                  Text(
                    '本次 #${invoice.lineNo} · ${invoice.checkState.label}'
                    '${invoice.verifiedByName == null ? '' : ' · ${invoice.verifiedByName}'}',
                  ),
              ],
            ),
          ),
      ],
    );
  }

  List<UtenContextMenuEntry> _rowMenu(
    BuildContext context,
    WidgetRef ref,
    ExpenseClaimInvoice invoice,
  ) {
    return [
      if (canVerify)
        UtenMenuItem(
          label: AppLocalizations.of(context).expenseFlowVerify,
          icon: Icons.fact_check_outlined,
          onTap: () => showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) =>
                _InvoiceVerifyDialog(claim: claim, invoice: invoice),
          ),
        ),
      if (editable)
        UtenMenuItem(
          label: '编辑',
          icon: Icons.edit_outlined,
          onTap: () => _openForm(context, ref, existing: invoice),
        ),
      if (editable)
        UtenMenuItem(
          label: '删除',
          icon: Icons.delete_outline_rounded,
          onTap: () => _confirmDelete(context, ref, invoice),
        ),
    ];
  }

  Future<void> _openForm(
    BuildContext context,
    WidgetRef ref, {
    ExpenseClaimInvoice? existing,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ExpenseInvoiceFormDialog(
        claimId: claim.id,
        attachments: claim.attachments,
        existing: existing,
        expectedVersion: claim.version,
      ),
    );
    if (saved == true) {
      ref.invalidate(expenseDetailProvider(claim.id));
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    ExpenseClaimInvoice invoice,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除发票登记？'),
        content: Text(
          '将删除第 ${invoice.lineNo} 行（号码 ${invoice.invoiceNo}）的票面要素，'
          '发票影像附件不受影响。',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await deleteExpenseInvoice(ref, claim.id, invoice.id);
      if (context.mounted) context.appSuccess('已删除发票登记');
    } catch (error) {
      if (context.mounted) context.appApiError(error);
    }
  }
}

final List<MasterColumnDef<ExpenseClaimInvoice>> _columns = [
  MasterColumnDef(
    key: 'lineNo',
    label: '#',
    width: 48,
    value: (invoice) => invoice.lineNo.toString(),
  ),
  MasterColumnDef(
    key: 'invoiceType',
    label: '类型',
    width: 110,
    value: (invoice) => invoice.type.label,
  ),
  MasterColumnDef(
    key: 'invoiceNo',
    label: '发票号码',
    width: 150,
    info:
        '数电票 20 位（无发票代码）；纸质/旧电子票 8 位号码 + 发票代码。'
        '全公司存活报销单间唯一，防止重复报销。',
    value: (invoice) => invoice.invoiceNo,
  ),
  MasterColumnDef(
    key: 'invoiceCode',
    label: '发票代码',
    width: 110,
    value: (invoice) => invoice.invoiceCode,
  ),
  MasterColumnDef(
    key: 'issueDate',
    label: '开票日期',
    width: 110,
    type: 'date',
    value: (invoice) =>
        invoice.issueDate == null ? '' : _fmtDate(invoice.issueDate!),
  ),
  MasterColumnDef(
    key: 'sellerName',
    label: '销售方',
    width: 200,
    value: (invoice) => invoice.sellerName,
  ),
  MasterColumnDef(
    key: 'buyerName',
    label: '购买方',
    width: 200,
    value: (invoice) => invoice.buyerName,
  ),
  MasterColumnDef(
    key: 'buyerTaxNo',
    label: '购买方税号',
    width: 180,
    value: (invoice) => invoice.buyerTaxNo,
  ),
  MasterColumnDef(
    key: 'amountExclTax',
    label: '金额',
    width: 100,
    type: 'money',
    value: (invoice) => invoice.amountExclTax?.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'taxAmount',
    label: '税额',
    width: 90,
    type: 'money',
    value: (invoice) => invoice.taxAmount?.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'totalAmount',
    label: '价税合计',
    width: 110,
    type: 'money',
    value: (invoice) => invoice.totalAmount.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'checkState',
    label: '人工查验',
    width: 90,
    value: (invoice) => invoice.checkState.label,
  ),
  MasterColumnDef(
    key: 'verificationRemark',
    label: '查验记录',
    width: 220,
    value: (invoice) => [
      invoice.verifiedByName,
      invoice.verificationRemark,
    ].whereType<String>().join(' · '),
  ),
  MasterColumnDef(
    key: 'remark',
    label: '备注',
    width: 160,
    value: (invoice) => invoice.remark,
  ),
];

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 发票登记/编辑弹窗：票面要素 + 图片识别回填 + 查重预检。
class ExpenseInvoiceFormDialog extends ConsumerStatefulWidget {
  const ExpenseInvoiceFormDialog({
    super.key,
    required this.claimId,
    required this.attachments,
    this.existing,
    this.expectedVersion = 0,
  });

  final String claimId;
  final List<Attachment> attachments;
  final ExpenseClaimInvoice? existing;
  final int expectedVersion;

  @override
  ConsumerState<ExpenseInvoiceFormDialog> createState() =>
      _ExpenseInvoiceFormDialogState();
}

class _ExpenseInvoiceFormDialogState
    extends ConsumerState<ExpenseInvoiceFormDialog> {
  final _noController = TextEditingController();
  final _codeController = TextEditingController();
  final _sellerController = TextEditingController();
  final _sellerTaxController = TextEditingController();
  final _buyerController = TextEditingController();
  final _buyerTaxController = TextEditingController();
  final _exclController = TextEditingController();
  final _taxController = TextEditingController();
  final _totalController = TextEditingController();
  final _remarkController = TextEditingController();

  ExpenseInvoiceType _type = ExpenseInvoiceType.general;
  DateTime? _issueDate;
  String? _attachmentId;
  bool _busy = false;
  bool _recognizing = false;
  String? _duplicateWarning;
  Timer? _duplicateTimer;
  int _duplicateRequest = 0;
  bool _ocrUsed = false;
  bool _ocrConfirmed = false;
  bool _buyerEdited = false;
  bool _buyerTaxEdited = false;
  AppLocalizations get l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _type = existing.type;
      _noController.text = existing.invoiceNo;
      _codeController.text = existing.invoiceCode ?? '';
      _sellerController.text = existing.sellerName ?? '';
      _sellerTaxController.text = existing.sellerTaxNo ?? '';
      _buyerController.text = existing.buyerName ?? '';
      _buyerTaxController.text = existing.buyerTaxNo ?? '';
      _exclController.text = existing.amountExclTax?.toStringAsFixed(2) ?? '';
      _taxController.text = existing.taxAmount?.toStringAsFixed(2) ?? '';
      _totalController.text = existing.totalAmount.toStringAsFixed(2);
      _remarkController.text = existing.remark ?? '';
      _issueDate = existing.issueDate;
      _attachmentId = existing.attachmentId;
    } else {
      unawaited(_prefillCompany());
      _issueDate = ChinaDateTime.today();
      if (widget.attachments.length == 1) {
        _attachmentId = widget.attachments.single.id;
      }
    }
  }

  Future<void> _prefillCompany() async {
    try {
      final settings = await ref.read(expenseSettingsProvider.future);
      if (!mounted) return;
      if (!_buyerEdited && _buyerController.text.isEmpty) {
        _buyerController.text = settings.companyName;
      }
      if (!_buyerTaxEdited && _buyerTaxController.text.isEmpty) {
        _buyerTaxController.text = settings.companyTaxNo;
      }
    } catch (_) {
      // Optional prefill never blocks manual entry or substitutes invented data.
    }
  }

  @override
  void dispose() {
    _duplicateTimer?.cancel();
    _noController.dispose();
    _codeController.dispose();
    _sellerController.dispose();
    _sellerTaxController.dispose();
    _buyerController.dispose();
    _buyerTaxController.dispose();
    _exclController.dispose();
    _taxController.dispose();
    _totalController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  bool get _isDigitalNo {
    if (_type == ExpenseInvoiceType.other) return false;
    final digits = _noController.text.trim();
    return RegExp(r'^\d{20}$').hasMatch(digits);
  }

  /// 号码/代码变化即查重（8/20 位成形才查）。
  Future<void> _checkDuplicate() async {
    final request = ++_duplicateRequest;
    final no = _noController.text.trim();
    if (_type == ExpenseInvoiceType.other
        ? !RegExp(r'^[A-Za-z0-9/-]{1,60}$').hasMatch(no) ||
              _sellerController.text.trim().isEmpty
        : !RegExp(r'^\d{8}$|^\d{20}$').hasMatch(no)) {
      if (_duplicateWarning != null) {
        setState(() => _duplicateWarning = null);
      }
      return;
    }
    try {
      final result = await ref
          .read(expenseRepositoryProvider)
          .checkInvoice(
            no,
            invoiceCode: _codeController.text.trim(),
            excludeClaimId: widget.claimId,
            invoiceType: _type.apiValue,
            sellerName: _sellerController.text.trim(),
          );
      if (!mounted || request != _duplicateRequest) return;
      setState(() {
        _duplicateWarning = result.duplicated ? '该凭证已登记，请勿重复报销' : null;
      });
    } on Exception {
      // 预检失败不打断填写：库级唯一索引仍是最终兜底。
    }
  }

  void _scheduleDuplicateCheck() {
    _duplicateTimer?.cancel();
    _duplicateRequest++;
    setState(() {
      _duplicateWarning = null;
      if (_isDigitalNo) _codeController.clear();
    });
    _duplicateTimer = Timer(const Duration(milliseconds: 400), _checkDuplicate);
  }

  Future<void> _recognize() async {
    if (_recognizing || _busy) return;
    final picked = await FilePicker.platform.pickFiles(
      withData: true,
      allowCompression: false,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
    );
    final file = picked?.files.singleOrNull;
    final bytes = file?.bytes;
    if (!mounted || file == null || bytes == null) return;
    setState(() => _recognizing = true);
    try {
      final recognized = await ref
          .read(expenseRepositoryProvider)
          .recognizeInvoice(
            bytes,
            file.name,
            file.extension == null || file.extension!.isEmpty
                ? 'image/jpeg'
                : 'image/${file.extension!.toLowerCase() == 'jpg' ? 'jpeg' : file.extension!.toLowerCase()}',
          );
      if (!mounted) return;
      setState(() {
        _ocrUsed = true;
        _ocrConfirmed = false;
        if (recognized.type != null) _type = recognized.type!;
        if (recognized.invoiceNo?.isNotEmpty == true) {
          _noController.text = recognized.invoiceNo!;
        }
        if (recognized.invoiceCode?.isNotEmpty == true) {
          _codeController.text = recognized.invoiceCode!;
        }
        if (_isDigitalNo) _codeController.clear();
        if (recognized.issueDate != null) _issueDate = recognized.issueDate;
        if (recognized.sellerName?.isNotEmpty == true) {
          _sellerController.text = recognized.sellerName!;
        }
        if (recognized.sellerTaxNo?.isNotEmpty == true) {
          _sellerTaxController.text = recognized.sellerTaxNo!;
        }
        if (recognized.buyerName?.isNotEmpty == true) {
          _buyerEdited = true;
          _buyerController.text = recognized.buyerName!;
        }
        if (recognized.buyerTaxNo?.isNotEmpty == true) {
          _buyerTaxEdited = true;
          _buyerTaxController.text = recognized.buyerTaxNo!;
        }
        if (recognized.amountExclTax != null) {
          _exclController.text = recognized.amountExclTax!.toStringAsFixed(2);
        }
        if (recognized.taxAmount != null) {
          _taxController.text = recognized.taxAmount!.toStringAsFixed(2);
        }
        if (recognized.totalAmount != null) {
          _totalController.text = recognized.totalAmount!.toStringAsFixed(2);
        }
      });
      if (mounted) {
        context.appSuccess('识别完成，请核对票面要素后保存');
        await _checkDuplicate();
      }
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  Future<void> _pickIssueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _issueDate ?? ChinaDateTime.today(),
      firstDate: DateTime.utc(2000),
      lastDate: ChinaDateTime.today(),
      helpText: '选择开票日期',
    );
    if (picked == null || !mounted) return;
    setState(() => _issueDate = picked);
  }

  String? _validate() {
    final no = _noController.text.trim();
    final code = _codeController.text.trim();
    if (_type == ExpenseInvoiceType.other) {
      if (!RegExp(r'^[A-Za-z0-9/-]{1,60}$').hasMatch(no) ||
          (code.isNotEmpty &&
              !RegExp(r'^[A-Za-z0-9/-]{1,20}$').hasMatch(code)) ||
          _sellerController.text.trim().isEmpty) {
        return l10n.expenseFlowOtherNumberInvalid;
      }
    } else {
      if (!RegExp(r'^\d{8}$|^\d{20}$').hasMatch(no)) {
        return '发票号码必须为 8 位或 20 位数字';
      }
      if (!_isDigitalNo && !RegExp(r'^\d{10}$|^\d{12}$').hasMatch(code)) {
        return '8 位号码的发票必须填写 10 或 12 位发票代码';
      }
    }
    if (_issueDate == null) return l10n.expenseFlowInvoiceDateRequired;
    if (_attachmentId == null) return l10n.expenseFlowOriginalRequired;
    if (parseExpenseAmountCents(_totalController.text) == null ||
        (_exclController.text.trim().isNotEmpty &&
            parseExpenseAmountCents(_exclController.text, allowZero: true) ==
                null) ||
        (_taxController.text.trim().isNotEmpty &&
            parseExpenseAmountCents(_taxController.text, allowZero: true) ==
                null)) {
      return l10n.expenseFlowInvoiceAmountInvalid;
    }
    if (_ocrUsed && !_ocrConfirmed) return l10n.expenseFlowOcrConfirmRequired;
    return _duplicateWarning;
  }

  Future<void> _submit() async {
    if (_busy || _recognizing) return;
    final error = _validate();
    if (error != null) {
      context.appWarning(error);
      return;
    }
    setState(() => _busy = true);
    try {
      final total = double.parse(_totalController.text.trim());
      final excl = double.tryParse(_exclController.text.trim());
      final tax = double.tryParse(_taxController.text.trim());
      final input = ExpenseClaimInvoiceInput(
        expectedVersion: widget.expectedVersion,
        type: _isDigitalNo && _type == ExpenseInvoiceType.general
            ? ExpenseInvoiceType.digital
            : _type,
        invoiceCode: _isDigitalNo
            ? null
            : _codeController.text.trim().isEmpty
            ? null
            : _codeController.text.trim(),
        invoiceNo: _noController.text.trim(),
        issueDate: _issueDate,
        sellerName: _blankToNull(_sellerController.text),
        sellerTaxNo: _blankToNull(_sellerTaxController.text),
        buyerName: _blankToNull(_buyerController.text),
        buyerTaxNo: _blankToNull(_buyerTaxController.text),
        amountExclTax: excl,
        taxAmount: tax,
        totalAmount: total,
        attachmentId: _attachmentId,
        remark: _blankToNull(_remarkController.text),
      );
      await saveExpenseInvoice(
        ref,
        widget.claimId,
        input,
        invoiceId: widget.existing?.id,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (saveError) {
      if (mounted) {
        // 库级唯一索引冲突等错误直接回显服务端消息。
        context.appApiError(saveError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        AlertDialog(
          title: Text(widget.existing == null ? '登记发票' : '编辑发票'),
          content: AbsorbPointer(
            absorbing: _busy,
            child: SizedBox(
              width: 640,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.existing == null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.expenseFlowOcrGuide,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            UtenButton(
                              key: const Key('expense-invoice-recognize'),
                              type: UtenButtonType.tonal,
                              size: UtenButtonSize.small,
                              icon: Icons.document_scanner_outlined,
                              isLoading: _recognizing,
                              onPressed: _recognizing ? null : _recognize,
                              child: const Text('识别发票图片'),
                            ),
                          ],
                        ),
                      ),
                    _invoiceFields(
                      children: [
                        Expanded(
                          child: UtenDropdownField(
                            label: '发票类型',
                            required: true,
                            value: _type.apiValue,
                            allowClear: false,
                            items: [
                              for (final type in ExpenseInvoiceType.values)
                                UtenDropdownItem(
                                  value: type.apiValue,
                                  label: type.label,
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null && value.isNotEmpty) {
                                setState(
                                  () =>
                                      _type = ExpenseInvoiceType.fromApi(value),
                                );
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(
                          child: TextField(
                            controller: _codeController,
                            enabled:
                                !_isDigitalNo ||
                                _type == ExpenseInvoiceType.other,
                            onChanged: (_) => _scheduleDuplicateCheck(),
                            keyboardType: TextInputType.number,
                            decoration: UtenInputDecoration(
                              InputDecoration(
                                labelText: _isDigitalNo
                                    ? '发票代码（数电票无）'
                                    : '发票代码 *',
                              ),
                              info: '纸质/旧电子票 10 或 12 位；20 位数电票没有发票代码。',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      key: const Key('expense-invoice-no'),
                      controller: _noController,
                      keyboardType: TextInputType.number,
                      decoration: const UtenInputDecoration(
                        InputDecoration(labelText: '发票号码 *'),
                        info: '数电票 20 位；纸质/旧电子票 8 位。全公司唯一，防重复报销。',
                      ),
                      onChanged: (_) => _scheduleDuplicateCheck(),
                    ),
                    if (_duplicateWarning != null) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Text(
                        _duplicateWarning!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    _invoiceFields(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: _pickIssueDate,
                            borderRadius: BorderRadius.circular(8),
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '开票日期',
                                border: OutlineInputBorder(),
                                suffixIcon: Icon(
                                  Icons.calendar_today_outlined,
                                  size: 18,
                                ),
                              ),
                              child: Text(
                                _issueDate == null
                                    ? '—'
                                    : '${_issueDate!.year}-${_issueDate!.month.toString().padLeft(2, '0')}-${_issueDate!.day.toString().padLeft(2, '0')}',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(
                          child: TextField(
                            key: const Key('expense-invoice-buyer-name'),
                            controller: _buyerController,
                            onChanged: (_) => _buyerEdited = true,
                            decoration: const UtenInputDecoration(
                              InputDecoration(labelText: '购买方名称'),
                              info: '按原件填写，个人实名交通等凭证按适用规则由财务核实。',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      key: const Key('expense-invoice-buyer-tax'),
                      controller: _buyerTaxController,
                      onChanged: (_) => _buyerTaxEdited = true,
                      maxLength: 20,
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          labelText: l10n.expenseFlowCompanyTaxNo,
                        ),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    _invoiceFields(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _sellerController,
                            onChanged: (_) => _scheduleDuplicateCheck(),
                            decoration: const InputDecoration(
                              labelText: '销售方名称',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(
                          child: TextField(
                            controller: _sellerTaxController,
                            decoration: const InputDecoration(
                              labelText: '销售方税号',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    _invoiceFields(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _exclController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const UtenInputDecoration(
                              InputDecoration(labelText: '合计金额（不含税）'),
                              info:
                                  '不含税金额 + 税额应等于价税合计（±0.01），'
                                  '不符时系统标记「勾稽不符」供审批人复核。',
                            ),
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(
                          child: TextField(
                            controller: _taxController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: '合计税额',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(
                          child: TextField(
                            key: const Key('expense-invoice-total'),
                            controller: _totalController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: '价税合计 *',
                              prefixText: '¥ ',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    if (_ocrUsed)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _ocrConfirmed,
                        onChanged: _busy
                            ? null
                            : (value) => setState(
                                () => _ocrConfirmed = value ?? false,
                              ),
                        title: Text(l10n.expenseFlowOcrConfirm),
                      ),
                    if (widget.attachments.isEmpty)
                      Text(
                        l10n.expenseFlowOriginalRequired,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    if (widget.attachments.isNotEmpty)
                      UtenDropdownField(
                        label: '关联凭证原件',
                        required: true,
                        value: _attachmentId,
                        items: [
                          for (final attachment in widget.attachments)
                            UtenDropdownItem(
                              value: attachment.id,
                              label: attachment.originalName,
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _attachmentId = value),
                      ),
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      controller: _remarkController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: '备注（选填）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            UtenButton(
              key: const Key('expense-invoice-save'),
              onPressed: _busy ? null : _submit,
              isLoading: _busy,
              icon: Icons.save_outlined,
              child: const Text('保存'),
            ),
          ],
        ),
        if (_recognizing)
          const Positioned.fill(
            child: UtenBusyOverlay(
              title: '正在识别发票…',
              description: '正在读取票面信息，请稍候',
            ),
          ),
      ],
    );
  }
}

String? _blankToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Widget _invoiceFields({required List<Widget> children}) => LayoutBuilder(
  builder: (context, constraints) {
    final fields = children
        .whereType<Expanded>()
        .map((field) => field.child)
        .toList();
    final columns = constraints.maxWidth < 500 ? 1 : fields.length;
    final width =
        (constraints.maxWidth - (columns - 1) * UtenSpacing.s12) / columns;
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s12,
      children: [
        for (final field in fields) SizedBox(width: width, child: field),
      ],
    );
  },
);

class _InvoiceVerifyDialog extends ConsumerStatefulWidget {
  const _InvoiceVerifyDialog({required this.claim, required this.invoice});
  final ExpenseClaim claim;
  final ExpenseClaimInvoice invoice;
  @override
  ConsumerState<_InvoiceVerifyDialog> createState() =>
      _InvoiceVerifyDialogState();
}

class _InvoiceVerifyDialogState extends ConsumerState<_InvoiceVerifyDialog> {
  final _remark = TextEditingController();
  bool _verified = true;
  bool _busy = false;
  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_remark.text.trim().isEmpty) {
      context.appWarning(
        AppLocalizations.of(context).expenseFlowVerifyRequired,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(expenseRepositoryProvider)
          .verifyInvoice(
            widget.claim.id,
            widget.invoice.id,
            expectedVersion: widget.claim.version,
            verified: _verified,
            remark: _remark.text.trim(),
          );
      ref.invalidate(expenseDetailProvider(widget.claim.id));
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.expenseFlowVerifyTitle),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.invoice.invoiceNo} · ¥ ${widget.invoice.totalAmount.toStringAsFixed(2)}',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(l10n.expenseFlowVerifyGuide),
              TextButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: Text(l10n.expenseFlowVerifyOfficial),
                onPressed: () async {
                  final opened = await launchUrl(
                    Uri.parse('https://inv-veri.chinatax.gov.cn/'),
                    mode: LaunchMode.externalApplication,
                  );
                  if (!opened && context.mounted) {
                    context.appWarning('https://inv-veri.chinatax.gov.cn/');
                  }
                },
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s8,
                children: [
                  ChoiceChip(
                    label: Text(l10n.expenseFlowVerifyPassed),
                    selected: _verified,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _verified = true),
                  ),
                  ChoiceChip(
                    label: Text(l10n.expenseFlowVerifyMismatch),
                    selected: !_verified,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _verified = false),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _remark,
                maxLines: 3,
                maxLength: 1000,
                enabled: !_busy,
                decoration: UtenInputDecoration(
                  InputDecoration(labelText: l10n.expenseFlowVerifyRemark),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        UtenButton(
          isLoading: _busy,
          onPressed: _busy ? null : _save,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
