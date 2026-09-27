import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'form_draft_storage_api.dart';

FormDraftStorage createFormDraftStorage() => _BrowserDraftStorage();

/// IndexedDB can retain original attachments without the localStorage 5 MB cap.
/// Every edit starts a transaction; success is reported only after commit.
class _BrowserDraftStorage
    implements FormDraftStorage, ClosableFormDraftStorage {
  Future<web.IDBDatabase>? _opening;

  @override
  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) (await opening).close();
  }

  Future<web.IDBDatabase> _open() => _opening ??= _openDatabase();

  Future<web.IDBDatabase> _openDatabase() {
    final result = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open('uten_form_drafts_v1', 1);
    request.onupgradeneeded = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      database.createObjectStore('drafts');
    }).toJS;
    request.onsuccess = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      if (result.isCompleted) {
        database.close();
      } else {
        result.complete(database);
      }
    }).toJS;
    request.onerror = ((web.Event event) {
      _opening = null;
      if (!result.isCompleted) {
        result.completeError(StateError('无法打开本机草稿存储'));
      }
    }).toJS;
    request.onblocked = ((web.Event event) {
      _opening = null;
      if (!result.isCompleted) {
        result.completeError(StateError('草稿存储被其他网页占用，请关闭旧页面后重试'));
      }
    }).toJS;
    return result.future;
  }

  Future<T> _request<T>(web.IDBRequest request, T Function(JSAny?) decode) {
    final result = Completer<T>();
    request.onsuccess = ((web.Event event) {
      try {
        result.complete(decode(request.result));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }).toJS;
    request.onerror = ((web.Event event) {
      result.completeError(StateError('本机草稿读取失败'));
    }).toJS;
    return result.future;
  }

  @override
  Future<Map<String, String>> readAll(String prefix) async {
    final database = await _open();
    final objectStore = database
        .transaction('drafts'.toJS, 'readonly')
        .objectStore('drafts');
    final range = web.IDBKeyRange.bound(prefix.toJS, '$prefix\uffff'.toJS);
    final keys = _request(
      objectStore.getAllKeys(range),
      (raw) => (raw as JSArray<JSString>).toDart,
    );
    final values = _request(
      objectStore.getAll(range),
      (raw) => (raw as JSArray<JSString>).toDart,
    );
    final allKeys = await keys;
    final allValues = await values;
    return {
      for (var index = 0; index < allKeys.length; index++)
        allKeys[index].toDart: allValues[index].toDart,
    };
  }

  @override
  Future<String?> read(String key) async {
    final database = await _open();
    return _request(
      database
          .transaction('drafts'.toJS, 'readonly')
          .objectStore('drafts')
          .get(key.toJS),
      (raw) => raw.isUndefinedOrNull ? null : (raw as JSString).toDart,
    );
  }

  Future<void> _mutate(void Function(web.IDBObjectStore) change) async {
    final database = await _open();
    final transaction = database.transaction(
      'drafts'.toJS,
      'readwrite',
      web.IDBTransactionOptions(durability: 'strict'),
    );
    final done = Completer<void>();
    transaction.oncomplete = ((web.Event event) => done.complete()).toJS;
    transaction.onabort = ((web.Event event) {
      if (!done.isCompleted) {
        done.completeError(StateError('本机草稿保存失败，存储空间可能不足'));
      }
    }).toJS;
    transaction.onerror = ((web.Event event) {
      if (!done.isCompleted) done.completeError(StateError('本机草稿保存失败'));
    }).toJS;
    change(transaction.objectStore('drafts'));
    await done.future;
  }

  @override
  Future<void> write(String key, String value) =>
      _mutate((store) => store.put(value.toJS, key.toJS));

  @override
  Future<void> remove(String key) => _mutate((store) => store.delete(key.toJS));

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    final database = await _open();
    final transaction = database.transaction(
      'drafts'.toJS,
      'readwrite',
      web.IDBTransactionOptions(durability: 'strict'),
    );
    final result = Completer<bool>();
    var matched = false;
    transaction.oncomplete = ((web.Event event) {
      if (!result.isCompleted) result.complete(matched);
    }).toJS;
    void fail() {
      if (!result.isCompleted) {
        result.completeError(StateError('本机草稿保存失败，存储空间可能不足'));
      }
    }

    transaction.onabort = ((web.Event event) => fail()).toJS;
    transaction.onerror = ((web.Event event) => fail()).toJS;
    final store = transaction.objectStore('drafts');
    final request = store.get(key.toJS);
    // Compare and write inside this active transaction, never two awaited
    // transactions: the latter would allow another browser tab to overwrite.
    request.onsuccess = ((web.Event event) {
      try {
        final raw = request.result;
        final existing = raw.isUndefinedOrNull
            ? null
            : (raw as JSString).toDart;
        if (existing != expectedValue) return;
        matched = true;
        if (value == null) {
          store.delete(key.toJS);
        } else {
          store.put(value.toJS, key.toJS);
        }
      } catch (_) {
        transaction.abort();
        fail();
      }
    }).toJS;
    request.onerror = ((web.Event event) => fail()).toJS;
    return result.future;
  }
}
