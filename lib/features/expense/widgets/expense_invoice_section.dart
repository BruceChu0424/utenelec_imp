import '../../../shared/paging/shared_read_provider_owner.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import '../../../shared/formatters/exact_decimal.dart';
// 报销单发票登记区（V608）：结构化发票要素表格 + 登记/编辑弹窗（图片识别回填 +
// 查重即时提示）。DRAFT/REJECTED 且本人可维护（编辑/删除走行菜单）；审批/打款
// 侧与只读访客仅浏览。防重复报销（财会〔2020〕6 号）由「代码+号码」库级唯一
// 索引兜底，本区的前端预检只是提示层。
// 文档：docs/03-页面/报销详情页.md §发票登记

import '../../../components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/layout/uten_form_grid.dart';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:uten_imp/core/io/guarded_url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MaxLengthEnforcement;
import '../../../core/network/api_exception.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../providers/expense_action_eligibility.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_drop_target.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../shared/formatters/financial_amount_validation.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/attachments/attachment.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../models/expense_invoice.dart';
import '../models/expense_guided_values.dart';
import '../../../shared/ai/guided/ai_guided_file_plan.dart';
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
    this.onVerify,
    this.stickyHeaderPinned,
  });

  final ExpenseClaim claim;

  /// DRAFT/REJECTED 且本人 → 可登记/编辑/删除。
  final bool editable;
  final bool canVerify;
  final Future<void> Function(ExpenseClaimInvoice invoice)? onVerify;
  Future<void> _openVerification(
    BuildContext context,
    ExpenseClaimInvoice invoice,
  ) async {
    if (onVerify != null) {
      await onVerify!(invoice);
      return;
    }
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InvoiceVerifyDialog(claim: claim, invoice: invoice),
    );
  }

  /// 发票要素表的表头吸顶信号（详情页滚动流内表头随页滚走会与数据脱节，
  /// 2026-09-22 全站表格滚动口径）。可空；不传则表头随页滚动（旧行为）。
  final ValueNotifier<bool>? stickyHeaderPinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final invoices = claim.invoices;
    final revision = ExpenseSubmissionRevision.fromClaim(claim);
    final total =
        financeExactSumTexts(
          invoices.map((invoice) => invoice.totalAmountText),
        ) ??
        '0';
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
            UtenFieldHintIcon(
              info: editable
                  ? '上传发票影像后点「登记发票」，支持图片识别回填票面要素。登记后须核对票面信息和关联原件。'
                  : '请核对登记要素与附件原件。未登记时请联系申请人补登，必要时驳回并说明原因。',
              compact: true,
            ),
            if (invoices.isNotEmpty) ...[
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '价税合计 ${financeExactMoneyDisplay(total)} 元',
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
        else
          MasterDataTableView<ExpenseClaimInvoice>(
            emptyMessage: '暂无发票记录',
            tableKey:
                'features.expense.widgets.expense_invoice_section.ExpenseInvoiceSection.build.1',
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
                ? (invoice) => _openVerification(context, invoice)
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
                  onPressed: () => _openVerification(context, invoice),
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
          onTap: () => _openVerification(context, invoice),
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
      builder: (dialogContext) => UtenAlertDialog(
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
  // 2026-10-08 用户口径「状态或进度列默认放最前」：人工查验是发票行的查验
  // 结论列（未查验 / 已人工查验 / 勾稽不符，推翻 2026-10-06 批次「无状态
  // 字样不动」的豁免），前置到序号列之前。
  MasterColumnDef(
    key: 'checkState',
    label: '人工查验',
    width: 90,
    filterFromRows: true,
    facetSearchEnabled: true,
    value: (invoice) => invoice.checkStateText,
    // 人工查验整格底色（ADR-169 逐页显式映射）：勾稽不符=橙（票面勾稽不符
    // 待审批人复核——风险中间态）/ 已人工查验=绿（查验通过，审批前置条件已
    // 满足）/ 未查验·金额勾稽相符=黄（等人工查验，无异常；金额勾稽相符只是
    // 机器预检，人工查验未做仍等查验，文案区分预检结果）。
    cellColor: (context, invoice) =>
        utenStatusBadgeCellColor(switch (invoice.checkState) {
          ExpenseInvoiceCheckState.mismatch => UtenStatusBadgeType.orange,
          ExpenseInvoiceCheckState.verified => UtenStatusBadgeType.success,
          ExpenseInvoiceCheckState.unchecked ||
          ExpenseInvoiceCheckState.amountsMatch => UtenStatusBadgeType.warning,
        }),
  ),
  MasterColumnDef(
    key: 'lineNo',
    label: '#',
    width: 48,
    type: 'count',
    sortable: true,
    value: (invoice) => invoice.lineNo.toString(),
  ),
  MasterColumnDef(
    key: 'invoiceType',
    label: '类型',
    width: 110,
    filterFromRows: true,
    facetSearchEnabled: true,
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
    sortable: true,
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
    exactValueOf: (invoice) => invoice.amountExclTaxText,
    label: '金额',
    width: 100,
    type: 'money',
    sortable: true,
    value: (invoice) => invoice.amountExclTaxText == null
        ? null
        : financeExactMoneyDisplay(invoice.amountExclTaxText),
  ),
  MasterColumnDef(
    key: 'taxAmount',
    exactValueOf: (invoice) => invoice.taxAmountText,
    label: '税额',
    width: 90,
    type: 'money',
    sortable: true,
    value: (invoice) => invoice.taxAmountText == null
        ? null
        : financeExactMoneyDisplay(invoice.taxAmountText),
  ),
  MasterColumnDef(
    key: 'totalAmount',
    exactValueOf: (invoice) => invoice.totalAmountText,
    label: '价税合计',
    width: 110,
    type: 'money',
    sortable: true,
    value: (invoice) => financeExactMoneyDisplay(invoice.totalAmountText),
  ),
  MasterColumnDef(
    key: 'currency',
    label: '币种',
    width: 80,
    value: (_) => expenseClaimCurrencyName,
  ),
  MasterColumnDef(
    key: 'verificationRemark',
    label: '查验记录',
    width: 220,
    value: (invoice) => [
      invoice.verifiedByName,
      invoice.verificationRemark,
      if (invoice.reconciliationDifferenceText case final difference?
          when financeAmountUnits(difference) != BigInt.zero)
        '票面原值差额$difference元（既有核验容差0.01元）',
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
    this.guidedFields,
    this.guidedAttachmentId,
    this.guidedPlan,
  });

  final String claimId;
  final List<Attachment> attachments;
  final ExpenseClaimInvoice? existing;
  final int expectedVersion;
  final Map<String, String>? guidedFields;
  final String? guidedAttachmentId;
  final AiGuidedFilePlan? guidedPlan;

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
      _exclController.text = existing.amountExclTaxText == null
          ? ''
          : financeExactMoneyDisplay(existing.amountExclTaxText);
      _taxController.text = existing.taxAmountText == null
          ? ''
          : financeExactMoneyDisplay(existing.taxAmountText);
      _totalController.text = financeExactMoneyDisplay(
        existing.totalAmountText,
      );
      _remarkController.text = existing.remark ?? '';
      _issueDate = existing.issueDate;
      _attachmentId = existing.attachmentId;
    } else {
      unawaited(_prefillCompany());
      _issueDate = ChinaDateTime.today();
      if (widget.attachments.length == 1) {
        _attachmentId = widget.attachments.single.id;
      }
      final fields = widget.guidedFields;
      if (fields != null) {
        _type = ExpenseInvoiceType.fromApi(fields['invoiceType']);
        _noController.text = fields['invoiceNo'] ?? '';
        _codeController.text = fields['invoiceCode'] ?? '';
        _sellerController.text = fields['sellerName'] ?? '';
        _sellerTaxController.text = fields['sellerTaxNo'] ?? '';
        _buyerController.text = fields['buyerName'] ?? '';
        _buyerTaxController.text = fields['buyerTaxNo'] ?? '';
        _exclController.text = fields['amountExclTax'] ?? '';
        _taxController.text = fields['taxAmount'] ?? '';
        _totalController.text = fields['totalAmount'] ?? '';
        _remarkController.text = fields['itemSummary'] ?? '';
        _issueDate = guidedInvoiceDate(fields['issueDate']);
        _attachmentId = widget.guidedAttachmentId;
        _ocrUsed = true;
        _ocrConfirmed = false;
        _buyerEdited = true;
        _buyerTaxEdited = true;
      }
    }
  }

  Future<void> _prefillCompany() async {
    try {
      final settings = await readSharedWidgetFuture(
        ref,
        expenseSettingsProvider.future,
      );
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
    if (!mounted || file == null) return;
    await _recognizeFile(file);
  }

  /// OCR 识别一张发票图（文件选择框与拖入共用）。
  Future<void> _recognizeFile(PlatformFile file) async {
    if (!mounted || _recognizing || _busy) return;
    final bytes = file.bytes;
    if (bytes == null) {
      if (mounted) context.appError('无法读取「${file.name}」的内容');
      return;
    }
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
          _exclController.text = financeExactMoneyDisplay(
            recognized.amountExclTaxText,
          );
        }
        if (recognized.taxAmount != null) {
          _taxController.text = financeExactMoneyDisplay(
            recognized.taxAmountText,
          );
        }
        if (recognized.totalAmount != null) {
          _totalController.text = financeExactMoneyDisplay(
            recognized.totalAmountText,
          );
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
    final picked = await showUtenDatePicker(
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
    final totalIssue = validateFinanceAmount(
      _totalController.text,
      label: '价税合计',
    );
    if (totalIssue != null) return totalIssue;
    for (final field in [
      (controller: _exclController, label: '不含税金额'),
      (controller: _taxController, label: '税额'),
    ]) {
      if (field.controller.text.trim().isNotEmpty) {
        final issue = validateNonNegativeFinanceAmount(
          field.controller.text,
          label: field.label,
        );
        if (issue != null) return issue;
      }
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
      if (widget.guidedPlan case final plan?) {
        await validateAiGuidedFilePlan(ref, plan);
        if (!mounted || !plan.matches(ref)) return;
      }
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
        amountExclTaxExact: financeExactDecimal(_exclController.text),
        taxAmount: tax,
        taxAmountExact: financeExactDecimal(_taxController.text),
        totalAmount: total,
        totalAmountExact: financeExactDecimal(_totalController.text),
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
    if (widget.guidedPlan case final plan?) {
      final identity = ref.watch(aiGuidedFileIdentityProvider);
      if (identity != plan.identity || !plan.matches(ref)) {
        final route = ModalRoute.of(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (route != null && route.isActive) {
            route.navigator?.removeRoute(route);
          }
        });
        return const SizedBox.shrink();
      }
    }
    final theme = Theme.of(context);
    return Stack(
      children: [
        // 弹窗整块都是拖放接收区（Web/桌面端）：发票图直接拖进来 OCR，与「识别发票图片」按钮同一条链。
        UtenDropTarget(
          enabled: widget.existing == null && !_recognizing && !_busy,
          hint: '松开鼠标识别发票图',
          onFiles: (files) => _recognizeFile(files.first),
          child: UtenAlertDialog(
            maxWidth: 640,
            scrollable: false,
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
                          padding: const EdgeInsets.only(
                            bottom: UtenSpacing.s12,
                          ),
                          child: Row(
                            children: [
                              Flexible(
                                child: UtenButton(
                                  key: const Key('expense-invoice-recognize'),
                                  type: UtenButtonType.tonal,
                                  size: UtenButtonSize.small,
                                  icon: Icons.document_scanner_outlined,
                                  isLoading: _recognizing,
                                  onPressed: _recognizing ? null : _recognize,
                                  child: const Text('识别发票图片'),
                                ),
                              ),
                              UtenFieldHintIcon(
                                info: l10n.expenseFlowOcrGuide,
                                dense: true,
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
                                    () => _type = ExpenseInvoiceType.fromApi(
                                      value,
                                    ),
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
                              borderRadius: BorderRadius.circular(
                                UtenRadius.md,
                              ),
                              child: InputDecorator(
                                decoration: const UtenInputDecoration(
                                  InputDecoration(
                                    labelText: '开票日期',
                                    border: OutlineInputBorder(),
                                    suffixIcon: Icon(
                                      Icons.calendar_today_outlined,
                                      size: 18,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  _issueDate == null
                                      ? '开票日期'
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
                              decoration: const UtenInputDecoration(
                                InputDecoration(
                                  labelText: '销售方名称',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          Expanded(
                            child: TextField(
                              controller: _sellerTaxController,
                              decoration: const UtenInputDecoration(
                                InputDecoration(
                                  labelText: '销售方税号',
                                  border: OutlineInputBorder(),
                                ),
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
                              keyboardType:
                                  const TextInputType.numberWithOptions(
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
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: const UtenInputDecoration(
                                InputDecoration(
                                  labelText: '合计税额',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          Expanded(
                            child: TextField(
                              key: const Key('expense-invoice-total'),
                              controller: _totalController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: const UtenInputDecoration(
                                InputDecoration(
                                  labelText: '价税合计 *',
                                  suffixText: '元',
                                  border: OutlineInputBorder(),
                                ),
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
                        decoration: const UtenInputDecoration(
                          InputDecoration(
                            labelText: '备注（选填）',
                            border: OutlineInputBorder(),
                          ),
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
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).pop(false),
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

Widget _invoiceFields({required List<Widget> children}) => UtenFormGrid(
  maxColumns: children.whereType<Expanded>().length.clamp(1, 6),
  children: [for (final field in children.whereType<Expanded>()) field.child],
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
  bool _unknown = false;
  bool _retired = false;
  bool _openingOfficial = false;
  String? _readBackState;
  late ExpenseClaim _latest = widget.claim;
  late SensitiveReadBoundary _boundary;
  late int _epoch;
  bool get _current =>
      mounted &&
      !_retired &&
      ref.read(sensitiveReadBoundaryProvider) == _boundary &&
      ref.read(exportContextEpochProvider) == _epoch;
  bool get _allowed =>
      _current &&
      ref.read(expenseActionEligibilityProvider).canVerifyInvoice(_latest);
  @override
  void initState() {
    super.initState();
    _boundary = ref.read(sensitiveReadBoundaryProvider);
    _epoch = ref.read(exportContextEpochProvider);
    void retire() {
      if (mounted && !_retired) setState(() => _retired = true);
    }

    ref.listenManual(sensitiveReadBoundaryProvider, (_, next) {
      if (next != _boundary) retire();
    });
    ref.listenManual(exportContextEpochProvider, (_, next) {
      if (next != _epoch) retire();
    });
  }

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  Future<void> _reconcile() async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      final fresh = await ref
          .read(expenseRepositoryProvider)
          .getById(widget.claim.id);
      if (!mounted || !_current) return;
      final invoice = fresh.invoices
          .where((value) => value.id == widget.invoice.id)
          .firstOrNull;
      if (invoice == null) throw const FormatException('票据已变化，请关闭后重新核对');
      setState(() {
        _latest = fresh;
        _unknown = false;
        _readBackState = '当前票据：${invoice.checkState.label}';
      });
      ref.invalidate(expenseDetailProvider(widget.claim.id));
    } catch (error) {
      if (mounted && _current) {
        setState(() => _busy = false);
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _unknown || !_allowed) return;
    final remark = _remark.text.trim();
    if (remark.isEmpty || remark.length > 500) {
      context.appWarning(
        remark.isEmpty
            ? AppLocalizations.of(context).expenseFlowVerifyRequired
            : '查验依据最多500字，原输入已保留',
      );
      return;
    }
    final verified = _verified;
    final version = _latest.version;
    var sent = false;
    setState(() => _busy = true);
    try {
      await runSensitiveWrite(
        ref,
        isCurrent: () => _allowed,
        write: () {
          sent = true;
          return ref
              .read(expenseRepositoryProvider)
              .verifyInvoice(
                widget.claim.id,
                widget.invoice.id,
                expectedVersion: version,
                verified: verified,
                remark: remark,
              );
        },
      );
      if (!mounted || !_current) return;
      setState(() => _busy = false);
      ref.invalidate(expenseDetailProvider(widget.claim.id));
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted && _current) {
        setState(() {
          _busy = false;
          _unknown =
              sent &&
              !(error is ApiException &&
                  error.hasResponseCode &&
                  const {400, 403, 404, 409, 422}.contains(error.httpStatus));
        });
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!_current) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.of(context).pop(),

        title: const Text('授权已变化'),
        content: const Text('请关闭后重新打开票据查验'),
      );
    }
    return Stack(
      children: [
        UtenAlertDialog(
          scrollable: false,
          title: Row(
            children: [
              Expanded(child: Text(l10n.expenseFlowVerifyTitle)),
              UtenFieldHintIcon(info: l10n.expenseFlowVerifyGuide),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${widget.invoice.invoiceNo} · ${financeExactMoneyDisplay(widget.invoice.totalAmountText)} 元',
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  if (_unknown || _readBackState != null)
                    Row(
                      children: [
                        Expanded(
                          child: Text(_unknown ? '查验结果待核对' : _readBackState!),
                        ),
                        const UtenFieldHintIcon(
                          info:
                              '结果未知时先读取当前票据核对，原查验结论与依据保留；读取不会重新提交。保存始终按当前单据版本重新校验。',
                        ),
                      ],
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new),
                    label: Text(l10n.expenseFlowVerifyOfficial),
                    onPressed: _openingOfficial
                        ? null
                        : () async {
                            setState(() => _openingOfficial = true);
                            try {
                              final opened = await launchUrl(
                                Uri.parse('https://inv-veri.chinatax.gov.cn/'),
                                mode: LaunchMode.externalApplication,
                              );
                              if (mounted) {
                                setState(() => _openingOfficial = false);
                              }
                              if (!opened && context.mounted) {
                                context.appWarning(
                                  'https://inv-veri.chinatax.gov.cn/',
                                );
                              }
                            } catch (error) {
                              if (context.mounted && _current) {
                                setState(() => _openingOfficial = false);
                                context.appApiError(error);
                              }
                            } finally {
                              if (mounted) {
                                setState(() => _openingOfficial = false);
                              }
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
                        onSelected: _busy || _unknown || !_allowed
                            ? null
                            : (_) => setState(() => _verified = true),
                      ),
                      ChoiceChip(
                        label: Text(l10n.expenseFlowVerifyMismatch),
                        selected: !_verified,
                        onSelected: _busy || _unknown || !_allowed
                            ? null
                            : (_) => setState(() => _verified = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  TextField(
                    controller: _remark,
                    maxLines: 3,
                    maxLength: 500,
                    maxLengthEnforcement: MaxLengthEnforcement.none,
                    enabled: !_busy && !_unknown && _allowed,
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
              onPressed: _busy
                  ? null
                  : _unknown
                  ? _reconcile
                  : _allowed
                  ? _save
                  : null,
              child: Text(_unknown ? '核对结果' : l10n.commonSave),
            ),
          ],
        ),
        if (_busy || _openingOfficial)
          const UtenBusyOverlay(title: '正在处理票据查验', showDoNotLeaveHint: false),
      ],
    );
  }
}
