@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:uten_imp/core/audit/device_audit_receipt_storage_web.dart';

void main() {
  late String name;
  late BrowserDeviceAuditReceiptStorage first;
  late BrowserDeviceAuditReceiptStorage second;
  setUp(() {
    name = 'uten_audit_isolated_test_${DateTime.now().microsecondsSinceEpoch}';
    first = BrowserDeviceAuditReceiptStorage(databaseName: name);
    second = BrowserDeviceAuditReceiptStorage(databaseName: name);
  });
  tearDown(() async {
    await first.close();
    await second.close();
    final done = Completer<void>();
    final request = web.window.indexedDB.deleteDatabase(name);
    request.onsuccess = ((web.Event _) => done.complete()).toJS;
    request.onerror = ((web.Event _) => done.completeError(
      StateError('test database cleanup failed'),
    )).toJS;
    await done.future;
  });

  test(
    'point replacement commits its exact original in the same IDB transaction',
    () async {
      expect(
        await first.compareAndSet(
          'operation',
          expectedValue: null,
          value: 'pending',
        ),
        isTrue,
      );
      expect(
        await first.compareAndSet(
          'operation',
          expectedValue: 'pending',
          value: 'success',
        ),
        isTrue,
      );
      expect(await second.read('operation'), 'success');
      expect(await _history(name, 'operation', 'pending'), 'pending');
      expect(
        await second.compareAndSet(
          'operation',
          expectedValue: 'pending',
          value: 'stale',
        ),
        isFalse,
      );
    },
  );

  test(
    'concurrent stores have exactly one winner for an observed value',
    () async {
      await first.compareAndSet(
        'operation',
        expectedValue: null,
        value: 'original',
      );
      final results = await Future.wait([
        first.compareAndSet('operation', expectedValue: 'original', value: 'a'),
        second.compareAndSet(
          'operation',
          expectedValue: 'original',
          value: 'b',
        ),
      ]);
      expect(results.where((value) => value), hasLength(1));
      expect(await first.read('operation'), results.first ? 'a' : 'b');
      expect(await _history(name, 'operation', 'original'), 'original');
    },
  );

  test(
    'a conflicting archived original aborts the new record update',
    () async {
      await first.compareAndSet(
        'operation',
        expectedValue: null,
        value: 'original',
      );
      await _history(
        name,
        'operation',
        'original',
        replaceWith: 'forensic mismatch',
      );
      await expectLater(
        first.compareAndSet(
          'operation',
          expectedValue: 'original',
          value: 'overwrite',
        ),
        throwsStateError,
      );
      expect(await first.read('operation'), 'original');
      expect(
        await _history(name, 'operation', 'original'),
        'forensic mismatch',
      );
    },
  );

  test(
    'returning to a previous value never erases either archived version',
    () async {
      await first.compareAndSet('operation', expectedValue: null, value: 'a');
      await first.compareAndSet('operation', expectedValue: 'a', value: 'b');
      await first.compareAndSet('operation', expectedValue: 'b', value: 'a');
      await first.compareAndSet('operation', expectedValue: 'a', value: 'c');
      expect(await second.read('operation'), 'c');
      expect(await _history(name, 'operation', 'a'), 'a');
      expect(await _history(name, 'operation', 'b'), 'b');
    },
  );

  test(
    'initialization is shared between independently opened stores',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var secondEntered = false;
      final a = first.initialize(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final b = second.initialize(() async {
        secondEntered = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(secondEntered, isFalse);
      release.complete();
      await a;
      await b;
      expect(secondEntered, isTrue);
    },
  );
}

Future<String?> _history(
  String name,
  String key,
  String old, {
  String? replaceWith,
}) async {
  final opened = Completer<web.IDBDatabase>();
  final open = web.window.indexedDB.open(name, 1);
  open.onsuccess = ((web.Event _) => opened.complete(
    open.result as web.IDBDatabase,
  )).toJS;
  open.onerror = ((web.Event _) => opened.completeError(
    StateError('test open failed'),
  )).toJS;
  final database = await opened.future;
  try {
    final transaction = database.transaction(
      'history'.toJS,
      replaceWith == null ? 'readonly' : 'readwrite',
    );
    final result = Completer<String?>();
    String? value;
    transaction.oncomplete = ((web.Event _) => result.complete(value)).toJS;
    transaction.onabort = ((web.Event _) => result.completeError(
      StateError('test transaction aborted'),
    )).toJS;
    final store = transaction.objectStore('history');
    final historyKey = '$key-${sha256.convert(utf8.encode(old))}';
    if (replaceWith != null) {
      store.put(replaceWith.toJS, historyKey.toJS);
    } else {
      final request = store.get(historyKey.toJS);
      request.onsuccess = ((web.Event _) {
        final raw = request.result;
        value = raw.isUndefinedOrNull ? null : (raw as JSString).toDart;
      }).toJS;
    }
    return await result.future;
  } finally {
    database.close();
  }
}
