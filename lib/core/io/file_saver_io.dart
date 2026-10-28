// 移动/桌面实现：桌面端默认写入「桌面」目录（2026-10-28 用户口径，OneDrive
// 重定向优先），可显式传 directory 指定目录；移动端写入文档目录。返回完整路径。
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

Future<bool> canSaveStream() async => true;

Future<void> _publishTail = Future<void>.value();

/// 导出默认目录：桌面端=桌面（OneDrive 桌面重定向优先，找不到回退本地桌面，
/// 再回退系统下载目录）；移动端=文档目录。
Future<String?> defaultExportDirectory() async {
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null) {
      final bases = [
        if (Platform.isWindows) ...[
          Platform.environment['OneDrive'],
          home,
        ] else
          home,
      ];
      for (final base in bases) {
        if (base == null || base.isEmpty) continue;
        final desktop = Directory('$base${Platform.pathSeparator}Desktop');
        if (await desktop.exists()) return desktop.path;
      }
    }
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads.path;
    final documents = await getApplicationDocumentsDirectory();
    return documents.path;
  }
  return await getApplicationDocumentsDirectory().then((dir) => dir.path);
}

Future<String> saveStream(
  Stream<Uint8List> chunks,
  String filename, {
  bool Function()? stillCurrent,
  Future<void> Function()? verifyScope,
  int maxBytes = 384 * 1024 * 1024,
  Future<Directory> Function()? destination,
  String? directory,
}) async {
  void check() {
    if (!(stillCurrent?.call() ?? true)) throw StateError('导出身份或服务器已变化，已取消保存');
  }

  check();
  final Directory dir;
  if (directory != null && directory.trim().isNotEmpty) {
    // 用户在导出弹窗里明确选择的目录；不存在时直接报错，不静默换地方。
    final chosen = Directory(directory.trim());
    if (!await chosen.exists()) {
      throw StateError('所选保存目录不存在，请重新选择');
    }
    dir = chosen;
  } else if (destination != null) {
    dir = await destination();
  } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    dir = Directory(
      (await defaultExportDirectory()) ??
          (await getApplicationDocumentsDirectory()).path,
    );
  } else {
    dir = await getApplicationDocumentsDirectory();
  }
  check();
  final partial = File(
    '${dir.path}${Platform.pathSeparator}.uten-export-${const Uuid().v4()}.partial',
  );
  await partial.create(exclusive: true);
  RandomAccessFile? output;
  var published = false;
  try {
    output = await partial.open(mode: FileMode.writeOnly);
    var size = 0;
    var verified = DateTime.now();
    await for (final chunk in chunks) {
      check();
      size += chunk.length;
      if (size > maxBytes) throw StateError('导出文件超过本机保存上限');
      if (DateTime.now().difference(verified) >= const Duration(seconds: 2)) {
        await verifyScope?.call();
        verified = DateTime.now();
        check();
      }
      await output.writeFrom(chunk);
    }
    await output.flush();
    await output.close();
    output = null;
    await verifyScope?.call();
    check();
    String? saved;
    Object? failure;
    StackTrace? failureStack;
    final publish = _publishTail.then((_) async {
      try {
        await verifyScope?.call();
        check();
        final file = await _availableFile(dir, filename);
        check();
        await partial.rename(file.path);
        published = true;
        saved = file.path;
      } catch (error, stack) {
        failure = error;
        failureStack = stack;
      }
    });
    _publishTail = publish;
    await publish;
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    return saved!;
  } finally {
    await output?.close();
    if (!published && await partial.exists()) await partial.delete();
  }
}

Future<String> saveBytes(
  Uint8List bytes,
  String filename, {
  bool Function()? stillCurrent,
  String? directory,
}) => saveStream(
  Stream.value(bytes),
  filename,
  stillCurrent: stillCurrent,
  directory: directory,
  maxBytes: bytes.length,
);

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
