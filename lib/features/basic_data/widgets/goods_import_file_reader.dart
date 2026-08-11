import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

const int maxGoodsImportBytes = 50 * 1024 * 1024;

/// A user-correctable problem found while reading a selected goods workbook.
class GoodsImportFileException implements Exception {
  const GoodsImportFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads a picked workbook without requiring the browser to materialize the
/// whole file inside the picker callback.
///
/// The stream path is important on Flutter Web: it lets us enforce the same
/// 50 MB limit as the server while producing a useful error instead of the
/// file picker's generic JavaScript exception.
Future<Uint8List> readGoodsImportFile(PlatformFile file) async {
  if (file.size > maxGoodsImportBytes) {
    throw const GoodsImportFileException('Excel 文件超过 50MB，请拆分后再导入');
  }

  final directBytes = file.bytes;
  if (directBytes != null) {
    return _validateWorkbookBytes(directBytes);
  }

  final stream = file.readStream;
  if (stream == null) {
    if (file.size <= 0) {
      throw const GoodsImportFileException('所选 Excel 文件为空，请重新选择');
    }
    throw const GoodsImportFileException('无法读取所选 Excel，请确认文件未被移动、删除或占用后重试');
  }

  final builder = BytesBuilder(copy: false);
  try {
    await for (final chunk in stream) {
      if (builder.length + chunk.length > maxGoodsImportBytes) {
        throw const GoodsImportFileException('Excel 文件超过 50MB，请拆分后再导入');
      }
      builder.add(chunk);
    }
  } on GoodsImportFileException {
    rethrow;
  } catch (_) {
    throw const GoodsImportFileException('无法读取所选 Excel，请确认文件未损坏或未被其它程序占用后重试');
  }

  return _validateWorkbookBytes(builder.takeBytes());
}

Uint8List _validateWorkbookBytes(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const GoodsImportFileException('所选 Excel 文件为空，请重新选择');
  }

  // Password-protected OOXML workbooks are stored in an OLE compound file.
  // Detect that signature before upload so staff get a recovery instruction
  // instead of an opaque POI/server error.
  const encryptedOfficeSignature = <int>[
    0xD0,
    0xCF,
    0x11,
    0xE0,
    0xA1,
    0xB1,
    0x1A,
    0xE1,
  ];
  if (_startsWith(bytes, encryptedOfficeSignature)) {
    throw const GoodsImportFileException(
      '文件为旧版 .xls 或已设置打开密码；请先另存为未加密的 .xlsx 再导入',
    );
  }

  // A normal .xlsx is an OOXML ZIP package and starts with a PK signature.
  if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
    throw const GoodsImportFileException(
      '文件内容不是有效的 .xlsx，请用 Excel 另存为 .xlsx 后重试',
    );
  }
  return bytes;
}

bool _startsWith(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}
