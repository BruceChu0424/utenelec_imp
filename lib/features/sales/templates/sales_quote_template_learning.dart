import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/ai/ai_job_models.dart';
import '../../../shared/ai/ai_job_runner.dart';
import '../../../shared/ai/ai_progress_dialog.dart';
import '../intake/sales_intake_launcher.dart';
import 'sales_quote_template.dart';
import 'sales_quote_template_repository.dart';

/// Reuses the public AI runner. The dedicated mode never applies source rows to a quotation.
Future<SalesQuoteTemplate?> learnSalesQuoteTemplate(
  BuildContext context,
  WidgetRef ref,
  String quoteId,
) async {
  final l10n = AppLocalizations.of(context);
  final repository = ref.read(salesQuoteTemplateRepositoryProvider);
  final target = await repository.learningContext(quoteId);
  if (!context.mounted) return null;
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xlsx', 'xls'],
    withData: true,
    allowCompression: false,
  );
  if (!context.mounted || picked == null || picked.files.isEmpty) return null;
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
  while (context.mounted) {
    final request = AiJobRequest(
      kind: 'SALES_DOCUMENT_INTAKE',
      params: {
        'docType': 'quote',
        'docId': quoteId,
        'clientId': target['clientId'].toString(),
        'templateOnly': 'true',
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
        task: (progress, cancel) =>
            runner.run(request, onProgress: progress, cancelToken: cancel),
      );
    } on AiJobFailure catch (failure) {
      if (context.mounted) context.appError(failure.message);
      return null;
    }
    if (!context.mounted || snapshot == null) return null;
    if (snapshot.status != AiJobStatus.succeeded ||
        snapshot.result?['templateOnly'] != true ||
        snapshot.result?['mapping'] is! Map) {
      context.appError(snapshot.errorMessage ?? l10n.quoteTemplateUnreadable);
      return null;
    }
    final result = snapshot.result!;
    final review = await showDialog<TemplateReviewDecision>(
      context: context,
      builder: (_) => SalesQuoteTemplateReview(
        result: result,
        clientName: target['clientName']?.toString() ?? '',
      ),
    );
    if (review == null || !context.mounted) return null;
    if (review.sheetIndex != null) {
      sheet = review.sheetIndex;
      continue;
    }
    final saved = await repository.adopt(quoteId, snapshot.id);
    if (!context.mounted) return null;
    context.appSuccess(l10n.quoteTemplateSaved);
    return saved;
  }
  return null;
}

class TemplateReviewDecision {
  const TemplateReviewDecision({this.sheetIndex});
  final int? sheetIndex;
}

/// Displays only the server's sanitized field mapping, never untrusted file content as UI instructions.
class SalesQuoteTemplateReview extends StatelessWidget {
  const SalesQuoteTemplateReview({
    super.key,
    required this.result,
    required this.clientName,
  });
  final Map<String, dynamic> result;
  final String clientName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mapping = Map<String, dynamic>.from(result['mapping'] as Map);
    final roles = Map<String, dynamic>.from(mapping['roles'] as Map? ?? {});
    final headers = Map<String, dynamic>.from(
      mapping['roleHeaders'] as Map? ?? {},
    );
    final extras = Map<String, dynamic>.from(
      mapping['extraHeaders'] as Map? ?? {},
    );
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
    };
    final otherSheets = (result['otherSheets'] as List? ?? [])
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
                Text('${l10n.quoteFinanceFieldClient}: $clientName'),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  '${l10n.quoteTemplateSheet}: ${result['sheetName'] ?? ''}',
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(l10n.quoteTemplateReviewHint),
                for (final notice in (result['notices'] as List? ?? []))
                  Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s8),
                    child: Text(notice.toString()),
                  ),
                const SizedBox(height: UtenSpacing.s12),
                for (final entry in roles.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${entry.key} · ${headers[entry.key] ?? entry.key}',
                    ),
                    subtitle: Text(
                      labels[entry.value] ?? l10n.quoteTemplateReference,
                    ),
                  ),
                for (final entry in extras.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${entry.key} · ${entry.value}'),
                    subtitle: Text(l10n.quoteTemplateReference),
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
          onPressed: roles.isEmpty
              ? null
              : () => Navigator.of(context).pop(const TemplateReviewDecision()),
          child: Flexible(child: Text(l10n.quoteTemplateSaveDownload)),
        ),
      ],
    );
  }
}
