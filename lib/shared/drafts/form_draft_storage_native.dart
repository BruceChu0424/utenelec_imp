import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'form_draft_storage_api.dart';

FormDraftStorage createFormDraftStorage() => NativeFormDraftStorage();

class NativeFormDraftStorage implements FormDraftStorage {
  NativeFormDraftStorage({this.directoryProvider});

  final Future<Directory> Function()? directoryProvider;

  // OS locks protect processes; this queue also protects instances in the same
  // isolate, where POSIX file locks alone do not establish ownership separation.
  static final Map<String, Future<void>> _recordTails = {};

  Future<Directory> _directory() async {
    final provider = directoryProvider;
    if (provider != null) return (await provider()).create(recursive: true);
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/form_drafts_v1').create(recursive: true);
  }

  Future<File> _file(String key) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(key)) {
      throw const FormatException('草稿存储标识无效');
    }
    return File('${(await _directory()).path}/$key.json');
  }

  Future<T> _locked<T>(String key, Future<T> Function(File) action) async {
    final target = await _file(key);
    final lockPath = '${target.path}.lock';
    final previous = _recordTails[lockPath] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = release.future;
    _recordTails[lockPath] = tail;
    await previous;
    try {
      // Keep a stable lock file. Removing it could let another process acquire
      // a new inode while an earlier process still owns the original lock.
      final handle = await File(lockPath).open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.blockingExclusive);
        try {
          return await action(target);
        } finally {
          await handle.unlock();
        }
      } finally {
        await handle.close();
      }
    } finally {
      release.complete();
      if (identical(_recordTails[lockPath], tail)) {
        _recordTails.remove(lockPath);
      }
    }
  }

  @override
  Future<Map<String, String>> readAll(String prefix) async {
    final result = <String, String>{};
    await for (final entity in (await _directory()).list()) {
      final name = entity.uri.pathSegments.last;
      if (entity is File && name.startsWith(prefix) && name.endsWith('.json')) {
        final key = name.substring(0, name.length - 5);
        final value = await read(key);
        if (value != null) result[key] = value;
      }
    }
    return result;
  }

  @override
  Future<String?> read(String key) => _locked(
    key,
    (file) async => await file.exists() ? file.readAsString() : null,
  );

  @override
  Future<void> write(String key, String value) =>
      _locked(key, (file) => _replace(file, value));

  Future<void> _replace(File target, String value) async {
    final temporary = File('${target.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> remove(String key) => _locked(key, (file) async {
    if (await file.exists()) await file.delete();
  });

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) => _locked(key, (file) async {
    final existing = await file.exists() ? await file.readAsString() : null;
    if (existing != expectedValue) return false;
    if (value == null) {
      if (await file.exists()) await file.delete();
    } else {
      await _replace(file, value);
    }
    return true;
  });
}
