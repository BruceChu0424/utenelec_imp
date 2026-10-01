import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/audit/device_audit_receipt_storage_native.dart';

void main() {
  late Directory directory;
  late NativeDeviceAuditReceiptStorage first;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('uten-audit-v4-test-');
    first = NativeDeviceAuditReceiptStorage(
      directoryProvider: () async => directory,
    );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'replaced committed bytes survive reopening as an immutable original',
    () async {
      expect(
        await first.compareAndSet(
          'receipt_test',
          expectedValue: null,
          value: 'pending original',
        ),
        isTrue,
      );
      expect(
        await first.compareAndSet(
          'receipt_test',
          expectedValue: 'pending original',
          value: 'confirmed receipt',
        ),
        isTrue,
      );
      final reopened = NativeDeviceAuditReceiptStorage(
        directoryProvider: () async => directory,
      );
      expect(await reopened.read('receipt_test'), 'confirmed receipt');
      final originals = await directory
          .list(recursive: true)
          .where((f) => f is File && f.path.contains('history'))
          .cast<File>()
          .toList();
      expect(originals, hasLength(1));
      expect(await originals.single.readAsString(), 'pending original');
      expect(
        await first.compareAndSet(
          'receipt_test',
          expectedValue: 'pending original',
          value: 'stale overwrite',
        ),
        isFalse,
      );
      expect(await reopened.read('receipt_test'), 'confirmed receipt');
    },
  );

  test('two instances cannot both replace the same observed version', () async {
    final second = NativeDeviceAuditReceiptStorage(
      directoryProvider: () async => directory,
    );
    await first.compareAndSet('shared', expectedValue: null, value: 'before');
    final results = await Future.wait([
      first.compareAndSet('shared', expectedValue: 'before', value: 'first'),
      second.compareAndSet('shared', expectedValue: 'before', value: 'second'),
    ]);
    expect(results.where((value) => value), hasLength(1));
    expect(await first.read('shared'), results.first ? 'first' : 'second');
  });

  test(
    'history mismatch refuses replacement and leaves both pieces of evidence intact',
    () async {
      await first.compareAndSet(
        'retained',
        expectedValue: null,
        value: 'original',
      );
      final bucket = sha256
          .convert(utf8.encode('retained'))
          .toString()
          .substring(0, 2);
      final digest = sha256.convert(utf8.encode('original'));
      final history = await Directory(
        '${directory.path}/$bucket/history',
      ).create(recursive: true);
      final file = File('${history.path}/retained-$digest.json');
      await file.writeAsString('unexpected forensic bytes', flush: true);
      await expectLater(
        first.compareAndSet(
          'retained',
          expectedValue: 'original',
          value: 'replacement',
        ),
        throwsStateError,
      );
      expect(await first.read('retained'), 'original');
      expect(await file.readAsString(), 'unexpected forensic bytes');
    },
  );

  test(
    'initialization serializes distinct store instances on the stable lock',
    () async {
      final second = NativeDeviceAuditReceiptStorage(
        directoryProvider: () async => directory,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var secondEntered = false;
      final a = first.initialize(() async {
        entered.complete();
        await release.future;
        return 1;
      });
      await entered.future;
      final b = second.initialize(() async {
        secondEntered = true;
        return 2;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(secondEntered, isFalse);
      release.complete();
      expect(await a, 1);
      expect(await b, 2);
    },
  );

  test('external paths cannot be used as receipt identities', () async {
    await expectLater(first.read('../external'), throwsFormatException);
    await expectLater(
      first.compareAndSet('C:/external', expectedValue: null, value: 'x'),
      throwsFormatException,
    );
    expect(await directory.list(recursive: true).toList(), isEmpty);
  });
}
