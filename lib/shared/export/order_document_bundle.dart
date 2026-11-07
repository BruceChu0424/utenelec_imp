import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../core/performance/ui_work_budget.dart';
import 'document_batch_limits.dart';
import '../print/procurement_order_pdf.dart';
import '../print/procurement_order_print_document.dart';

/// Byte budgets bound a complete document export. Request/proof batches stay
/// bounded independently of the number of selected documents.
abstract final class OrderDocumentExportLimits {
  static const authorizationBatchSize = orderDocumentAuthorizationBatchSize;
  static const sourceBytes = 32 * 1024 * 1024;
  static const artifactBytes = 100 * 1024 * 1024;
  static const metadataBytes = 64 * 1024;
}

/// Serialisation yields between values. It does not block input while copying
/// a complete batch to the worker, and rejects oversized input before launch.
Future<({String payload, int bytes})> encodeOrderBundleInput(
  List<Map<String, dynamic>> documents, {
  required bool Function() stillCurrent,
}) async {
  if (documents.isEmpty) throw StateError('请选择需要导出的单据');
  final output = StringBuffer();
  var bytes = 0;
  final work = UiWorkBudget(
    isCurrent: stillCurrent,
    debugLabel: 'order-pdf-worker-input',
  );
  void append(String value) {
    bytes += utf8.encode(value).length;
    if (bytes > OrderDocumentExportLimits.sourceBytes) {
      throw StateError('单据快照超过32MiB读取预算，请缩小本批单据');
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
          value.length > OrderDocumentExportLimits.sourceBytes) {
        throw StateError('单据快照超过32MiB读取预算，请缩小本批单据');
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
Future<Uint8List> renderOrderBundle(
  String payload,
  Uint8List? fontBytes, {
  required ProcurementOrderPrintKind kind,
}) async {
  final successful = <Map<String, String>>[];
  final failed = <String>[];
  final files = <String, Uint8List>{};
  var retainedBytes = 0;
  try {
    if (utf8.encode(payload).length > OrderDocumentExportLimits.sourceBytes) {
      throw const _ResourceLimit();
    }
    final raw = jsonDecode(payload) as List;
    if (raw.isEmpty) throw const _ResourceLimit();
    final font = fontBytes == null
        ? pw.Font.helvetica()
        : pw.Font.ttf(ByteData.sublistView(fontBytes));
    final ids = <String>{};
    for (final value in raw) {
      final document = ProcurementOrderPrintDocument.fromJson(
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
        final pdf = await renderProcurementOrderPdf(
          document,
          font: font,
          kind: kind,
        );
        if (pdf.length >
            OrderDocumentExportLimits.artifactBytes - retainedBytes) {
          throw const _ResourceLimit();
        }
        retainedBytes += pdf.length;
        // A filename must not silently replace another successful business object.
        final stem =
            '${kind.label}-${document.billNo.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')}';
        final safeId = document.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
        var filename = '$stem.pdf';
        var collision = 0;
        while (files.containsKey(filename)) {
          collision++;
          filename = collision == 1
              ? '$stem-$safeId.pdf'
              : '$stem-$safeId-$collision.pdf';
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
      final out = OrderDocumentZipOutput(
        OrderDocumentExportLimits.artifactBytes,
      );
      ZipEncoder().encodeStream(archive, out);
      bytes = out.getBytes();
      filename = '${kind.label}批量导出(${files.length}份).zip';
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
class OrderDocumentZipOutput extends OutputMemoryStream {
  OrderDocumentZipOutput(this.maximumBytes);
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

const _sectionedPacket = 0x554f4232;

Uint8List _packet(Map<String, Object?> metadata, Uint8List bytes) {
  final successful = metadata['successful'] as List? ?? const [];
  final failed = metadata['failed'] as List? ?? const [];
  final count = successful.length > failed.length
      ? successful.length
      : failed.length;
  final headers = <List<int>>[];
  var metadataBytes = 0;
  for (
    var start = 0;
    start < count || headers.isEmpty;
    start += OrderDocumentExportLimits.authorizationBatchSize
  ) {
    List<dynamic> section(List<dynamic> values) => start >= values.length
        ? const []
        : values.sublist(
            start,
            (start + OrderDocumentExportLimits.authorizationBatchSize).clamp(
              0,
              values.length,
            ),
          );
    final header = utf8.encode(
      jsonEncode({
        if (metadata['error'] != null) 'error': metadata['error'],
        'filename': metadata['filename'] ?? '',
        'successful': section(successful),
        'failed': section(failed),
      }),
    );
    if (header.length > OrderDocumentExportLimits.metadataBytes ||
        header.length > OrderDocumentExportLimits.sourceBytes - metadataBytes) {
      throw StateError('worker metadata');
    }
    metadataBytes += header.length;
    headers.add(header);
  }
  final output = Uint8List(
    8 + headers.length * 4 + metadataBytes + bytes.length,
  );
  final data = ByteData.sublistView(output)
    ..setUint32(0, _sectionedPacket)
    ..setUint32(4, headers.length);
  var offset = 8;
  for (final header in headers) {
    data.setUint32(offset, header.length);
    offset += 4;
    output.setRange(offset, offset + header.length, header);
    offset += header.length;
  }
  output.setRange(offset, output.length, bytes);
  return output;
}

class _BundlePacket {
  _BundlePacket(Uint8List packet) {
    if (packet.length < 4) throw const FormatException('worker packet');
    final data = ByteData.sublistView(packet);
    final first = data.getUint32(0);
    var offset = 4;
    var count = 1;
    if (first == _sectionedPacket) {
      if (packet.length < 8) throw const FormatException('worker packet');
      count = data.getUint32(4);
      if (count < 1 || count > (packet.length - 8) ~/ 5) {
        throw const FormatException('worker metadata');
      }
      offset = 8;
    }
    var metadataBytes = 0;
    for (var index = 0; index < count; index++) {
      final int length;
      if (first == _sectionedPacket) {
        if (offset > packet.length - 4) {
          throw const FormatException('worker metadata');
        }
        length = data.getUint32(offset);
        offset += 4;
      } else {
        length = first;
      }
      if (length > OrderDocumentExportLimits.metadataBytes ||
          length > packet.length - offset ||
          length > OrderDocumentExportLimits.sourceBytes - metadataBytes) {
        throw const FormatException('worker metadata');
      }
      metadataBytes += length;
      headers.add(Uint8List.sublistView(packet, offset, offset + length));
      offset += length;
    }
    bytes = Uint8List.sublistView(packet, offset);
    if (bytes.length > OrderDocumentExportLimits.artifactBytes) {
      throw const FormatException('worker artifact');
    }
  }
  final headers = <Uint8List>[];
  late final Uint8List bytes;
}

class OrderDocumentBundleResult {
  OrderDocumentBundleResult.decode(Uint8List packet) {
    final source = _BundlePacket(packet);
    for (final header in source.headers) {
      _append(header);
    }
    bytes = source.bytes;
  }

  OrderDocumentBundleResult._();

  static Future<OrderDocumentBundleResult> decodeComplete(
    Uint8List packet, {
    required bool Function() stillCurrent,
  }) async {
    final work = UiWorkBudget(
      isCurrent: stillCurrent,
      maxItems: 1,
      debugLabel: 'order-pdf-worker-receipt',
    );
    work.ensureCurrent();
    final source = _BundlePacket(packet);
    final result = OrderDocumentBundleResult._();
    for (final header in source.headers) {
      result._append(header);
      await work.checkpoint();
    }
    work.ensureCurrent();
    result.bytes = source.bytes;
    return result;
  }

  void _append(Uint8List header) {
    final metadata = (jsonDecode(utf8.decode(header)) as Map)
        .cast<String, dynamic>();
    if (metadata['error'] == 'RESOURCE_LIMIT') {
      throw StateError('单据PDF或ZIP超过100MiB资源预算，请缩小本批单据；未保存半件');
    }
    final sectionName = metadata['filename'] as String;
    if (_filename != null && _filename != sectionName) {
      throw const FormatException('worker artifact identity');
    }
    _filename = sectionName;
    successful.addAll(
      (metadata['successful'] as List)
          .map((value) => (value as Map).cast<String, String>())
          .toList(growable: false),
    );
    failed.addAll((metadata['failed'] as List).cast<String>());
  }

  final successful = <Map<String, String>>[];
  final failed = <String>[];
  String? _filename;
  String get filename => _filename ?? '';
  late final Uint8List bytes;
}
