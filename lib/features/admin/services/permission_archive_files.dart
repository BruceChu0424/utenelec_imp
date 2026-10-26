import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../../core/io/file_saver.dart';
import '../models/permission_configuration.dart';
import '../models/permission_template_archive.dart';

/// One bounded reader for configuration and template imports. Identity changes
/// after the native picker or any stream chunk discard the result.
Future<Uint8List?> pickPermissionArchiveBytes({
  required bool Function() stillCurrent,
}) async {
  if (!stillCurrent()) return null;
  final files = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['json'],
    withReadStream: true,
  );
  if (!stillCurrent() || files == null) return null;
  final file = files.files.single;
  if (file.size > permissionConfigurationMaxBytes) {
    throw const FormatException('权限文件不能超过 16 MB');
  }
  final bytes = BytesBuilder(copy: false);
  if (file.bytes != null) {
    if (file.bytes!.length > permissionConfigurationMaxBytes) {
      throw const FormatException('权限文件不能超过 16 MB');
    }
    bytes.add(file.bytes!);
  } else if (file.readStream != null) {
    await for (final part in file.readStream!) {
      if (!stillCurrent()) return null;
      if (bytes.length + part.length > permissionConfigurationMaxBytes) {
        throw const FormatException('权限文件不能超过 16 MB');
      }
      bytes.add(part);
    }
  } else {
    throw const FormatException('无法读取文件，请重新选择权限文件');
  }
  return stillCurrent() ? bytes.takeBytes() : null;
}

Future<PermissionTemplateArchive?> pickPermissionTemplateArchive({
  required bool Function() stillCurrent,
}) async {
  final bytes = await pickPermissionArchiveBytes(stillCurrent: stillCurrent);
  return bytes == null ? null : PermissionTemplateArchive.decode(bytes);
}

/// Preserve a readable scope/name prefix while reserving room for .json.
String permissionArchiveFilename(String scope, [String? name]) {
  final label = name?.trim();
  final prefix = '权限-$scope${label == null || label.isEmpty ? '' : '-$label'}';
  final safe = sanitizeDownloadFilename(prefix);
  return '${safe.length > 175 ? safe.substring(0, 175).trimRight() : safe}.json';
}
