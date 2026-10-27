import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/feedback/uten_dialog.dart';
import '../../core/io/file_saver.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/ui/app_notification.dart';
import '../../core/print/isolated_print_pdf.dart';
import '../../core/performance/ui_work_budget.dart';
import '../../core/network/read_scope_revision.dart';
import '../providers/sensitive_read_boundary_provider.dart';
import 'order_document_bundle.dart';
import '../print/procurement_order_print_document.dart';

/// Shared injected workbench export contract; feature adapters supply the kind.
typedef OperationsWorkbenchBatchDocExport =
    Future<void> Function(
      BuildContext context, {
      required ApiClient apiClient,
      required List<({String id, String number})> documents,
      void Function(int done, int total)? onProgress,
      bool Function()? stillCurrent,
    });

/// Single PDF or ZIP publication with identity, content proof and resource guards.
/// Partial read/render failures are reported after the authorised output is saved.
///
/// 文件落点与 Excel 导出同口径(桌面=下载目录，
/// Web=浏览器下载)。
///
/// [saver] 仅测试注入(避免写真实下载目录)；缺省走 [saveBytes]。
Future<void> exportOrderDocumentsBatch(
  BuildContext context, {
  required ApiClient apiClient,
  required ProcurementOrderPrintKind kind,
  required Future<Uint8List> Function(String, Uint8List?) renderer,
  required List<({String id, String number})> documents,
  void Function(int done, int total)? onProgress,
  bool Function()? stillCurrent,
  Future<String> Function(
    Uint8List bytes,
    String filename, {
    bool Function()? stillCurrent,
  })?
  saver,
  Future<Uint8List> Function(PrintPdfRequest request)? generate,
}) async {
  final uniqueDocuments = {
    for (final document in documents) document.id: document,
  }.values.toList(growable: false);
  if (uniqueDocuments.isEmpty ||
      !context.mounted ||
      !(stillCurrent?.call() ?? true)) {
    return;
  }
  if (uniqueDocuments.length > OrderDocumentExportLimits.documents) {
    context.appError('一次最多导出100份${kind.label}，请分批选择');
    return;
  }
  ProviderContainer? container;
  try {
    container = ProviderScope.containerOf(context, listen: false);
  } on StateError {
    /* Standalone tests. */
  }
  final boundary = container?.read(sensitiveReadBoundaryProvider);
  final revision = container?.read(readScopeRevisionProvider);
  var retired = false;
  bool current() =>
      !retired &&
      context.mounted &&
      (stillCurrent?.call() ?? true) &&
      (container == null ||
          (container.read(sensitiveReadBoundaryProvider) == boundary &&
              container.read(readScopeRevisionProvider) == revision));
  final confirmed = await UtenDialog.show(
    context,
    title: '确认导出${kind.label}',
    content: Text(
      '将导出 ${uniqueDocuments.length} 份${kind.label}。请核对单号：\n'
      '${uniqueDocuments.map((document) => document.number.isEmpty ? document.id : document.number).join('、')}',
    ),
    confirmLabel: '确认导出',
    waitForExit: true,
  );
  if (confirmed != true || !context.mounted || !current()) {
    return;
  }
  final generator = IsolatedPrintPdfGenerator();
  void retire() {
    retired = true;
    generator.dispose();
  }

  final boundarySubscription = container?.listen(
    sensitiveReadBoundaryProvider,
    (_, next) {
      if (next != boundary) retire();
    },
  );
  final revisionSubscription = container?.listen(readScopeRevisionProvider, (
    _,
    next,
  ) {
    if (next != revision) retire();
  });
  final cancellation = Timer.periodic(const Duration(milliseconds: 25), (_) {
    if (!current()) retire();
  });
  final encodedDocuments = <String>[];
  var sourceBytes = 2;
  final failed = <String>[];
  final proofs = <String, String>{};
  final numbers = {
    for (final d in uniqueDocuments) d.id: d.number.isEmpty ? d.id : d.number,
  };
  var processed = 0;
  try {
    for (final document in uniqueDocuments) {
      if (!current() || !context.mounted) return;
      Map<String, dynamic>? fetched;
      try {
        final json = await apiClient.get(
          '${kind.endpoint}/${Uri.encodeComponent(document.id)}/print-data',
        );
        if (!current() || !context.mounted) return;
        if (json['id'] != document.id) {
          throw ApiException('CONFLICT', '${kind.label}快照身份不一致，请刷新后重新导出');
        }
        if (json['contentDigest'] is! String ||
            !RegExp(
              r'^[a-f0-9]{64}$',
            ).hasMatch(json['contentDigest'] as String)) {
          throw ApiException(
            'PRINT_PROOF_REQUIRED',
            '当前服务器未提供${kind.label}快照证明，不能安全交付此批单据，请更新服务器后重试',
          );
        }
        fetched = json;
      } catch (error) {
        failed.add(
          error is ApiException
              ? '${numbers[document.id]}：${error.message}'
              : numbers[document.id]!,
        );
      } finally {
        processed++;
        onProgress?.call(processed, uniqueDocuments.length);
      }
      if (fetched != null) {
        final encoded = await encodeOrderBundleInput([
          fetched,
        ], stillCurrent: current);
        final next =
            sourceBytes +
            encoded.bytes -
            2 +
            (encodedDocuments.isEmpty ? 0 : 1);
        if (next > OrderDocumentExportLimits.sourceBytes) {
          throw StateError('本批${kind.label}快照超过32MiB读取预算，请缩小本批单据；未保存半件');
        }
        sourceBytes = next;
        proofs[document.id] = fetched['contentDigest'] as String;
        encodedDocuments.add(
          encoded.payload.substring(1, encoded.payload.length - 1),
        );
      }
    }
    if (!current() || !context.mounted) return;
    if (encodedDocuments.isEmpty) {
      context.appError('未导出任何${kind.label}：${failed.join('；')}');
      return;
    }
    final payload = '[${encodedDocuments.join(',')}]';
    encodedDocuments.clear();
    final font = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
    if (!current() || !context.mounted) return;
    final request = PrintPdfRequest.binary(
      kind: kind.workerKind,
      payload: payload,
      renderer: renderer,
      fontBytes: font.buffer.asUint8List(
        font.offsetInBytes,
        font.lengthInBytes,
      ),
    );
    final packet = await (generate ?? generator.generate)(request);
    if (!current() || !context.mounted) return;
    final result = OrderDocumentBundleResult.decode(packet);
    failed.addAll(result.failed.map((id) => numbers[id] ?? id));
    final successfulIds = result.successful.map((value) => value['id']).toSet();
    if (successfulIds.length != result.successful.length ||
        successfulIds.any((id) => !proofs.containsKey(id)) ||
        result.successful.any(
          (proof) => proof['contentDigest'] != proofs[proof['id']],
        )) {
      throw StateError('${kind.label}输出身份不一致，未保存文件');
    }
    if (result.successful.isEmpty) {
      context.appError('未导出任何${kind.label}：${failed.join('；')}');
      return;
    }
    // Re-read each original authorised document on the server immediately before
    // publication. Owner/status/price masking and exact content must still match.
    await apiClient.post(
      '${kind.endpoint}/print-authorization',
      body: {
        'documents': [
          for (final proof in result.successful)
            {'id': proof['id'], 'contentDigest': proof['contentDigest']},
        ],
      },
    );
    if (!current() || !context.mounted) return;
    final name = result.filename;
    final bytes = result.bytes;
    final String saved;
    try {
      saved = await (saver ?? saveBytes)(bytes, name, stillCurrent: current);
    } on StateError {
      // 导出期间身份/服务器已变化：按导出统一口径放弃落盘，不再提示。
      return;
    }
    if (!current() || !context.mounted) return;
    final l10n = AppLocalizations.of(context);
    context.appSuccess(
      kIsWeb
          ? l10n.exportDownloadStarted(name)
          : l10n.exportDownloadSaved(saved),
    );
    if (failed.isNotEmpty) {
      context.appWarning(
        '已导出 ${result.successful.length} 份，${failed.length} 份失败：${failed.join('、')}',
      );
    }
  } on UiWorkCancelled {
    return;
  } catch (error) {
    if (current() && context.mounted) {
      context.appError(
        error is ApiException
            ? error.message
            : error is StateError
            ? error.message.toString()
            : '${kind.label}生成失败，未保存文件',
      );
    }
  } finally {
    cancellation.cancel();
    boundarySubscription?.close();
    revisionSubscription?.close();
    generator.dispose();
    encodedDocuments.clear();
  }
}
