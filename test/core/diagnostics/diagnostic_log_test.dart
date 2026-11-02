import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_log.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_record.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_request_interceptor.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_storage_io.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_store.dart';

class _Store implements DiagnosticStore {
  final lines = StringBuffer();
  Completer<void>? gate;
  bool fail = false;
  int writes = 0;
  @override
  String? get directory => null;
  @override
  Future<void> append(String text) async {
    writes++;
    await gate?.future;
    if (fail) throw const FileSystemException('private data must not leak');
    lines.write(text);
  }

  @override
  Future<Uint8List> readRecent() async =>
      Uint8List.fromList(utf8.encode(lines.toString()));
  @override
  Future<void> openDirectory() async {}
}

class _BadText {
  @override
  String toString() => throw StateError('private');
}

class _Adapter implements HttpClientAdapter {
  int requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests++;
    return ResponseBody.fromString(
      '{"message":"private business response"}',
      403,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('Dart and C# consume the same log path contract', () async {
    final contract =
        jsonDecode(
              await File(
                'test/fixtures/client_diagnostics_v1.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    for (final sample in contract['paths'] as List<dynamic>) {
      final row = sample as Map<String, dynamic>;
      expect(diagnosticPath(row['input'] as String), row['expected']);
    }
  });
  test(
    'logs retain operational facts and omit sensitive payloads and identity',
    () {
      final text = diagnosticRecord('request.failed', {
        'path':
            'https://company.invalid/api/goods/01398765-4321-4321-4321-abcdef123456?token=secret',
        'method': 'POST',
        'status': 403,
        'durationMs': 12,
        'body': 'private business body',
        'headers': {'Authorization': 'Bearer secret'},
        'password': 'secret',
        'code': 'Bearer secret',
        'bytes': double.nan,
        'reason': _BadText(),
      });
      final map = jsonDecode(text) as Map<String, dynamic>;
      expect(map['path'], '/api/goods/:id');
      expect(map['status'], 403);
      expect(map.keys, isNot(contains('body')));
      expect(text, isNot(contains('private business')));
      expect(text, isNot(contains('secret')));
      expect(map.keys, isNot(contains('bytes')));
      expect(map.keys, isNot(contains('reason')));
      expect(diagnosticErrorKind(_BadText()), 'unhandled');
    },
  );
  test('huge incidental strings have a constant bounded representation', () {
    final large = List.filled(1024 * 1024, 'x').join();
    final text = diagnosticRecord('diagnostic.test', {
      'stack': large,
      'path': large,
    });
    expect(text.length, lessThan(512));
    expect(text, contains('[oversize]'));
  });
  test(
    'ten thousand events under blocked I/O stay bounded and keep the latest facts',
    () async {
      final store = _Store()..gate = Completer<void>();
      final log = DiagnosticLog(store);
      for (var i = 0; i < 10000; i++) {
        log.record('diagnostic.burst', fields: {'count': i});
      }
      var responsive = false;
      await Future<void>.delayed(Duration.zero, () => responsive = true);
      expect(responsive, isTrue);
      expect(store.writes, 1);
      store.gate!.complete();
      await log.flush();
      final text = store.lines.toString();
      expect(text, contains('diagnostic.dropped'));
      expect(text, contains('9999'));
      expect(text.length, lessThan(128 * 1024));
    },
  );
  test(
    'failed disk never replays operations or throws into UI and still exports memory',
    () async {
      final store = _Store()..fail = true;
      final log = DiagnosticLog(store);
      log.record('diagnostic.first');
      await log.flush();
      for (var i = 0; i < 1000; i++) {
        log.record('diagnostic.latest', fields: {'count': i});
      }
      final text = utf8.decode(await log.export());
      expect(store.writes, 1);
      expect(text, contains('999'));
      expect(text, isNot(contains('private data')));
    },
  );
  test(
    'file rotation and expiry preserve non-log files and export native crash records',
    () async {
      final root = await Directory.systemTemp.createTemp('uten-log-test-');
      addTearDown(() => root.delete(recursive: true));
      final unrelated = File('${root.path}/business.json');
      await unrelated.writeAsString('keep');
      for (var i = 0; i < 20; i++) {
        final file = File('${root.path}/app-old-$i.log');
        await file.writeAsString('{}\n');
        await file.setLastModified(DateTime.utc(2020, 1, 1, i));
      }
      final store = await FileDiagnosticStore.open(root, '2.5.43+2543');
      final chunk = '${List.filled(64 * 1024, 'x').join()}\n';
      for (var i = 0; i < 40; i++) {
        await store.append(chunk);
      }
      await File('${root.path}/native-fixture.log').writeAsString(
        '{"event":"native.unhandled_exception","code":"0xc0000005"}\n',
      );
      final text = utf8.decode(await store.readRecent());
      expect(await unrelated.readAsString(), 'keep');
      expect(text, contains('native.unhandled_exception'));
      final files = await root
          .list()
          .where((f) => f is File && f.path.endsWith('.log'))
          .toList();
      expect(files.length, lessThanOrEqualTo(18));
      for (final f in files.where((f) => !f.path.contains('old-'))) {
        expect(await (f as File).length(), lessThanOrEqualTo(2 * 1024 * 1024));
      }
    },
  );
  test(
    'request logging leaves refusals intact and sends no credentials or body to logs',
    () async {
      final previous = AppDiagnostics.log;
      final store = _Store();
      final log = DiagnosticLog(store);
      AppDiagnostics.log = log;
      addTearDown(() => AppDiagnostics.log = previous);
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'))
        ..httpClientAdapter = adapter;
      dio.interceptors.add(DiagnosticRequestInterceptor());
      addTearDown(dio.close);
      DioException? failure;
      try {
        await dio.post<dynamic>(
          '/goods/123',
          data: {'password': 'secret', 'name': 'private order'},
          options: Options(headers: {'Authorization': 'Bearer secret'}),
        );
      } on DioException catch (error) {
        failure = error;
      }
      expect(failure?.response?.data, {'message': 'private business response'});
      expect(adapter.requests, 1);
      await log.flush();
      final text = store.lines.toString();
      expect(text, contains('/goods/:id'));
      expect(text, contains('403'));
      for (final value in [
        'secret',
        'private order',
        'private business response',
        'Authorization',
      ]) {
        expect(text, isNot(contains(value)));
      }
    },
  );
}
