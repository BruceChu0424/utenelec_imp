import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'form_draft_storage_api.dart';

FormDraftStorage createFormDraftStorage() => BrowserFormDraftStorage();

/// IndexedDB can retain original attachments without the localStorage 5 MB cap.
/// Every edit starts a transaction; success is reported only after commit.
class BrowserFormDraftStorage
    implements
        FormDraftStorage,
        ClosableFormDraftStorage,
        FormDraftHistoryStorage {
  BrowserFormDraftStorage({
    this.databaseName = 'uten_form_drafts_v1',
    this.afterHistoryQueued,
  });
  final String databaseName;

  /// Fault-injection seam: throwing here must abort the whole IDB transaction.
  final void Function()? afterHistoryQueued;
  static const _stores = [
    'drafts',
    'history_index',
    'history_payload',
    'history_head',
  ];
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
    final request = web.window.indexedDB.open(databaseName, 2);
    request.onupgradeneeded = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      if (!database.objectStoreNames.contains('drafts')) {
        database.createObjectStore('drafts');
      }
      for (final name in _stores.skip(1)) {
        database.createObjectStore(name);
      }
      // Upgrade and import are one transaction: an abort retains the v1 DB.
      final transaction = request.transaction!;
      final scan = transaction.objectStore('drafts').openCursor();
      scan.onsuccess = ((web.Event event) {
        if (scan.result.isUndefinedOrNull) return;
        final cursor = scan.result as web.IDBCursorWithValue;
        final key = (cursor.key as JSString).toDart;
        final value = (cursor.value as JSString).toDart;
        _appendHistory(
          transaction,
          key,
          null,
          value,
          importing: true,
          committed: () => cursor.continue_(),
        );
      }).toJS;
    }).toJS;
    request.onsuccess = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      database.onversionchange = ((web.Event event) {
        database.close();
        _opening = null;
      }).toJS;
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

  @override
  Future<void> write(String key, String value) async {
    await _mutate(key, value: value);
  }

  @override
  Future<void> remove(String key) async {
    await _mutate(key, value: null);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) => _mutate(key, expectedValue: expectedValue, value: value, compare: true);

  Future<bool> _mutate(
    String key, {
    String? expectedValue,
    required String? value,
    bool compare = false,
  }) async {
    final database = await _open();
    final transaction = database.transaction(
      _stores.map((name) => name.toJS).toList().toJS,
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
        if (compare && existing != expectedValue) return;
        matched = true;
        if (value == null && isFormDraftTerminalMarker(existing)) return;
        _appendHistory(
          transaction,
          key,
          existing,
          value,
          committed: () {
            if (value == null) {
              // A real draft is retained as a terminal marker, including callers
              // that still use the lower-level remove API.
              final draft = decodeFormDraftHistoryPayload(existing);
              if (draft == null) {
                store.delete(key.toJS);
              } else {
                store.put(
                  jsonEncode({
                    'version': 1,
                    'id': draft.id,
                    'completed': true,
                    'historyAction': 'deleted',
                    'revision': 'deleted:${draft.revision}',
                  }).toJS,
                  key.toJS,
                );
              }
            } else {
              store.put(compactFormDraftTerminalMarker(value)!.toJS, key.toJS);
            }
          },
        );
      } catch (_) {
        transaction.abort();
        fail();
      }
    }).toJS;
    request.onerror = ((web.Event event) => fail()).toJS;
    return result.future;
  }

  String _indexKey(String prefix, int sequence) =>
      '$prefix:${sequence.toString().padLeft(15, '0')}';

  void _appendHistory(
    web.IDBTransaction transaction,
    String key,
    String? existing,
    String? value, {
    bool importing = false,
    required void Function() committed,
  }) {
    final prefix = formDraftHistoryPrefix(key);
    final change = formDraftHistoryChange(
      key,
      existing,
      value,
      importing: importing,
    );
    if (prefix == null || change == null) {
      committed();
      return;
    }
    final heads = transaction.objectStore('history_head');
    final request = heads.get(prefix.toJS);
    request.onsuccess = ((web.Event event) {
      try {
        final raw = request.result;
        final sequence =
            (raw.isUndefinedOrNull ? 0 : int.parse((raw as JSString).toDart)) +
            1;
        formDraftHistorySequence('$sequence');
        final indexKey = _indexKey(prefix, sequence).toJS;
        final remainingRange = web.IDBKeyRange.bound(
          indexKey,
          '$prefix:\uffff'.toJS,
        );
        var checks = 2;
        var collision = false;
        for (final name in ['history_index', 'history_payload']) {
          // Key-only seeks detect both a missing head and rollback into a hole,
          // without reading payloads or scanning the existing history.
          final check = transaction.objectStore(name).getKey(remainingRange);
          check.onsuccess = ((web.Event event) {
            try {
              collision = collision || !check.result.isUndefinedOrNull;
              if (--checks != 0) return;
              if (collision) {
                transaction.abort();
                return;
              }
              // add, never put: originals cannot be overwritten even if a
              // control value was corrupted or an unexpected duplicate exists.
              transaction
                  .objectStore('history_index')
                  .add(
                    jsonEncode(change.entry(sequence).toJson()).toJS,
                    indexKey,
                  );
              transaction
                  .objectStore('history_payload')
                  .add(change.payload.toJS, indexKey);
              heads.put('$sequence'.toJS, prefix.toJS);
              afterHistoryQueued?.call();
              committed();
            } catch (_) {
              transaction.abort();
            }
          }).toJS;
        }
      } catch (_) {
        transaction.abort();
      }
    }).toJS;
  }

  @override
  Future<FormDraftHistoryPage> readHistoryPage(
    String prefix, {
    String? before,
    int limit = 30,
  }) async {
    validateFormDraftHistoryPrefix(prefix);
    formDraftHistoryLimit(limit);
    final boundary = before == null ? null : formDraftHistorySequence(before);
    final database = await _open();
    final result = Completer<FormDraftHistoryPage>();
    final range = web.IDBKeyRange.bound(
      '$prefix:'.toJS,
      (boundary == null ? '$prefix:\uffff' : _indexKey(prefix, boundary)).toJS,
      false,
      boundary != null,
    );
    final request = database
        .transaction('history_index'.toJS, 'readonly')
        .objectStore('history_index')
        .openCursor(range, 'prev');
    final entries = <FormDraftHistoryEntry>[];
    var scanned = 0;
    request.onsuccess = ((web.Event event) {
      if (request.result.isUndefinedOrNull) {
        result.complete(FormDraftHistoryPage(entries: entries));
        return;
      }
      final cursor = request.result as web.IDBCursorWithValue;
      final sequence = int.parse(
        (cursor.key as JSString).toDart.substring(prefix.length + 1),
      );
      try {
        final entry = FormDraftHistoryEntry.fromJson(
          jsonDecode((cursor.value as JSString).toDart) as Map<String, dynamic>,
        );
        if (entry.id == '$sequence') entries.add(entry);
      } on FormatException {
        // A damaged metadata record still consumes its bounded scan slot.
      } on TypeError {
        // Preserve unsupported records for recovery.
      } on ArgumentError {
        // Future metadata cannot hide other records.
      }
      if (++scanned >= limit) {
        result.complete(
          FormDraftHistoryPage(
            entries: entries,
            nextCursor: sequence > 1 ? '$sequence' : null,
          ),
        );
      } else {
        cursor.continue_();
      }
    }).toJS;
    request.onerror = ((web.Event event) => result.completeError(
      StateError('草稿历史读取失败'),
    )).toJS;
    return result.future;
  }

  @override
  Future<FormDraftHistoryRecord?> readHistoryRecord(
    String prefix,
    String id,
  ) async {
    validateFormDraftHistoryPrefix(prefix);
    final sequence = formDraftHistorySequence(id);
    final database = await _open();
    final transaction = database.transaction(
      ['history_index'.toJS, 'history_payload'.toJS].toJS,
      'readonly',
    );
    final key = _indexKey(prefix, sequence).toJS;
    String? decode(JSAny? value) =>
        value.isUndefinedOrNull ? null : (value as JSString).toDart;
    final metadata = _request(
      transaction.objectStore('history_index').get(key),
      decode,
    );
    final payload = _request(
      transaction.objectStore('history_payload').get(key),
      decode,
    );
    final values = await Future.wait([metadata, payload]);
    try {
      if (values[0] == null) return null;
      final entry = FormDraftHistoryEntry.fromJson(
        jsonDecode(values[0]!) as Map<String, dynamic>,
      );
      final draft = decodeFormDraftHistoryPayload(values[1]);
      if (entry.id != id ||
          draft == null ||
          draft.id != entry.draftId ||
          draft.revision != entry.revision ||
          draft.module != entry.module ||
          draft.route != entry.route ||
          draft.permission != entry.permission ||
          draft.draftKind != entry.draftKind) {
        return null;
      }
      return FormDraftHistoryRecord(entry: entry, draft: draft);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}
