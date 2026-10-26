// Web 实现：Blob + 隐藏 anchor 触发浏览器下载（无第三方依赖）。
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'dart:async';
import 'package:uuid/uuid.dart';

import 'package:web/web.dart' as web;

Future<bool> canSaveStream() async {
  try {
    if (!web.window.isSecureContext ||
        !web.window.navigator.storage.hasProperty('getDirectory'.toJS).toDart) {
      return false;
    }
    await web.window.navigator.storage.getDirectory().toDart;
    return true;
  } catch (_) {
    return false;
  }
}

@JS()
extension type _DirectoryEntries(JSObject _) implements JSObject {
  external _EntryIterator entries();
}
@JS()
extension type _EntryIterator(JSObject _) implements JSObject {
  external JSPromise<_EntryResult> next();
}
@JS()
extension type _EntryResult(JSObject _) implements JSObject {
  external bool get done;
  external JSArray<JSAny> get value;
}

/// Private origin files are reproducible transfer buffers, never business
/// history. Keep at most 2 GiB / 128 recent entries and reap expired copies.
Future<void> _prepareTransferSpace(
  web.FileSystemDirectoryHandle directory,
) async {
  final iterator = _DirectoryEntries(directory).entries();
  var count = 0;
  var bytes = 0;
  final cutoff = DateTime.now()
      .subtract(const Duration(hours: 1))
      .millisecondsSinceEpoch;
  while (true) {
    final next = await iterator.next().toDart;
    if (next.done) break;
    if (++count > 128) throw StateError('浏览器临时下载较多，请稍后重试或使用桌面版');
    final pair = next.value.toDart;
    final name = (pair[0] as JSString).toDart;
    if (!RegExp(r'^transfer-[a-f0-9-]{36}\.bin$').hasMatch(name)) continue;
    final handle = (pair[1] as web.FileSystemFileHandle);
    final file = await handle.getFile().toDart;
    if (file.lastModified < cutoff) {
      await directory.removeEntry(name).toDart;
    } else {
      bytes += file.size;
    }
  }
  if (bytes + 384 * 1024 * 1024 > 2 * 1024 * 1024 * 1024) {
    throw StateError('浏览器临时下载空间不足，请稍后重试或使用桌面版');
  }
  final estimate = await web.window.navigator.storage.estimate().toDart;
  if (estimate.quota - estimate.usage < 448 * 1024 * 1024) {
    throw StateError('浏览器可用空间不足，请使用桌面版保存');
  }
}

Future<String> saveStream(
  Stream<Uint8List> chunks,
  String filename, {
  bool Function()? stillCurrent,
  Future<void> Function()? verifyScope,
  int maxBytes = 384 * 1024 * 1024,
}) async {
  void check() {
    if (!(stillCurrent?.call() ?? true)) throw StateError('导出身份或服务器已变化，已取消下载');
  }

  check();
  if (!await canSaveStream()) throw StateError('当前浏览器不支持大文件保存，请使用桌面版');
  final root = await web.window.navigator.storage.getDirectory().toDart;
  final directory = await root
      .getDirectoryHandle(
        'uten-export-transfers-v1',
        web.FileSystemGetDirectoryOptions(create: true),
      )
      .toDart;
  await _prepareTransferSpace(directory);
  check();
  final name = 'transfer-${const Uuid().v4()}.bin';
  final handle = await directory
      .getFileHandle(name, web.FileSystemGetFileOptions(create: true))
      .toDart;
  web.FileSystemWritableFileStream? writer;
  var handedOff = false;
  try {
    writer = await handle.createWritable().toDart;
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
      await writer.write(chunk.toJS).toDart;
    }
    await writer.close().toDart;
    writer = null;
    await verifyScope?.call();
    check();
    final file = await handle.getFile().toDart;
    if (file.size != size) throw StateError('保存的导出文件不完整，请重试原任务');
    final url = web.URL.createObjectURL(file);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    handedOff = true;
    // The browser owns the disk-backed File during its download. Keep the
    // transfer copy alive long enough; a later session also reaps old entries.
    Timer(const Duration(minutes: 30), () {
      web.URL.revokeObjectURL(url);
      unawaited(
        directory.removeEntry(name).toDart.catchError((Object _) => null),
      );
    });
    return filename;
  } finally {
    if (writer != null) {
      try {
        await writer.abort().toDart;
      } catch (_) {}
    }
    if (!handedOff) {
      try {
        await directory.removeEntry(name).toDart;
      } catch (_) {}
    }
  }
}

Future<String> saveBytes(
  Uint8List bytes,
  String filename, {
  bool Function()? stillCurrent,
}) async {
  if (!(stillCurrent?.call() ?? true)) throw StateError('导出身份或服务器已变化，已取消下载');
  final blob = web.Blob(<JSAny>[bytes.toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return filename;
}
