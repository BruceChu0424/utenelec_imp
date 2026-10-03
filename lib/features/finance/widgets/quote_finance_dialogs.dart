// 报价核价页的弹窗(ADR-134)：退回销售(原因快捷选项 + 自由填写) / 批量设折扣。
//
// 退回原因必填：点快捷选项把原因填进输入框(可再补充)，空着提交就地提示，不发请求。
// 两个弹窗都只收集输入，网络请求与遮罩由页面负责(防止弹窗持有异步态)。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../models/quote_finance_pricing.dart';

/// 退回销售：返回填写的原因；取消返回 null。
Future<String?> showQuoteFinanceReturnDialog(
  BuildContext context, {
  required String billNo,
  required TaskClaimSession claim,
  Widget Function(BuildContext, Widget)? decorate,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      final dialog = _QuoteFinanceReturnDialog(billNo: billNo, claim: claim);
      return decorate?.call(context, dialog) ?? dialog;
    },
  );
}

class _QuoteFinanceReturnDialog extends StatefulWidget {
  const _QuoteFinanceReturnDialog({required this.billNo, required this.claim});

  final String billNo;
  final TaskClaimSession claim;

  @override
  State<_QuoteFinanceReturnDialog> createState() =>
      _QuoteFinanceReturnDialogState();
}

class _QuoteFinanceReturnDialogState extends State<_QuoteFinanceReturnDialog> {
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _useChip(String text) {
    final current = _reason.text.trim();
    final next = current.isEmpty
        ? text
        : current.contains(text)
        ? current
        : '$current; $text';
    setState(() {
      _reason.text = next;
      _reason.selection = TextSelection.collapsed(offset: next.length);
      _error = null;
    });
  }

  void _submit(AppLocalizations l10n) {
    final reason = _reason.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = l10n.quoteFinanceReturnReasonRequired);
      return;
    }
    Navigator.pop(context, reason);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chips = [
      l10n.quoteFinanceReturnChipQty,
      l10n.quoteFinanceReturnChipGoods,
      l10n.quoteFinanceReturnChipPrice,
    ];
    return AlertDialog(
      title: Text(l10n.quoteFinanceReturnTitle(widget.billNo)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UtenReviewerResponsibilityNotice(
                actionLabel: l10n.quoteFinanceActionReturn,
                compact: true,
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(l10n.quoteFinanceReturnBody),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  for (var i = 0; i < chips.length; i++)
                    ActionChip(
                      key: Key('quote-finance-return-chip-$i'),
                      avatar: const Icon(Icons.add_rounded, size: 18),
                      label: Text(chips[i]),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onPressed: () => _useChip(chips[i]),
                    ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                key: const Key('quote-finance-return-reason'),
                controller: _reason,
                autofocus: true,
                maxLength: 500,
                maxLines: 3,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: l10n.quoteFinanceReturnReasonLabel,
                    border: const OutlineInputBorder(),
                    error: utenFieldError(_error),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.quoteFinanceCancel),
        ),
        FinanceReviewClaimButton(
          key: const Key('quote-finance-return-submit'),
          claim: widget.claim,
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            minimumSize: const Size(0, 48),
          ),
          onPressed: () => _submit(l10n),
          child: Text(l10n.quoteFinanceReturnSubmit),
        ),
      ],
    );
  }
}

/// 批量设折扣：返回 4 位小数折扣；取消返回 null。
Future<String?> showQuoteFinanceBatchDiscountDialog(
  BuildContext context, {
  required int count,
  Widget Function(BuildContext, Widget)? decorate,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      final dialog = _QuoteFinanceBatchDiscountDialog(count: count);
      return decorate?.call(context, dialog) ?? dialog;
    },
  );
}

class _QuoteFinanceBatchDiscountDialog extends StatefulWidget {
  const _QuoteFinanceBatchDiscountDialog({required this.count});

  final int count;

  @override
  State<_QuoteFinanceBatchDiscountDialog> createState() =>
      _QuoteFinanceBatchDiscountDialogState();
}

class _QuoteFinanceBatchDiscountDialogState
    extends State<_QuoteFinanceBatchDiscountDialog> {
  final _discount = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _discount.dispose();
    super.dispose();
  }

  void _submit(AppLocalizations l10n) {
    final normalized = normalizeQuoteDiscount(_discount.text);
    if (normalized == null) {
      setState(() => _error = l10n.quoteFinanceErrorDiscount);
      return;
    }
    Navigator.pop(context, normalized);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.quoteFinanceBatchDiscountTitle(widget.count)),
      content: SizedBox(
        width: 400,
        child: TextField(
          key: const Key('quote-finance-batch-discount-input'),
          controller: _discount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onSubmitted: (_) => _submit(l10n),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText: l10n.quoteFinanceColDiscount,
              hintText: l10n.quoteFinanceBatchDiscountHint,
              border: const OutlineInputBorder(),
              error: utenFieldError(_error),
            ),
            info: l10n.quoteFinanceColDiscountInfo,
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.quoteFinanceCancel),
        ),
        UtenButton(
          key: const Key('quote-finance-batch-discount-apply'),
          onPressed: () => _submit(l10n),
          child: Text(l10n.quoteFinanceBatchApply),
        ),
      ],
    );
  }
}
