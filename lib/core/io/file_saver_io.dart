// 移动/桌面实现：写入下载目录(桌面)或文档目录(移动)，返回完整路径。
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String> saveBytes(Uint8List bytes, String filename) async {
  final Directory dir;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    // 桌面优先下载目录（用户最易找）；取不到回落文档目录。
    dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  } else {
    dir = await getApplicationDocumentsDirectory();
  }
  final file = File('${dir.path}${Platform.pathSeparator}$filename');
  await file.writeAsBytes(bytes);
  return file.path;
}
