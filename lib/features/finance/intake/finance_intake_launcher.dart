import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/ai/ai_job_models.dart';
import '../../../shared/ai/ai_job_repository.dart';
import '../../../shared/ai/ai_job_runner.dart';
import '../../../shared/ai/ai_progress_dialog.dart';
import '../models/finance_doc.dart';
import 'finance_intake_models.dart';
import 'finance_intake_l10n.dart';

export 'finance_intake_models.dart';

typedef FinanceIntakeLauncher =
    Future<FinanceIntakePatch?> Function(
      BuildContext context,
      WidgetRef ref, {
      required PlatformFile file,
      required FinanceDocType docType,
      required bool Function() stillCurrent,
      Map<FinanceIntakeField, String> currentFields,
    });

final financeIntakeLauncherProvider = Provider<FinanceIntakeLauncher>(
  (ref) => launchFinanceIntakeWithFile,
);

/// Local-only parsing on the business server, followed by explicit field review.
/// The caller's fence must cover identity, permission, file membership and form revision.
Future<FinanceIntakePatch?> launchFinanceIntakeWithFile(
  BuildContext context,
  WidgetRef ref, {
  required PlatformFile file,
  required FinanceDocType docType,
  required bool Function() stillCurrent,
  Map<FinanceIntakeField, String> currentFields = const {},
}) async {
  if (!stillCurrent()) return null;
  if (docType != FinanceDocType.receipt && docType != FinanceDocType.payment) {
    throw ApiException(
      'FINANCE_INTAKE_UNSUPPORTED',
      financeIntakeText(context, 'unsupportedType'),
    );
  }
  final contentType = financeIntakeContentTypes[file.extension?.toLowerCase()];
  if (contentType == null) {
    throw ApiException(
      'FINANCE_INTAKE_UNSUPPORTED',
      financeIntakeText(context, 'unsupportedFile'),
    );
  }
  if (file.bytes?.isNotEmpty != true || file.bytes!.length > 15 * 1024 * 1024) {
    throw ApiException(
      'FINANCE_INTAKE_SIZE',
      financeIntakeText(context, 'size'),
    );
  }
  final retained = PlatformFile(
    name: file.name,
    size: file.bytes!.length,
    bytes: Uint8List.fromList(file.bytes!).asUnmodifiableView(),
  );
  final snapshot = await runAiJob(
    context,
    runner: ref.read(aiJobRunnerProvider),
    request: AiJobRequest(
      kind: financeIntakeKind,
      params: {'docType': docType.name},
      bytes: retained.bytes!,
      fileName: retained.name,
      contentType: contentType,
    ),
    title: financeIntakeText(context, 'title'),
    subtitle: financeIntakeText(context, 'subtitle'),
    stages: [
      AiProgressStage(
        key: 'upload',
        label: financeIntakeText(context, 'upload'),
        serverStages: const [AiJobSnapshot.uploadingStage, 'STARTING'],
      ),
      AiProgressStage(
        key: 'read',
        label: financeIntakeText(context, 'read'),
        serverStages: const ['READING', 'PARSING'],
      ),
      AiProgressStage(
        key: 'check',
        label: financeIntakeText(context, 'check'),
        serverStages: const ['CHECKING_FIELDS', 'READY_TO_REVIEW'],
      ),
    ],
  );
  if (!context.mounted || !stillCurrent() || snapshot == null) return null;
  FinanceIntakeResult checked(AiJobSnapshot value) {
    if (value.id != snapshot.id ||
        value.kind != financeIntakeKind ||
        value.status != AiJobStatus.succeeded ||
        value.result == null) {
      throw ApiException(
        'FINANCE_INTAKE_EXPIRED',
        financeIntakeText(context, 'expired'),
      );
    }
    final result = FinanceIntakeResult.fromJson(value.result!);
    if (!result.matchesSource(retained, docType)) {
      throw ApiException(
        'FINANCE_INTAKE_SOURCE',
        financeIntakeText(context, 'sourceMismatch'),
      );
    }
    return result;
  }

  final result = checked(snapshot);
  final selected = await showDialog<Set<FinanceIntakeField>>(
    context: context,
    builder: (_) => FinanceIntakeReviewDialog(
      result: result,
      docType: docType,
      currentFields: currentFields,
    ),
  );
  if (!context.mounted ||
      !stillCurrent() ||
      selected == null ||
      selected.isEmpty) {
    return null;
  }
  // Confirmation is a second authorization boundary; never apply a stale cached job.
  final fresh = await ref.read(aiJobRepositoryProvider).get(snapshot.id);
  if (!context.mounted || !stillCurrent()) return null;
  final verified = checked(fresh);
  if (jsonEncode(verified.fields.map((k, v) => MapEntry(k.name, v))) !=
      jsonEncode(result.fields.map((k, v) => MapEntry(k.name, v)))) {
    throw ApiException(
      'FINANCE_INTAKE_CHANGED',
      financeIntakeText(context, 'changed'),
    );
  }
  return FinanceIntakePatch(
    jobId: snapshot.id,
    file: retained,
    sourceSha256: verified.sourceSha256 as String,
    docType: docType,
    sourceCurrencyCode: verified.fields[FinanceIntakeField.currencyCode],
    confirmedFields: Map.unmodifiable({
      for (final field in selected) field: verified.fields[field]!,
    }),
  );
}

