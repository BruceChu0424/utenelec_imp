import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/performance/ui_work_budget.dart';
import '../../../shared/export/document_batch_limits.dart';
import 'purchase_order_pdf.dart';
import 'purchase_order_print_document.dart';

/// Existing workbench business maximum, plus explicit local resource budgets.
/// This is a bounded small-document batch, not a streaming bulk-export source.
abstract final class PurchaseOrderExportLimits {
  static const documents = maxWorkbenchDocumentExport;
  static const sourceBytes = 32 * 1024 * 1024;
  static const artifactBytes = 100 * 1024 * 1024;
  static const metadataBytes = 64 * 1024;
}

/// Serialisation yields between values. It does not block input while copying
/// a complete batch to the worker, and rejects oversized input before launch.
Future<({String payload, int bytes})> encodePurchaseOrderBundleInput(
  List<Map<String, dynamic>> documents, {
  required bool Function() stillCurrent,
}) async {
  if (documents.isEmpty ||
      documents.length > PurchaseOrderExportLimits.documents) {
    throw StateError('一次最多导出100份采购单，请分批选择');
  }
  final output = StringBuffer();
  var bytes = 0;
  final work = UiWorkBudget(
    isCurrent: stillCurrent,
    debugLabel: 'purchase-pdf-worker-input',
  );
  void append(String value) {
    bytes += utf8.encode(value).length;
    if (bytes > PurchaseOrderExportLimits.sourceBytes) {
      throw StateError('采购单快照超过32MiB读取预算，请缩小本批单据');
    }
    output.write(value);
  }

  Future<void> write(Object? value) async {
    work.ensureCurrent();
    if (value is Map) {
      append('{');
      var first = true;
      for (final entry in value.entries) {
        if (entry.key is! String) throw const FormatException('snapshot key');
        if (!first) append(',');
        first = false;
        append(jsonEncode(entry.key));
        append(':');
        await write(entry.value);
      }
      append('}');
    } else if (value is List) {
      append('[');
      for (var index = 0; index < value.length; index++) {
        if (index > 0) append(',');
        await write(value[index]);
      }
      append(']');
    } else {
      if (value is String &&
          value.length > PurchaseOrderExportLimits.sourceBytes) {
        throw StateError('采购单快照超过32MiB读取预算，请缩小本批单据');
      }
      append(jsonEncode(value));
    }
    await work.checkpoint();
  }

  await write(documents);
  work.ensureCurrent();
  return (payload: output.toString(), bytes: bytes);
}

