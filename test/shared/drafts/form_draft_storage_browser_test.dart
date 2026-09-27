@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';

void main() {
  late FormDraftStorage first;
  late FormDraftStorage second;
  late String prefix;

  setUp(() {
    first = createFormDraftStorage();
    second = createFormDraftStorage();
    prefix = 'browser-test-${DateTime.now().microsecondsSinceEpoch}_';
  });

  tearDown(() async {
    final records = await first.readAll(prefix);
    for (final key in records.keys) {
      await first.remove(key);
    }
    await (first as ClosableFormDraftStorage).close();
    await (second as ClosableFormDraftStorage).close();
  });

  test(
    'IndexedDB persists across store instances and scans the entire prefix',
    () async {
      final key = '${prefix}zzzz';
      final sibling = '${prefix}other';
      final foreign = '${prefix}foreign_prefix';
      await first.write(key, '{"remark":"填写一半"}');
      await first.write(sibling, 'another document');
      await first.write(foreign, 'different prefix');
      await (first as ClosableFormDraftStorage).close();
      expect(await second.read(key), '{"remark":"填写一半"}');
      expect(await second.readAll(prefix), {
        key: '{"remark":"填写一半"}',
        sibling: 'another document',
        foreign: 'different prefix',
      });
      expect(await second.readAll('${prefix}other'), {
        sibling: 'another document',
      });
      // A literal backslash-u upper bound would omit zzzz from readAll.
      expect((await second.readAll(prefix)).containsKey(key), isTrue);
    },
  );

  test(
    'IndexedDB compareAndSet has one winner across competing transactions',
    () async {
      final key = '${prefix}race';
      await first.write(key, 'revision-1');
      final results = await Future.wait([
        first.compareAndSet(key, expectedValue: 'revision-1', value: 'tab-a'),
        second.compareAndSet(key, expectedValue: 'revision-1', value: 'tab-b'),
      ]);
      expect(results.where((matched) => matched), hasLength(1));
      expect(await createFormDraftStorage().read(key), anyOf('tab-a', 'tab-b'));
      expect(
        await first.compareAndSet(
          key,
          expectedValue: 'revision-1',
          value: null,
        ),
        isFalse,
      );
    },
  );

  test(
    'IndexedDB completion marker rejects resurrection and removal is durable',
    () async {
      final key = '${prefix}completed';
      const original = '{"revision":"r1","data":{"qty":"1."}}';
      final completed = jsonEncode({'completed': true, 'revision': 'r2'});
      expect(
        await first.compareAndSet(key, expectedValue: null, value: original),
        isTrue,
      );
      expect(
        await second.compareAndSet(
          key,
          expectedValue: original,
          value: completed,
        ),
        isTrue,
      );
      expect(
        await first.compareAndSet(
          key,
          expectedValue: original,
          value: 'late autosave',
        ),
        isFalse,
      );
      expect(
        await first.compareAndSet(
          key,
          expectedValue: null,
          value: 'late creation',
        ),
        isFalse,
      );
      expect(await createFormDraftStorage().read(key), completed);
      await second.remove(key);
      expect(await createFormDraftStorage().read(key), isNull);
    },
  );

  test(
    'IndexedDB retains attachment-sized payload beyond localStorage capacity',
    () async {
      final key = '${prefix}attachment';
      final payload = '原始附件-${List.filled(8 * 1024 * 1024, 'x').join()}-完整';
      await first.write(key, payload);
      await (first as ClosableFormDraftStorage).close();
      final restored = await second.read(key);
      expect(restored?.length, payload.length);
      expect(restored, payload);
      expect((await second.readAll(prefix))[key]?.length, payload.length);
    },
  );
}
