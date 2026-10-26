import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../core/performance/responsive_data_codec.dart';
import '../../core/performance/ui_work_budget.dart';
import 'form_draft_storage_api.dart';

class _MigrationPreparationChanged implements Exception {
  const _MigrationPreparationChanged();
}

FormDraftStorage createFormDraftStorage() => BrowserFormDraftStorage();

/// IndexedDB can retain original attachments without the localStorage 5 MB cap.
/// Every edit starts a transaction; success is reported only after commit.
class BrowserFormDraftStorage
    implements
        FormDraftStorage,
        ClosableFormDraftStorage,
        FormDraftHistoryStorage,
        BusinessResetFormDraftStorage {
  BrowserFormDraftStorage({
    this.databaseName = 'uten_form_drafts_v1',
    this.afterHistoryQueued,
    this.beforeMigrationUpgrade,
  });
  final String databaseName;

  /// Fault-injection seam: throwing here must abort the whole IDB transaction.
  final void Function()? afterHistoryQueued;

  /// Tests may mutate a legacy connection after preparation, before upgrade.
  /// The upgrade must abort rather than import a stale original.
  final Future<void> Function()? beforeMigrationUpgrade;
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

  Future<web.IDBDatabase> _openDatabase() async {
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        final probe = await _openForPreparation();
        if (probe.version == 2) return _observeDatabase(probe);
        if (probe.version > 2) {
          probe.close();
          throw StateError('草稿存储版本较新，请更新客户端；原记录已保留');
        }
        final Map<String, String> originals;
        try {
          originals = await _readRawDrafts(probe);
        } finally {
          probe.close();
        }
        final empty = await prepareFormDraftHistoryValue(null);
        final prepared = <String, FormDraftHistoryChange?>{};
        for (final entry in originals.entries) {
          prepared[entry.key] = preparedFormDraftHistoryChange(
            entry.key,
            empty,
            await prepareFormDraftHistoryValue(entry.value),
            importing: true,
          );
        }
        await beforeMigrationUpgrade?.call();
        try {
          return await _upgradePreparedDatabase(originals, prepared);
        } on _MigrationPreparationChanged {
          // Another v1 writer changed the raw source while decoding. All v2
          // stores/history writes rolled back with the aborted upgrade.
        }
      }
      throw StateError('旧草稿仍被其他页面修改，请关闭旧页面后重试；原记录已保留');
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  web.IDBDatabase _observeDatabase(web.IDBDatabase database) {
    database.onversionchange = ((web.Event _) {
      database.close();
      _opening = null;
    }).toJS;
    return database;
  }

  Future<web.IDBDatabase> _openForPreparation() {
    final result = Completer<web.IDBDatabase>();
    // No requested version: read v1 originals before opening the v2 upgrade.
    final request = web.window.indexedDB.open(databaseName);
    request.onupgradeneeded = ((web.Event _) {
      (request.result as web.IDBDatabase).createObjectStore('drafts');
    }).toJS;
    request.onsuccess = ((web.Event _) {
      final database = request.result as web.IDBDatabase;
      database.onversionchange = ((web.Event _) => database.close()).toJS;
      if (result.isCompleted) {
        database.close();
      } else {
        result.complete(database);
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!result.isCompleted) result.completeError(StateError('无法打开本机草稿存储'));
    }).toJS;
    request.onblocked = ((web.Event _) {
      if (!result.isCompleted) {
        result.completeError(StateError('草稿存储被其他网页占用，请关闭旧页面后重试'));
      }
    }).toJS;
    return result.future;
  }

  Future<Map<String, String>> _readRawDrafts(web.IDBDatabase database) async {
    final store = database
        .transaction('drafts'.toJS, 'readonly')
        .objectStore('drafts');
    // Queue both requests in this transaction before awaiting either.
    final keys = _request(
      store.getAllKeys(),
      (raw) => (raw as JSArray<JSString>).toDart,
    );
    final values = _request(
      store.getAll(),
      (raw) => (raw as JSArray<JSString>).toDart,
    );
    final allKeys = await keys;
    final allValues = await values;
    final records = <String, String>{};
    final work = UiWorkBudget();
    for (var i = 0; i < allKeys.length; i++) {
      records[allKeys[i].toDart] = allValues[i].toDart;
      await work.checkpoint();
    }
    return records;
  }

  Future<web.IDBDatabase> _upgradePreparedDatabase(
    Map<String, String> originals,
    Map<String, FormDraftHistoryChange?> prepared,
  ) {
    final result = Completer<web.IDBDatabase>();
    Object? preparationFailure;
    final request = web.window.indexedDB.open(databaseName, 2);
    request.onupgradeneeded = ((web.Event event) {
      if (result.isCompleted) {
        request.transaction?.abort();
        return;
      }
      final database = request.result as web.IDBDatabase;
      if (!database.objectStoreNames.contains('drafts')) {
        database.createObjectStore('drafts');
      }
      for (final name in _stores.skip(1)) {
        database.createObjectStore(name);
      }
      // Upgrade and import are one transaction: an abort retains the v1 DB.
      final transaction = request.transaction!;
      var seen = 0;
      final scan = transaction.objectStore('drafts').openCursor();
      scan.onsuccess = ((web.Event event) {
        if (scan.result.isUndefinedOrNull) {
          if (seen != originals.length) {
            preparationFailure = const _MigrationPreparationChanged();
            transaction.abort();
          }
          return;
        }
        final cursor = scan.result as web.IDBCursorWithValue;
        final key = (cursor.key as JSString).toDart;
        final value = (cursor.value as JSString).toDart;
        if (!originals.containsKey(key) || originals[key] != value) {
          preparationFailure = const _MigrationPreparationChanged();
          transaction.abort();
          return;
        }
        seen++;
        _appendPreparedHistory(
          transaction,
          key,
          prepared[key],
          committed: () => cursor.continue_(),
        );
      }).toJS;
    }).toJS;
    request.onsuccess = ((web.Event event) {
      final database = request.result as web.IDBDatabase;
      if (result.isCompleted) {
        database.close();
      } else {
        result.complete(_observeDatabase(database));
      }
    }).toJS;
    request.onerror = ((web.Event event) {
      _opening = null;
      if (!result.isCompleted) {
        result.completeError(preparationFailure ?? StateError('无法打开本机草稿存储'));
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
  Future<void> synchronizeBusinessReset(
    String ownerPrefix,
    int generation,
  ) async {
    validateFormDraftReset(ownerPrefix, generation);
    final database = await _open();
    final transaction = database.transaction(
      _stores.map((name) => name.toJS).toList().toJS,
      'readwrite',
      web.IDBTransactionOptions(durability: 'strict'),
    );
    final done = Completer<void>();
    Object failure = StateError('本机草稿清空失败，请重新登录后重试');
    transaction.oncomplete = ((web.Event _) => done.complete()).toJS;
    transaction.onabort = ((web.Event _) {
      if (!done.isCompleted) done.completeError(failure);
    }).toJS;
    transaction.onerror = ((web.Event _) {
      if (!done.isCompleted) done.completeError(failure);
    }).toJS;
    final heads = transaction.objectStore('history_head');
    final marker = '${ownerPrefix}__business_reset_generation'.toJS;
    final request = heads.get(marker);
    request.onsuccess = ((web.Event _) {
      try {
        final latest = request.result.isUndefinedOrNull
            ? 0
            : int.parse((request.result as JSString).toDart);
        if (generation < latest) {
          throw FormDraftGenerationMismatch(generation, latest);
        }
        heads.put('$generation'.toJS, marker);
        if (generation == 0) return;
        for (final name in _stores) {
          for (final feature in ['', 'daily_report_approval_']) {
            final start = '$feature$ownerPrefix';
            final scan = transaction
                .objectStore(name)
                .openCursor(
                  web.IDBKeyRange.bound(start.toJS, '$start\uffff'.toJS),
                );
            scan.onsuccess = ((web.Event _) {
              if (scan.result.isUndefinedOrNull) return;
              final cursor = scan.result as web.IDBCursorWithValue;
              final key = (cursor.key as JSString).toDart;
              final prefix = name == 'drafts'
                  ? formDraftHistoryPrefix(key)
                  : key.split(':').first;
              final scope = prefix == null ? null : formDraftResetScope(prefix);
              if (scope?.owner == ownerPrefix &&
                  scope!.generation < generation) {
                cursor.delete();
              }
              cursor.continue_();
            }).toJS;
          }
        }
      } catch (error) {
        failure = error;
        transaction.abort();
      }
    }).toJS;
    await done.future;
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
    final records = <String, String>{};
    final work = UiWorkBudget();
    for (var index = 0; index < allKeys.length; index++) {
      records[allKeys[index].toDart] = allValues[index].toDart;
      await work.checkpoint();
    }
    return records;
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
    final next = await prepareFormDraftHistoryValue(value);
    final expected = compare
        ? await prepareFormDraftHistoryValue(expectedValue)
        : null;
    for (var attempt = 0; attempt < 8; attempt++) {
      final previous =
          expected ??
          await prepareFormDraftHistoryValue(
            await _request(
              database
                  .transaction('drafts'.toJS, 'readonly')
                  .objectStore('drafts')
                  .get(key.toJS),
              (raw) => raw.isUndefinedOrNull ? null : (raw as JSString).toDart,
            ),
          );
      final change = preparedFormDraftHistoryChange(key, previous, next);
      final String? storedValue;
      if (value != null) {
        storedValue = next.compact;
      } else if (previous.draft case final draft?) {
        storedValue = await encodeJsonResponsive({
          'version': 1,
          'id': draft.id,
          'completed': true,
          'historyAction': 'deleted',
          'revision': 'deleted:${draft.revision}',
        });
      } else {
        storedValue = null;
      }
      final committed = await _mutatePrepared(
        database,
        key,
        previous,
        change,
        value: value,
        storedValue: storedValue,
        compare: compare,
      );
      if (committed != null) return committed;
      // A non-CAS legacy writer must prepare the newest original before retry.
      // No payload/history write occurred in the previous transaction.
    }
    throw StateError('草稿仍被其他页面修改，请稍后重试；原记录已保留');
  }

  Future<bool?> _mutatePrepared(
    web.IDBDatabase database,
    String key,
    PreparedFormDraftHistoryValue previous,
    FormDraftHistoryChange? change, {
    required String? value,
    required String? storedValue,
    required bool compare,
  }) {
    final transaction = database.transaction(
      _stores.map((name) => name.toJS).toList().toJS,
      'readwrite',
      web.IDBTransactionOptions(durability: 'strict'),
    );
    final result = Completer<bool?>();
    var matched = false;
    var retry = false;
    transaction.oncomplete = ((web.Event event) {
      if (!result.isCompleted) result.complete(retry ? null : matched);
    }).toJS;
    void fail() {
      if (!result.isCompleted) {
        result.completeError(StateError('本机草稿保存失败，存储空间可能不足'));
      }
    }

    transaction.onabort = ((web.Event event) => fail()).toJS;
    transaction.onerror = ((web.Event event) => fail()).toJS;
    final store = transaction.objectStore('drafts');
    void mutate() {
      final request = store.get(key.toJS);
      // Compare and write inside this active transaction, never two awaited
      // transactions: the latter would allow another browser tab to overwrite.
      request.onsuccess = ((web.Event event) {
        try {
          final raw = request.result;
          final existing = raw.isUndefinedOrNull
              ? null
              : (raw as JSString).toDart;
          // This exact original-string check remains inside the active write
          // transaction. Preparation never replaces the atomic CAS condition.
          if (existing != previous.raw) {
            retry = !compare;
            return;
          }
          matched = true;
          if (value == null && previous.terminal) return;
          _appendPreparedHistory(
            transaction,
            key,
            change,
            committed: () {
              if (storedValue == null) {
                store.delete(key.toJS);
              } else {
                store.put(storedValue.toJS, key.toJS);
              }
            },
          );
        } catch (_) {
          transaction.abort();
          fail();
        }
      }).toJS;
      request.onerror = ((web.Event event) => fail()).toJS;
    }

    final prefix = formDraftHistoryPrefix(key);
    final reset = prefix == null ? null : formDraftResetScope(prefix);
    if (reset == null) {
      mutate();
    } else {
      final fence = transaction
          .objectStore('history_head')
          .get('${reset.owner}__business_reset_generation'.toJS);
      fence.onsuccess = ((web.Event _) {
        try {
          final latest = fence.result.isUndefinedOrNull
              ? 0
              : int.parse((fence.result as JSString).toDart);
          if (reset.generation < latest) {
            result.completeError(
              FormDraftGenerationMismatch(reset.generation, latest),
            );
            transaction.abort();
            return;
          }
          mutate();
        } catch (_) {
          transaction.abort();
          fail();
        }
      }).toJS;
    }
    return result.future;
  }

  String _indexKey(String prefix, int sequence) =>
      '$prefix:${sequence.toString().padLeft(15, '0')}';

  void _appendPreparedHistory(
    web.IDBTransaction transaction,
    String key,
    FormDraftHistoryChange? change, {
    required void Function() committed,
  }) {
    final prefix = formDraftHistoryPrefix(key);
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
    final result = Completer<void>();
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
    final rows = <(int, String)>[];
    String? nextCursor;
    var scanned = 0;
    request.onsuccess = ((web.Event event) {
      if (request.result.isUndefinedOrNull) {
        result.complete();
        return;
      }
      final cursor = request.result as web.IDBCursorWithValue;
      final sequence = int.parse(
        (cursor.key as JSString).toDart.substring(prefix.length + 1),
      );
      try {
        rows.add((sequence, (cursor.value as JSString).toDart));
      } on TypeError {
        // Unsupported metadata still consumes one seek slot.
      }
      if (++scanned >= limit) {
        nextCursor = sequence > 1 ? '$sequence' : null;
        result.complete();
      } else {
        cursor.continue_();
      }
    }).toJS;
    request.onerror = ((web.Event event) => result.completeError(
      StateError('草稿历史读取失败'),
    )).toJS;
    await result.future;
    final entries = <FormDraftHistoryEntry>[];
    for (final (sequence, raw) in rows) {
      try {
        final entry = FormDraftHistoryEntry.fromJson(
          await decodeJsonResponsive(raw) as Map<String, dynamic>,
        );
        if (entry.id == '$sequence') entries.add(entry);
      } on FormatException {
        // A damaged metadata record still consumes its bounded scan slot.
      } on TypeError {
        // Preserve unsupported records for recovery.
      } on ArgumentError {
        // Future metadata cannot hide other records.
      }
    }
    return FormDraftHistoryPage(entries: entries, nextCursor: nextCursor);
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
        await decodeJsonResponsive(values[0]!) as Map<String, dynamic>,
      );
      final draft = await decodeFormDraftHistoryPayloadResponsive(values[1]);
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
