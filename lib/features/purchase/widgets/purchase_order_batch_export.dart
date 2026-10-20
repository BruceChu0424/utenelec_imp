// 采购任务工作台「进行中」段的批量导出单据（2026-10-19）。
//
// 与详情页「打印单据」按钮同一条链路：逐单取服务端 print-data 快照，在前端
// 生成与打印预览完全一致的采购单 PDF；批量口径下不再逐份弹系统打印对话框，
// 而是落成文件——单份直接保存 PDF，多份打包成一个 zip。本模块属于 purchase
// feature，由 app_router 注入进共享的 OperationsWorkbenchPage（工作台不依赖
// purchase feature，与 draftCategoryBuilder 同一解耦模式）。
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

import '../../../core/io/file_saver.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/ui/app_notification.dart';
import '../models/purchase_order_print_document.dart';
import 'purchase_order_print_preview.dart';

/// 工作台侧的批量导出能力签名（结构化函数类型，purchase 侧实现与之匹配；
/// 共享页不 import 本文件，测试注入 fake 闭包即可）。
typedef OperationsWorkbenchBatchDocExport =
    Future<void> Function(
      BuildContext context, {
      required ApiClient apiClient,
      required List<({String id, String number})> documents,
      void Function(int done, int total)? onProgress,
      bool Function()? stillCurrent,
    });

/// 打印字体只解析一次：NotoSansSCFull 有 17MB，逐份重复 load + TTF 解析
/// 会让几十份的批量导出线性变慢。
pw.Font? _cachedPrintFont;

Future<pw.Font> _loadPrintFont() async => _cachedPrintFont ??= pw.Font.ttf(
  await rootBundle.load('assets/fonts/NotoSansSCFull.ttf'),
);

/// 逐单导出采购单 PDF：单份保存 PDF，多份打包 zip；部分失败不打断其余
/// 单据，结束后汇总提示。文件落点与 Excel 导出同口径（桌面=下载目录，
/// Web=浏览器下载）。
///
/// [saver] 仅测试注入（避免写真实下载目录）；缺省走 [saveBytes]。
Future<void> exportPurchaseOrderDocumentsBatch(
  BuildContext context, {
  required ApiClient apiClient,
  required List<({String id, String number})> documents,
  void Function(int done, int total)? onProgress,
  bool Function()? stillCurrent,
  Future<String> Function(
    Uint8List bytes,
    String filename, {
    bool Function()? stillCurrent,
  })?
  saver,
}) async {
  if (documents.isEmpty) return;
  final font = await _loadPrintFont();
  final done = <String, Uint8List>{}; // 文件名 → PDF 字节（单号全局唯一）。
  final failed = <String>[];
  var processed = 0;
  for (final document in documents) {
    try {
      final json = await apiClient.get(
        '/purchase/orders/${Uri.encodeComponent(document.id)}/print-data',
      );
      final paper = PurchaseOrderPrintDocument.fromJson(json);
      done['采购单-${paper.billNo}.pdf'] = await buildPurchaseOrderPdf(
        paper,
        font: font,
      );
    } catch (_) {
      failed.add(document.number.isEmpty ? document.id : document.number);
    } finally {
      processed++;
      onProgress?.call(processed, documents.length);
    }
    if (!(stillCurrent?.call() ?? true)) return;
  }
  if (!(stillCurrent?.call() ?? true)) return;
  if (done.isEmpty) {
    if (context.mounted) context.appError('全部单据导出失败，请稍后重试');
    return;
  }
  final String name;
  final Uint8List bytes;
  if (done.length == 1) {
    name = done.keys.single;
    bytes = done.values.single;
  } else {
    final archive = Archive();
    for (final entry in done.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    name = '采购单批量导出(${done.length}份).zip';
    // ZipEncoder.encode 的静态签名是 List<int>，saveBytes 要 Uint8List。
    bytes = Uint8List.fromList(ZipEncoder().encode(archive));
  }
  final String saved;
  try {
    saved = await (saver ?? saveBytes)(bytes, name, stillCurrent: stillCurrent);
  } on StateError {
    // 导出期间身份/服务器已变化：按导出统一口径放弃落盘，不再提示。
    return;
  }
  if (!context.mounted || !(stillCurrent?.call() ?? true)) return;
  final l10n = AppLocalizations.of(context);
  context.appSuccess(
    kIsWeb ? l10n.exportDownloadStarted(name) : l10n.exportDownloadSaved(saved),
  );
  if (failed.isNotEmpty) {
    context.appWarning(
      '已导出 ${done.length} 份，${failed.length} 份失败：${failed.join('、')}',
    );
  }
}
