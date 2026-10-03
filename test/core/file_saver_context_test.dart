import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:uten_imp/core/io/file_saver.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final Future<String?> directory;
  @override
  Future<String?> getDownloadsPath() => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previous;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('uten-save-context-');
    previous = PathProviderPlatform.instance;
  });
  tearDown(() {
    PathProviderPlatform.instance = previous;
    if (!directory.absolute.path.startsWith(
      Directory.systemTemp.absolute.path,
    )) {
      throw StateError('Unexpected test directory');
    }
    directory.deleteSync(recursive: true);
  });
  test(
    'identity loss while finding download directory prevents file creation',
    () async {
      final destination = Completer<String?>();
      PathProviderPlatform.instance = _Paths(destination.future);
      bool current = true;
      final saved = saveBytes(
        Uint8List.fromList([1]),
        'quote.xlsx',
        stillCurrent: () => current,
      );
      current = false;
      destination.complete(directory.path);
      await expectLater(saved, throwsStateError);
      expect(directory.listSync(), isEmpty);
    },
  );
  test(
    'existing callers without a context callback still save normally',
    () async {
      PathProviderPlatform.instance = _Paths(Future.value(directory.path));
      final path = await saveBytes(Uint8List.fromList([4, 5, 6]), 'quote.xlsx');
      expect(File(path).readAsBytesSync(), [4, 5, 6]);
    },
  );
  test(
    'identity is checked again after probing the available filename',
    () async {
      PathProviderPlatform.instance = _Paths(Future.value(directory.path));
      File('${directory.path}/quote.xlsx').writeAsStringSync('existing');
      int checks = 0;
      await expectLater(
        saveBytes(
          Uint8List.fromList([1]),
          'quote.xlsx',
          stillCurrent: () => ++checks < 3,
        ),
        throwsStateError,
      );
      expect(checks, 3);
      expect(directory.listSync(), hasLength(1));
      expect(
        File('${directory.path}/quote.xlsx').readAsStringSync(),
        'existing',
      );
    },
  );
}
