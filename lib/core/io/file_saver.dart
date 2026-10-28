// 跨端字节保存：Web 浏览器 blob 下载；移动/桌面写入下载/文档目录。
// 条件导入：dart:io 可用（移动/桌面）走 io 实现，否则（Web）走 dart:html 实现——
// 这样 dart:html 不会在移动端被编译（条件导入的语义保证）。
import 'dart:typed_data';

import 'file_saver_web.dart' if (dart.library.io) 'file_saver_io.dart' as impl;

/// 保存 [bytes] 为 [filename]：Web 触发浏览器下载；IO 写入下载目录(桌面)/文档目录(移动)。
/// 返回：Web = filename；IO = 完整保存路径（供 toast 提示用户去哪找）。
Future<String> saveBytes(
  Uint8List bytes,
  String filename, {
  bool Function()? stillCurrent,
  String? directory,
}) => impl.saveBytes(
  bytes,
  sanitizeDownloadFilename(filename),
  stillCurrent: stillCurrent,
  directory: directory,
);

Future<bool> canSaveStream() => impl.canSaveStream();

/// 桌面端导出默认目录（2026-10-28 起默认=桌面，OneDrive 重定向优先）；Web 返回 null。
Future<String?> defaultExportDirectory() => impl.defaultExportDirectory();

/// Writes one chunk at a time. Failed, cancelled or stale reads never publish a
/// partially downloaded file. [verifyScope] also runs before final publication.
Future<String> saveStream(
  Stream<Uint8List> chunks,
  String filename, {
  bool Function()? stillCurrent,
  Future<void> Function()? verifyScope,
  int maxBytes = 384 * 1024 * 1024,
  String? directory,
}) => impl.saveStream(
  chunks,
  sanitizeDownloadFilename(filename),
  stillCurrent: stillCurrent,
  verifyScope: verifyScope,
  maxBytes: maxBytes,
  directory: directory,
);

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
