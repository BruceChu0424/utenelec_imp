import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/first_flutter_failure_capture.dart';

void main() {
  Directory fresh() =>
      Directory.systemTemp.createTempSync('uten-first-flutter.');
  void removeOwned(Directory directory) {
    expect(
      directory.parent.resolveSymbolicLinksSync(),
      Directory.systemTemp.resolveSymbolicLinksSync(),
    );
    expect(
      directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
      startsWith('uten-first-flutter.'),
    );
    directory.deleteSync(recursive: true);
  }

  test(
    'first complete stack survives 500 later errors and every error forwards',
    () {
      final directory = fresh();
      final originalHandler = FlutterError.onError;
      var forwarded = 0;
      var firstPublications = 0;
      FlutterError.onError = (_) => forwarded++;
      final capture =
          FirstFlutterFailureCapture(
              directory,
              sourceHead: 'a' * 40,
              onFirstCaptured: (_) => firstPublications++,
            )
            ..phase = 'native-narrow-before-menu'
            ..install();
      final stack = [
        for (var i = 0; i < 900; i++) '#$i original frame $i',
      ].join('\n');
      final first = FlutterError('original layout assertion');
      try {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: first,
            stack: StackTrace.fromString(stack),
            library: 'retained-layout-fixture',
          ),
        );
        final file = File('${directory.path}/first-flutter-error.json');
        final bytes = file.readAsBytesSync();
        for (var i = 0; i < 500; i++) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: FlutterError('later $i'),
              stack: StackTrace.fromString('later stack $i'),
            ),
          );
        }
        final record =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(record['stack'], stack);
        expect(record['phase'], 'native-narrow-before-menu');
        expect(record['exception'], contains('original layout assertion'));
        expect(file.readAsBytesSync(), bytes);
        expect(capture.count, 501);
        expect(forwarded, 501);
        expect(firstPublications, 1);
        expect(() => capture.throwFirst(), throwsA(same(first)));
      } finally {
        capture.restore();
        FlutterError.onError = originalHandler;
        removeOwned(directory);
      }
    },
  );

  test(
    'reinstall chains an app handler once and restore returns original handler',
    () {
      final directory = fresh();
      final saved = FlutterError.onError;
      var originalCalls = 0, appCalls = 0;
      void original(FlutterErrorDetails details) => originalCalls++;
      FlutterError.onError = original;
      final capture = FirstFlutterFailureCapture(
        directory,
        sourceHead: 'b' * 40,
      )..install();
      final old = FlutterError.onError;
      FlutterError.onError = (details) {
        appCalls++;
        old?.call(details);
      };
      capture.install();
      try {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: FlutterError('one original event'),
            stack: StackTrace.fromString('one original stack'),
          ),
        );
        expect(capture.count, 1);
        expect(originalCalls, 1);
        expect(appCalls, 1);
        capture.restore();
        expect(FlutterError.onError, same(original));
      } finally {
        capture.restore();
        FlutterError.onError = saved;
        removeOwned(directory);
      }
    },
  );

  test(
    'evidence I/O failure never replaces or consumes the original failure',
    () {
      final directory = fresh();
      final file = File('${directory.path}/not-a-directory')
        ..writeAsStringSync('fixture');
      final saved = FlutterError.onError;
      var forwarded = 0;
      FlutterError.onError = (_) => forwarded++;
      final capture = FirstFlutterFailureCapture(
        Directory(file.path),
        sourceHead: 'c' * 40,
      )..install();
      final original = FlutterError('original must stay first');
      try {
        FlutterError.reportError(FlutterErrorDetails(exception: original));
        expect(capture.persistenceError, isA<FileSystemException>());
        expect(capture.first?.exception, same(original));
        expect(forwarded, 1);
        expect(() => capture.throwFirst(), throwsA(same(original)));
      } finally {
        capture.restore();
        FlutterError.onError = saved;
        removeOwned(directory);
      }
    },
  );
}
