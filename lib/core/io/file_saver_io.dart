// 移动/桌面实现：写入下载目录(桌面)或文档目录(移动)，返回完整路径。
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String> saveBytes(Uint8List bytes, String filename) async {
  final Directory dir;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    // 桌面优先下载目录（用户最易找）；取不到回落文档目录。
    dir =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
  } else {
    dir = await getApplicationDocumentsDirectory();
  }
  final file = await _availableFile(dir, filename);
  await file.writeAsBytes(bytes);
  return file.path;
}

Future<File> _availableFile(Directory directory, String filename) async {
  File candidate = File('${directory.path}${Platform.pathSeparator}$filename');
  if (!await candidate.exists()) return candidate;

  final dot = filename.lastIndexOf('.');
  final hasExtension = dot > 0 && dot < filename.length - 1;
  final stem = hasExtension ? filename.substring(0, dot) : filename;
  final extension = hasExtension ? filename.substring(dot) : '';
  for (var copy = 1; copy <= 9999; copy++) {
    candidate = File(
      '${directory.path}${Platform.pathSeparator}$stem ($copy)$extension',
    );
    if (!await candidate.exists()) return candidate;
  }
  throw const FileSystemException('No available download filename');
}
