import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Test evidence only. Keeps the first original stack before a later error storm.
/// Every error still reaches the handler that the app/test binding installed.
class FirstFlutterFailureCapture {
  FirstFlutterFailureCapture(
    this.directory, {
    required this.sourceHead,
    this.onFirstCaptured,
  });

  final Directory directory;
  final String sourceHead;
  final void Function(FlutterErrorDetails details)? onFirstCaptured;
  final _seen = Expando<bool>('first-flutter-failure-forwarding');
  FlutterExceptionHandler? _original;
  FlutterExceptionHandler? _installed;
  bool _hasOriginal = false;
  bool _alive = true;
  String phase = 'before-bootstrap';
  FlutterErrorDetails? first;
  int count = 0;
  Object? persistenceError;
  Object? publicationError;

  void install() {
    if (!_alive || identical(FlutterError.onError, _installed)) return;
    final previous = FlutterError.onError;
    if (!_hasOriginal) {
      _original = previous;
      _hasOriginal = true;
    }
    void handler(FlutterErrorDetails details) {
      _record(details);
      previous?.call(details);
    }

    _installed = handler;
    FlutterError.onError = handler;
  }

  void _record(FlutterErrorDetails details) {
    if (!_alive || _seen[details] == true) return;
    _seen[details] = true;
    count++;
    if (first != null) return;
    first = details;
    try {
      final record = {
        'sourceHead': sourceHead,
        'phase': phase,
        'capturedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'exceptionType': details.exception.runtimeType.toString(),
        'exception': details.exceptionAsString(),
        'stack': details.stack?.toString(),
        'hasOriginalStack': details.stack != null,
        'captureStackWhenOriginalMissing': details.stack == null
            ? StackTrace.current.toString()
            : null,
        'library': details.library,
        'context': details.context?.toDescription(),
        'silent': details.silent,
      };
      directory.createSync(recursive: true);
      File('${directory.path}/first-flutter-error.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(record),
        flush: true,
      );
      File('${directory.path}/first-flutter-error.txt').writeAsStringSync(
        'sourceHead=$sourceHead\nphase=$phase\n'
        '${details.exceptionAsString()}\n\n'
        '${details.stack ?? 'Original framework stack was unavailable.'}\n',
        flush: true,
      );
    } catch (error) {
      // The original framework error is still forwarded and remains fatal.
      persistenceError = error;
    }
    try {
      onFirstCaptured?.call(details);
    } catch (error) {
      publicationError = error;
    }
  }

  Never throwFirst() {
    final details = first!;
    Error.throwWithStackTrace(
      details.exception,
      details.stack ?? StackTrace.current,
    );
  }

  void restore() {
    if (!_alive) return;
    _alive = false;
    if (_hasOriginal) FlutterError.onError = _original;
  }
}
