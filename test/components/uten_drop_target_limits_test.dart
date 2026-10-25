import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_drop_target.dart';

class _File extends DropItemFile {
  _File(this.declared, this.chunks) : super('/private/template.txt');
  final int declared;
  final List<List<int>> chunks;
  int streamReads = 0, unboundedReads = 0;
  @override
  Future<int> length() async => declared;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    streamReads++;
    for (final chunk in chunks) {
      yield Uint8List.fromList(chunk);
    }
  }

  @override
  Future<Uint8List> readAsBytes() async {
    unboundedReads++;
    throw StateError('Unbounded read forbidden');
  }
}

void main() {
  test(
    'oversized metadata is rejected before a file stream is opened',
    () async {
      final file = _File(101, [
        [1],
      ]);
      final rejected = <String>[];
      final (files, skipped) = await droppedItemsToPlatformFiles(
        [file],
        maxFileBytes: 100,
        onRejected: (_, reason) => rejected.add(reason),
      );
      expect(files, isEmpty);
      expect(skipped, 1);
      expect(rejected, ['FILE_TOO_LARGE']);
      expect(file.streamReads, 0);
      expect(file.unboundedReads, 0);
    },
  );

  test('actual stream limits protect against a growing file', () async {
    final file = _File(1, [
      [1, 2],
      [3, 4],
    ]);
    final (files, skipped) = await droppedItemsToPlatformFiles([
      file,
    ], maxFileBytes: 3);
    expect(files, isEmpty);
    expect(skipped, 1);
    expect(file.streamReads, 1);
    expect(file.unboundedReads, 0);
  });

  test('aggregate bound is checked before reading the next file', () async {
    final first = _File(3, [
          [1, 2, 3],
        ]),
        second = _File(3, [
          [4, 5, 6],
        ]);
    final rejected = <String>[];
    final (files, skipped) = await droppedItemsToPlatformFiles(
      [first, second],
      maxFileBytes: 4,
      maxTotalBytes: 5,
      onRejected: (_, reason) => rejected.add(reason),
    );
    expect(files.single.bytes, [1, 2, 3]);
    expect(skipped, 1);
    expect(second.streamReads, 0);
    expect(rejected, ['BATCH_TOO_LARGE']);
  });

  test(
    'identity cancellation discards every buffered file before dispatch',
    () async {
      var current = true;
      final file = _File(2, [
        [1],
        [2],
      ]);
      Stream<List<int>> chunks() async* {
        yield [1];
        current = false;
        yield [2];
      }

      await expectLater(
        readBoundedFileBytes(chunks(), maxBytes: 4, canContinue: () => current),
        throwsA(isA<UtenFileReadCancelled>()),
      );
      final (files, _) = await droppedItemsToPlatformFiles(
        [file],
        maxFileBytes: 4,
        canContinue: () => false,
      );
      expect(files, isEmpty);
      expect(file.streamReads, 0);
    },
  );
}
