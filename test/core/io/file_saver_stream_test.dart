import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/io/file_saver_io.dart' as saver;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('uten-b1-stream-');
  });
  tearDown(() async {
    if (!directory.absolute.path.startsWith(
      Directory.systemTemp.absolute.path,
    )) {
      throw StateError('Unexpected fixture directory');
    }
    await directory.delete(recursive: true);
  });
  Future<String> save(
    Stream<Uint8List> source, {
    bool Function()? current,
    Future<void> Function()? verify,
    int maxBytes = 8 * 1024 * 1024,
  }) => saver.saveStream(
    source,
    'facts.xlsx',
    destination: () async => directory,
    stillCurrent: current,
    verifyScope: verify,
    maxBytes: maxBytes,
  );

  test(
    'large source is consumed in order without retaining an input list',
    () async {
      var produced = 0;
      Stream<Uint8List> source() async* {
        for (var i = 0; i < 128; i++) {
          produced++;
          yield Uint8List(32768)..fillRange(0, 32768, i);
        }
      }

      final path = await save(source());
      expect(produced, 128);
      expect(await File(path).length(), 4 * 1024 * 1024);
      final reader = await File(path).open();
      try {
        for (var i = 0; i < 128; i++) {
          final bytes = await reader.read(32768);
          expect(bytes.every((b) => b == i), isTrue);
        }
      } finally {
        await reader.close();
      }
      expect(directory.listSync(), hasLength(1));
    },
  );
  test(
    'failed stream and size rejection remove partial files and preserve an existing file',
    () async {
      final previous = File('${directory.path}/facts.xlsx');
      await previous.writeAsString('original');
      Stream<Uint8List> failed() async* {
        yield Uint8List.fromList([1, 2]);
        throw StateError('fixture network failure');
      }

      await expectLater(save(failed()), throwsStateError);
      await expectLater(
        save(Stream.value(Uint8List(8)), maxBytes: 7),
        throwsStateError,
      );
      expect(await previous.readAsString(), 'original');
      expect(directory.listSync(), hasLength(1));
    },
  );
  test(
    'identity ABA or final authorization failure never publishes downloaded bytes',
    () async {
      var epoch = 0;
      final initial = epoch;
      Stream<Uint8List> stale() async* {
        yield Uint8List.fromList([1]);
        epoch++;
        epoch++;
        yield Uint8List.fromList([2]);
      }

      await expectLater(
        save(stale(), current: () => epoch == initial),
        throwsStateError,
      );
      expect(directory.listSync(), isEmpty);
      await expectLater(
        save(
          Stream.value(Uint8List.fromList([3])),
          verify: () async {
            throw StateError('withdrawn');
          },
        ),
        throwsStateError,
      );
      expect(directory.listSync(), isEmpty);
    },
  );
  test(
    'concurrent equal filenames remain distinct and failed publication does not poison later saves',
    () async {
      final paths = await Future.wait([
        save(Stream.value(Uint8List.fromList([1, 2]))),
        save(Stream.value(Uint8List.fromList([3, 4, 5]))),
      ]);
      expect(paths.toSet(), hasLength(2));
      expect(await File(paths[0]).readAsBytes(), [1, 2]);
      expect(await File(paths[1]).readAsBytes(), [3, 4, 5]);
      expect(directory.listSync(), hasLength(2));
    },
  );
}
