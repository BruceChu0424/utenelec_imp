import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:crypto/crypto.dart';
import 'package:web/web.dart' as web;

import 'device_audit_receipt_storage_api.dart';
import '../security/auth_refresh_lock.dart';

DeviceAuditReceiptStorage createDeviceAuditReceiptStorage() =>
    BrowserDeviceAuditReceiptStorage();

class BrowserDeviceAuditReceiptStorage implements DeviceAuditReceiptStorage {
  BrowserDeviceAuditReceiptStorage({
    this.databaseName = 'uten_device_audit_v4',
  });
  final String databaseName;
  Future<web.IDBDatabase>? _opening;

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) (await opening).close();
  }

  @override
  Future<T> initialize<T>(Future<T> Function() action) => AuthRefreshLock(
    'audit-device-permanent-initialization',
  ).synchronized(action);

  Future<web.IDBDatabase> _open() => _opening ??= _openDatabase();

  Future<web.IDBDatabase> _openDatabase() {
    final result = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(databaseName, 1);
    request.onupgradeneeded = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      database.createObjectStore('receipts');
      database.createObjectStore('history');
    }).toJS;
    request.onsuccess = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      if (result.isCompleted) {
        database.close();
      } else {
        database.onversionchange = ((web.Event _) {
          database.close();
          _opening = null;
        }).toJS;
        result.complete(database);
      }
    }).toJS;
    void fail() {
      _opening = null;
      if (!result.isCompleted) result.completeError(StateError('无法打开本机回执存储'));
    }

    request.onerror = ((web.Event _) => fail()).toJS;
    request.onblocked = ((web.Event _) => fail()).toJS;
    return result.future;
  }

  @override
  Future<String?> read(String key) async {
    final database = await _open();
    final result = Completer<String?>();
    final request = database
        .transaction('receipts'.toJS, 'readonly')
        .objectStore('receipts')
        .get(key.toJS);
    request.onsuccess = ((web.Event _) {
      try {
        final raw = request.result;
        result.complete(
          raw.isUndefinedOrNull ? null : (raw as JSString).toDart,
        );
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }).toJS;
    request.onerror = ((web.Event _) => result.completeError(
      StateError('本机回执读取失败'),
    )).toJS;
    return result.future;
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String value,
  }) async {
    final database = await _open();
    final transaction = database.transaction(
      ['receipts'.toJS, 'history'.toJS].toJS,
      'readwrite',
      web.IDBTransactionOptions(durability: 'strict'),
    );
    final result = Completer<bool>();
    var matched = false;
    transaction.oncomplete = ((web.Event _) {
      if (!result.isCompleted) result.complete(matched);
    }).toJS;
    void fail() {
      if (!result.isCompleted) {
        result.completeError(StateError('本机回执保存失败，原记录仍保留'));
      }
    }

    transaction.onabort = ((web.Event _) => fail()).toJS;
    transaction.onerror = ((web.Event _) => fail()).toJS;
    final store = transaction.objectStore('receipts');
    final request = store.get(key.toJS);
    request.onsuccess = ((web.Event _) {
      try {
        final raw = request.result;
        final existing = raw.isUndefinedOrNull
            ? null
            : (raw as JSString).toDart;
        if (existing != expectedValue) return;
        matched = true;
        if (existing == value) return;
        if (existing != null) {
          final originalKey = '$key-${sha256.convert(utf8.encode(existing))}';
          final history = transaction.objectStore('history');
          final original = history.get(originalKey.toJS);
          original.onsuccess = ((web.Event _) {
            final stored = original.result;
            if (!stored.isUndefinedOrNull &&
                (stored as JSString).toDart != existing) {
              transaction.abort();
              fail();
              return;
            }
            if (stored.isUndefinedOrNull) {
              history.add(existing.toJS, originalKey.toJS);
            }
            store.put(value.toJS, key.toJS);
          }).toJS;
          original.onerror = ((web.Event _) => fail()).toJS;
        } else {
          store.put(value.toJS, key.toJS);
        }
      } catch (_) {
        transaction.abort();
        fail();
      }
    }).toJS;
    request.onerror = ((web.Event _) => fail()).toJS;
    return result.future;
  }
}
