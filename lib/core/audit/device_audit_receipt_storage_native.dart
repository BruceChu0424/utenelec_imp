import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'device_audit_receipt_storage_api.dart';

DeviceAuditReceiptStorage createDeviceAuditReceiptStorage() =>
    NativeDeviceAuditReceiptStorage();

class NativeDeviceAuditReceiptStorage implements DeviceAuditReceiptStorage {
  NativeDeviceAuditReceiptStorage({this.directoryProvider});

  final Future<Directory> Function()? directoryProvider;
  static final Map<String, Future<void>> _tails = {};

  @override
  Future<T> initialize<T>(Future<T> Function() action) =>
      _locked('initialization', (_) => action());

  Future<File> _file(String key) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,160}$').hasMatch(key)) {
      throw const FormatException('本机回执存储标识无效');
    }
    final supplied = directoryProvider;
    final root = supplied == null
        ? Directory(
            '${(await getApplicationSupportDirectory()).path}/device_audit_v4',
          )
        : await supplied();
    final bucket = sha256.convert(utf8.encode(key)).toString().substring(0, 2);
    final directory = await Directory(
      '${root.path}/$bucket',
    ).create(recursive: true);
    return File('${directory.path}/$key.json');
  }

  Future<T> _locked<T>(String key, Future<T> Function(File) action) async {
    final file = await _file(key);
    final lock = '${file.path}.lock';
    final before = _tails[lock] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[lock] = done.future;
    await before;
    try {
      final handle = await File(lock).open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.blockingExclusive);
        try {
          return await action(file);
        } finally {
          await handle.unlock();
        }
      } finally {
        await handle.close();
      }
    } finally {
      done.complete();
      if (identical(_tails[lock], done.future)) _tails.remove(lock);
    }
  }

  Future<void> _replace(File file, String value) async {
    final temporary = File('${file.path}.${const Uuid().v4()}.part');
    try {
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(file.path);
    } finally {
      // This file never represented a committed record.
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<String?> read(String key) => _locked(
    key,
    (file) async => await file.exists() ? file.readAsString() : null,
  );

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String value,
  }) => _locked(key, (file) async {
    final existing = await file.exists() ? await file.readAsString() : null;
    if (existing != expectedValue) return false;
    if (existing == value) return true;
    if (existing != null) {
      final digest = sha256.convert(utf8.encode(existing));
      final history = await Directory(
        '${file.parent.path}/history',
      ).create(recursive: true);
      final original = File('${history.path}/$key-$digest.json');
      if (await original.exists()) {
        if (await original.readAsString() != existing) {
          throw StateError('本机回执历史核对未通过，原记录未覆盖');
        }
      } else {
        await _replace(original, existing);
      }
    }
    await _replace(file, value);
    return true;
  });
}