/// Pure feature renderer, invoked only inside the common dedicated worker.
/// The full Chinese font is parsed once for the complete batch, as before.
Future<Uint8List> renderPurchaseOrderBundle(
  String payload,
  Uint8List? fontBytes,
) async {
  final successful = <Map<String, String>>[];
  final failed = <String>[];
  final files = <String, Uint8List>{};
  var retainedBytes = 0;
  try {
    if (utf8.encode(payload).length > PurchaseOrderExportLimits.sourceBytes) {
      throw const _ResourceLimit();
    }
    final raw = jsonDecode(payload) as List;
    if (raw.isEmpty || raw.length > PurchaseOrderExportLimits.documents) {
      throw const _ResourceLimit();
    }
    final font = fontBytes == null
        ? pw.Font.helvetica()
        : pw.Font.ttf(ByteData.sublistView(fontBytes));
    final ids = <String>{};
    for (final value in raw) {
      final document = PurchaseOrderPrintDocument.fromJson(
        (value as Map).cast<String, dynamic>(),
      );
      if (!ids.add(document.id)) {
        throw const FormatException('duplicate snapshot');
      }
      try {
        if (document.contentDigest == null ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(document.contentDigest!)) {
          throw const FormatException('snapshot proof');
        }
        final pdf = await renderPurchaseOrderPdf(document, font: font);
        if (pdf.length >
            PurchaseOrderExportLimits.artifactBytes - retainedBytes) {
          throw const _ResourceLimit();
        }
        retainedBytes += pdf.length;
        // A filename must not silently replace another successful business object.
        var filename =
            '采购单-${document.billNo.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')}.pdf';
        if (files.containsKey(filename)) {
          filename =
              '${filename.substring(0, filename.length - 4)}-${document.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}.pdf';
        }
        files[filename] = pdf;
        successful.add({
          'id': document.id,
          'contentDigest': document.contentDigest!,
          'filename': filename,
        });
      } on _ResourceLimit {
        rethrow;
      } catch (_) {
        failed.add(document.id);
      }
    }
    if (files.isEmpty) {
      return _packet({
        'successful': successful,
        'failed': failed,
        'filename': '',
      }, Uint8List(0));
    }
    final String filename;
    final Uint8List bytes;
    if (files.length == 1) {
      filename = files.keys.single;
      bytes = files.values.single;
    } else {
      final archive = Archive();
      for (final entry in files.entries) {
        archive.addFile(
          ArchiveFile.bytes(entry.key, entry.value)
            ..compression = CompressionType.none,
        );
      }
      final out = PurchaseOrderZipOutput(
        PurchaseOrderExportLimits.artifactBytes,
      );
      ZipEncoder().encodeStream(archive, out);
      bytes = out.getBytes();
      filename = '采购单批量导出(${files.length}份).zip';
    }
    return _packet({
      'successful': successful,
      'failed': failed,
      'filename': filename,
    }, bytes);
  } on _ResourceLimit {
    return _packet({'error': 'RESOURCE_LIMIT'}, Uint8List(0));
  }
}

class _ResourceLimit implements Exception {
  const _ResourceLimit();
}

/// Archive output checks each write before growing its buffer. PDF inputs are
/// already compressed, so stored ZIP entries avoid a second compression heap.
class PurchaseOrderZipOutput extends OutputMemoryStream {
  PurchaseOrderZipOutput(this.maximumBytes);
  final int maximumBytes;
  void _reserve(int count) {
    if (count < 0 || count > maximumBytes - length) {
      throw const _ResourceLimit();
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _reserve(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _reserve(count);
    super.writeBackReference(distance, count);
  }
}

Uint8List _packet(Map<String, Object?> metadata, Uint8List bytes) {
  final header = utf8.encode(jsonEncode(metadata));
  if (header.length > PurchaseOrderExportLimits.metadataBytes) {
    throw StateError('worker metadata');
  }
  final output = Uint8List(4 + header.length + bytes.length);
  ByteData.sublistView(output).setUint32(0, header.length);
  output.setRange(4, 4 + header.length, header);
  output.setRange(4 + header.length, output.length, bytes);
  return output;
}

class PurchaseOrderBundleResult {
  PurchaseOrderBundleResult.decode(Uint8List packet) {
    if (packet.length < 4) throw const FormatException('worker packet');
    final length = ByteData.sublistView(packet).getUint32(0);
    if (length > PurchaseOrderExportLimits.metadataBytes ||
        length > packet.length - 4) {
      throw const FormatException('worker metadata');
    }
    final metadata =
        (jsonDecode(utf8.decode(Uint8List.sublistView(packet, 4, 4 + length)))
                as Map)
            .cast<String, dynamic>();
    if (metadata['error'] == 'RESOURCE_LIMIT') {
      throw StateError('采购单PDF或ZIP超过100MiB资源预算，请缩小本批单据；未保存半件');
    }
    successful = (metadata['successful'] as List)
        .map((value) => (value as Map).cast<String, String>())
        .toList(growable: false);
    failed = (metadata['failed'] as List).cast<String>();
    filename = metadata['filename'] as String;
    bytes = Uint8List.sublistView(packet, 4 + length);
    if (bytes.length > PurchaseOrderExportLimits.artifactBytes) {
      throw const FormatException('worker artifact');
    }
  }
  late final List<Map<String, String>> successful;
  late final List<String> failed;
  late final String filename;
  late final Uint8List bytes;
}