class FinanceIntakeReviewDialog extends StatefulWidget {
  const FinanceIntakeReviewDialog({
    super.key,
    required this.result,
    required this.docType,
    this.currentFields = const {},
  });
  final FinanceIntakeResult result;
  final FinanceDocType docType;
  final Map<FinanceIntakeField, String> currentFields;
  @override
  State<FinanceIntakeReviewDialog> createState() =>
      _FinanceIntakeReviewDialogState();
}

class _FinanceIntakeReviewDialogState extends State<FinanceIntakeReviewDialog> {
  final _selected = <FinanceIntakeField>{};
  bool _selectable(FinanceIntakeField field) =>
      field != FinanceIntakeField.transactionDate &&
      field != FinanceIntakeField.bankFee &&
      !(field == FinanceIntakeField.accountAmount &&
          !widget.result.fields.containsKey(FinanceIntakeField.currencyCode));
  bool get _canApply => _selected.any(
    (field) =>
        field == FinanceIntakeField.bankReference ||
        field == FinanceIntakeField.accountAmount,
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(financeIntakeText(context, 'reviewTitle')),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.result.fileName as String),
            const SizedBox(height: UtenSpacing.s12),
            Text(financeIntakeText(context, 'reviewHint')),
            Text(financeIntakeText(context, 'dateHint')),
            if (!widget.result.fields.containsKey(
              FinanceIntakeField.currencyCode,
            ))
              Text(financeIntakeText(context, 'currencyHint')),
            if (widget.result.fields.containsKey(FinanceIntakeField.bankFee))
              Text(financeIntakeText(context, 'receiptFeeHint')),
            const SizedBox(height: UtenSpacing.s8),
            for (final warning in widget.result.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                child: Text(financeIntakeWarning(context, warning)),
              ),
            for (final entry in widget.result.fields.entries)
              CheckboxListTile(
                key: ValueKey('finance-intake-field-${entry.key.name}'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  '${financeIntakeText(context, entry.key == FinanceIntakeField.accountAmount ? (widget.docType == FinanceDocType.receipt ? 'receiptAmount' : 'paymentAmount') : entry.key.name)}: ${entry.value}',
                ),
                subtitle: Text(
                  [
                    if ((widget.currentFields[entry.key]?.trim().isNotEmpty ??
                            false) &&
                        widget.currentFields[entry.key] != entry.value)
                      '${financeIntakeText(context, 'current')}: ${widget.currentFields[entry.key]} → ${financeIntakeText(context, 'suggestion')}: ${entry.value}',
                    widget.result.fieldSources[entry.key] ??
                        financeIntakeText(context, 'sourceHint'),
                  ].join('\n'),
                ),
                value: _selected.contains(entry.key),
                onChanged: !_selectable(entry.key)
                    ? null
                    : (checked) => setState(() {
                        checked == true
                            ? _selected.add(entry.key)
                            : _selected.remove(entry.key);
                      }),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(financeIntakeText(context, 'cancel')),
      ),
      FilledButton(
        key: const ValueKey('finance-intake-confirm'),
        onPressed: !_canApply
            ? null
            : () => Navigator.of(
                context,
              ).pop(Set<FinanceIntakeField>.of(_selected)),
        child: Text(
          financeIntakeText(
            context,
            'apply',
          ).replaceAll('{count}', '${_selected.length}'),
        ),
      ),
    ],
  );
}
