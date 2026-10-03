import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/ai/ai_job_models.dart';
import '../../../shared/ai/ai_job_runner.dart';
import '../../../shared/ai/ai_progress_dialog.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../intake/sales_intake_launcher.dart';
import 'sales_quote_template.dart';
import 'sales_quote_template_repository.dart';
import 'sales_quote_template_scope.dart';

/// Reuses the public AI runner. The dedicated mode never applies source rows to a quotation.
Future<SalesQuoteTemplate?> learnSalesQuoteTemplate(
  BuildContext context,
  WidgetRef ref,
  String quoteId, {
  bool Function()? stillCurrent,
}) async {
  final scope = SalesQuoteTemplateScope(ref);
  bool current() =>
      context.mounted &&
      scope.current(ref, learning: true) &&
      (stillCurrent?.call() ?? true);
  if (!context.mounted || !current()) return null;
  final l10n = AppLocalizations.of(context);
  final repository = ref.read(salesQuoteTemplateRepositoryProvider);
  final target = await repository.learningContext(quoteId);
  if (!context.mounted || !current()) return null;
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xlsx', 'xls'],
    withData: true,
    allowCompression: false,
  );
  if (!context.mounted ||
      !current() ||
      picked == null ||
      picked.files.isEmpty) {
    return null;
  }
  final file = picked.files.single;
  final extension = file.name.split('.').last.toLowerCase();
  final bytes = file.bytes;
  if (!const {'xlsx', 'xls'}.contains(extension) ||
      bytes == null ||
      bytes.isEmpty ||
      bytes.length > kSalesIntakeMaxFileBytes) {
    context.appError(l10n.quoteTemplateFileRequired);
    return null;
  }
  int? sheet;
  final attemptId = const Uuid().v4();
  while (context.mounted && current()) {
    final request = AiJobRequest(
      kind: 'SALES_DOCUMENT_INTAKE',
      params: {
        'docType': 'quote',
        'docId': quoteId,
        'clientId': target['clientId'].toString(),
        'templateOnly': 'true',
        'templateAttemptId': attemptId,
        if (sheet != null) 'sheet': '$sheet',
      },
      bytes: bytes,
      fileName: file.name,
      contentType: kSalesIntakeContentTypes[extension]!,
    );
    final runner = ref.read(aiJobRunnerProvider);
    final AiJobSnapshot? snapshot;
    try {
      snapshot = await ref.read(salesIntakeProgressPresenterProvider)(
        context,
        title: l10n.quoteTemplateLearningTitle,
        subtitle: file.name,
        stages: [
          AiProgressStage(
            key: AiJobSnapshot.uploadingStage,
            label: l10n.salesIntakeStageUpload,
          ),
          AiProgressStage(key: 'READING', label: l10n.salesIntakeStageRead),
          AiProgressStage(
            key: 'LAYOUT',
            label: l10n.salesIntakeStageLayout,
            serverStages: const ['EXTRACTING'],
          ),
        ],
        task: (progress, cancel) async {
          if (!current()) cancel.cancel();
          final identityWatch = ref.listenManual(exportContextEpochProvider, (
            _,
            _,
          ) {
            if (!current()) cancel.cancel();
          });
          try {
            return await runner.run(
              request,
              onProgress: progress,
              cancelToken: cancel,
            );
          } finally {
            identityWatch.close();
          }
        },
      );
    } on AiJobFailure catch (failure) {
      if (context.mounted && current()) context.appError(failure.message);
      return null;
    }
    if (!context.mounted || !current() || snapshot == null) return null;
    if (snapshot.status != AiJobStatus.succeeded ||
        snapshot.result?['templateOnly'] != true ||
        snapshot.result?['mapping'] is! Map) {
      context.appError(snapshot.errorMessage ?? l10n.quoteTemplateUnreadable);
      return null;
    }
    final result = snapshot.result!;
    final review = await showDialog<TemplateReviewDecision>(
      context: context,
      builder: (_) => SalesQuoteTemplateScopeDialog(
        stillCurrent: current,
        child: SalesQuoteTemplateReview(
          result: result,
          clientName: target['clientName']?.toString() ?? '',
        ),
      ),
    );
    if (review == null || !context.mounted || !current()) return null;
    if (review.sheetIndex != null) {
      sheet = review.sheetIndex;
      continue;
    }
    final saved = await repository.adopt(
      quoteId,
      snapshot.id,
      columnRoles: review.columnRoles,
    );
    if (!context.mounted || !current()) return null;
    context.appSuccess(l10n.quoteTemplateSaved);
    return saved;
  }
  return null;
}

class TemplateReviewDecision {
  const TemplateReviewDecision({this.sheetIndex, this.columnRoles});
  final int? sheetIndex;
  final Map<String, String>? columnRoles;
}

/// Displays only the server's sanitized field mapping, never untrusted file content as UI instructions.
class SalesQuoteTemplateReview extends StatefulWidget {
  const SalesQuoteTemplateReview({
    super.key,
    required this.result,
    required this.clientName,
  });
  final Map<String, dynamic> result;
  final String clientName;

  @override
  State<SalesQuoteTemplateReview> createState() =>
      _SalesQuoteTemplateReviewState();
}

