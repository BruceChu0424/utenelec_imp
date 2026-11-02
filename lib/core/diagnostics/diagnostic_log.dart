import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../constants/app_info.dart';
import '../io/file_saver.dart';
import '../performance/data_work_queue.dart';
import 'diagnostic_record.dart';
import 'diagnostic_store.dart';
import 'diagnostic_storage_web.dart'
    if (dart.library.io) 'diagnostic_storage_io.dart'
    as storage;

class DiagnosticLog {
  DiagnosticLog(this.store);
  final DiagnosticStore store;
  final _metadata = <String, Object?>{
    'version': AppInfo.version,
    'build': AppInfo.buildId,
    'runtime': kIsWeb ? 'web' : 'flutter',
    'os': defaultTargetPlatform.name,
    'architecture': storage.diagnosticArchitecture(),
  };
  final _pending = Queue<String>();
  final _recent = Queue<String>();
  int _recentSize = 0, dropped = 0;
  bool _writing = false, _diskFailed = false;
  Completer<void>? _flushed;
  void record(
    String event, {
    String level = 'info',
    Map<String, Object?> fields = const {},
  }) {
    final line = diagnosticRecord(event, {
      ...fields,
      ..._metadata,
    }, level: level);
    _recent.add(line);
    _recentSize += line.length;
    while (_recentSize > 512 * 1024 && _recent.length > 1) {
      _recentSize -= _recent.removeFirst().length;
    }
    if (_diskFailed) return;
    if (_pending.length == 256) {
      _pending.removeFirst();
      dropped++;
    }
    _pending.add(line);
    if (!_writing) {
      _writing = true;
      unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        final batch = StringBuffer();
        if (dropped > 0) {
          batch.write(
            diagnosticRecord('diagnostic.dropped', {
              'count': dropped,
            }, level: 'warning'),
          );
          dropped = 0;
        }
        for (var i = 0; i < 32 && _pending.isNotEmpty; i++) {
          batch.write(_pending.removeFirst());
        }
        await store.append(batch.toString());
        if (_pending.isNotEmpty) await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {
      // A full/read-only disk cannot change business results or start a retry loop.
      _diskFailed = true;
      _pending.clear();
      _recent.add(
        diagnosticRecord(
          'diagnostic.storage_unavailable',
          const {},
          level: 'error',
        ),
      );
    } finally {
      _writing = false;
      _flushed?.complete();
      _flushed = null;
    }
  }

  Future<void> flush() =>
      !_writing ? Future.value() : (_flushed ??= Completer<void>()).future;
  Future<Uint8List> export() async {
    await flush().timeout(const Duration(seconds: 2), onTimeout: () {});
    if (_writing) return Uint8List.fromList(utf8.encode(_recent.join()));
    if (!_diskFailed) {
      try {
        return await store.readRecent();
      } catch (_) {
        /* Memory fallback. */
      }
    }
    return Uint8List.fromList(utf8.encode(_recent.join()));
  }
}

class AppDiagnostics {
  static DiagnosticLog? log;
  static Future<void>? _initialization;
  static Timer? _pulse;
  static Future<void> initialize() => _initialization ??= _initialize();
  static Future<void> _initialize() async {
    try {
      log = DiagnosticLog(await storage.createDiagnosticStore(AppInfo.version));
    } catch (_) {
      log = DiagnosticLog(await _fallbackStore());
    }
    record(
      'app.start',
      fields: {
        'version': AppInfo.version,
        'build': AppInfo.buildId,
        'runtime': kIsWeb ? 'web' : 'flutter',
        'os': defaultTargetPlatform.name,
      },
    );
    dataWorkQueue.onPressure = (active, pending) => record(
      'work.queue_pressure',
      level: 'warning',
      fields: {'count': pending, 'reason': 'bounded_concurrency_$active'},
    );
    final oldFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      recordError('flutter.error', details.exception, details.stack);
      oldFlutter?.call(details);
    };
    final oldPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      recordError('dart.unhandled', error, stack);
      return oldPlatform?.call(error, stack) ?? false;
    };
    final watch = Stopwatch()..start();
    var previous = 0;
    _pulse = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = watch.elapsedMilliseconds,
          gap = watch.elapsedMilliseconds - previous;
      previous = now;
      if (gap > 3000) {
        record('ui.delayed', level: 'warning', fields: {'frameGapMs': gap});
      }
    });
    WidgetsBinding.instance.addObserver(_DiagnosticLifecycle());
  }

  static Future<DiagnosticStore> _fallbackStore() async => _FallbackStore();
  static void record(
    String event, {
    String level = 'info',
    Map<String, Object?> fields = const {},
  }) => log?.record(event, level: level, fields: fields);
  static void recordError(String event, Object error, StackTrace? stack) =>
      record(
        event,
        level: 'error',
        fields: {
          'exceptionType': error.runtimeType.toString(),
          'reason': diagnosticErrorKind(error),
          if (stack != null)
            'stack': stack.toString().split('\n').take(10).join('\n'),
        },
      );
  static Future<String> exportLog({String? directory}) async {
    final current = log;
    if (current == null) await initialize();
    final bytes = await log!.export();
    return saveBytes(
      bytes,
      'UTEN-${AppInfo.version}-${DateTime.now().toUtc().millisecondsSinceEpoch}.log',
      directory: directory,
    );
  }

  static Future<void> openDirectory() async => log?.store.openDirectory();
}

class _DiagnosticLifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppDiagnostics.record('app.lifecycle', fields: {'stage': state.name});
    if (state == AppLifecycleState.detached) {
      AppDiagnostics._pulse?.cancel();
    }
    unawaited(AppDiagnostics.log?.flush());
  }
}

class _FallbackStore implements DiagnosticStore {
  final _lines = Queue<String>();
  @override
  String? get directory => null;
  @override
  Future<void> append(String lines) async {
    _lines.add(lines);
    while (_lines.length > 128) {
      _lines.removeFirst();
    }
  }

  @override
  Future<Uint8List> readRecent() async =>
      Uint8List.fromList(utf8.encode(_lines.join()));
  @override
  Future<void> openDirectory() async {}
}
