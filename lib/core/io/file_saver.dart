// 跨端字节保存：Web 浏览器 blob 下载；移动/桌面写入下载/文档目录。
// 条件导入：dart:io 可用（移动/桌面）走 io 实现，否则（Web）走 dart:html 实现——
// 这样 dart:html 不会在移动端被编译（条件导入的语义保证）。
import 'dart:typed_data';

import 'file_saver_web.dart' if (dart.library.io) 'file_saver_io.dart' as impl;

/// 保存 [bytes] 为 [filename]：Web 触发浏览器下载；IO 写入下载目录(桌面)/文档目录(移动)。
/// 返回：Web = filename；IO = 完整保存路径（供 toast 提示用户去哪找）。
Future<String> saveBytes(Uint8List bytes, String filename) =>
    impl.saveBytes(bytes, sanitizeDownloadFilename(filename));

/// Converts a display label or server-provided filename into one safe leaf name.
///
/// File downloads must never be able to escape the selected download directory.
/// The same normalization is used on Web so filenames behave consistently across
/// platforms.
String sanitizeDownloadFilename(String filename) {
  var safe = filename
      .trim()
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ');
  safe = safe.replaceAll(RegExp(r'^\.+|\.+$'), '');
  if (safe.isEmpty) safe = 'download';
  if (safe.length > 180) safe = safe.substring(0, 180).trimRight();
  return safe;
}