class _SalesQuoteTemplateReviewState extends State<SalesQuoteTemplateReview> {
  late final Map<String, dynamic> mapping = Map<String, dynamic>.from(
    widget.result['mapping'] as Map,
  );
  late final Map<String, dynamic> headers = {
    ...Map<String, dynamic>.from(mapping['roleHeaders'] as Map? ?? {}),
    ...Map<String, dynamic>.from(mapping['extraHeaders'] as Map? ?? {}),
    ...Map<String, dynamic>.from(mapping['availableHeaders'] as Map? ?? {}),
  };
  late final Map<String, String> roles = {
    for (final key in headers.keys)
      key:
          (mapping['confirmedColumnRoles'] as Map?)?[key]?.toString() ??
          ((mapping['extraHeaders'] as Map?)?.containsKey(key) == true
              ? 'REFERENCE'
              : ((mapping['roles'] as Map?)?[key]?.toString() ?? 'REFERENCE')),
  };
  static const selectable = {
    'PART_NO',
    'DESCRIPTION',
    'DESCRIPTION_ALT',
    'COLOR',
    'QTY',
    'UNIT',
    'UNIT_PRICE',
    'DISCOUNT',
    'AMOUNT',
    'REMARK',
    'LINE_NO',
    'SERIES',
    'REFERENCE',
    'IGNORED',
  };

  @override
  void initState() {
    super.initState();
    roles.updateAll(
      (key, value) => selectable.contains(value) ? value : 'REFERENCE',
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = {
      'PART_NO': l10n.quoteFinanceColFileModel,
      'DESCRIPTION': l10n.quoteFinanceColFileName,
      'DESCRIPTION_ALT': l10n.quoteFinanceColGoods,
      'GOODS_NAME': l10n.quoteFinanceColGoods,
      'GOODS_NAME_EN': l10n.goodsNameEnLabel,
      'GOODS_CODE': l10n.quoteFinanceColCode,
      'COLOR': l10n.quoteFinanceColColor,
      'QTY': l10n.quoteFinanceColQty,
      'UNIT': l10n.quoteFinanceColUnit,
      'UNIT_PRICE': roles.containsValue('DISCOUNT')
          ? l10n.quoteFinanceColListPrice
          : l10n.quoteFinanceColDealPrice,
      'DISCOUNT': l10n.quoteFinanceColDiscount,
      'AMOUNT': l10n.quoteFinanceColLineAmount,
      'REMARK': l10n.quoteFinanceColRemark,
      'LINE_NO': l10n.warehouseOutboundLineNo,
      'SERIES': l10n.warehouseStockOutboundSeries,
      'REFERENCE': l10n.quoteTemplateReference,
      'IGNORED': l10n.costImportSkip,
    };
    final assigned = roles.values
        .where((value) => value != 'REFERENCE' && value != 'IGNORED')
        .toList();
    final error =
        !roles.containsValue('QTY') ||
            !roles.values.any(
              (value) =>
                  {'PART_NO', 'DESCRIPTION', 'DESCRIPTION_ALT'}.contains(value),
            )
        ? l10n.quoteTemplateMappingRequired
        : assigned.toSet().length != assigned.length
        ? l10n.quoteTemplateMappingDuplicate
        : null;
    final otherSheets = (widget.result['otherSheets'] as List? ?? [])
        .whereType<Map<dynamic, dynamic>>();
    return AlertDialog(
      title: Text(l10n.quoteTemplateReviewTitle),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .6,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${l10n.quoteFinanceFieldClient}: ${widget.clientName}'),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  '${l10n.quoteTemplateSheet}: ${widget.result['sheetName'] ?? ''}',
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(l10n.quoteTemplateReviewHint),
                for (final notice in (widget.result['notices'] as List? ?? []))
                  Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s8),
                    child: Text(notice.toString()),
                  ),
                const SizedBox(height: UtenSpacing.s12),
                for (final entry in roles.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                    child: UtenDropdownField(
                      key: ValueKey('quote-template-role-${entry.key}'),
                      label:
                          '${entry.key} · ${headers[entry.key] ?? entry.key}',
                      value: entry.value,
                      allowClear: false,
                      items: [
                        for (final role in selectable)
                          UtenDropdownItem(value: role, label: labels[role]!),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => roles[entry.key] = value);
                        }
                      },
                    ),
                  ),
                if (error != null)
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                for (final sheet in otherSheets)
                  UtenButton(
                    type: UtenButtonType.ghost,
                    onPressed: sheet['index'] is num
                        ? () => Navigator.of(context).pop(
                            TemplateReviewDecision(
                              sheetIndex: (sheet['index'] as num).toInt(),
                            ),
                          )
                        : null,
                    child: Flexible(
                      child: Text(
                        '${l10n.quoteTemplateSheet}: ${sheet['name']}',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: Flexible(child: Text(l10n.commonCancel)),
        ),
        UtenButton(
          key: const ValueKey('quote-template-adopt'),
          onPressed: error != null
              ? null
              : () => Navigator.of(
                  context,
                ).pop(TemplateReviewDecision(columnRoles: Map.of(roles))),
          child: Flexible(child: Text(l10n.quoteTemplateSaveDownload)),
        ),
      ],
    );
  }
}
