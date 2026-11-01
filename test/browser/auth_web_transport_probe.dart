// Compiled and run in a real headless browser by tool/verify_auth_web_transport.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;
import 'package:uten_imp/core/network/streaming_download_adapter_web.dart';
import 'package:uten_imp/core/network/file_upload_contract.dart';

@JS('utenFetchAbortCount')
external JSNumber _abortCount(JSString path);

Future<void> main() async {
  final results = <Map<String, Object?>>[];
  final observations = <String, Object?>{};
  final dio = _client();
  Future<void> check(String name, Future<void> Function() action) async {
    await _caseEvent(name, 'start');
    try {
      await action();
      results.add({'name': name, 'passed': true});
      await _caseEvent(name, 'passed');
    } catch (error) {
      results.add({'name': name, 'passed': false, 'error': error.toString()});
      await _caseEvent(name, error.toString());
    }
  }

  try {
    await check('JSON bytes and final upload progress', () async {
      final progress = <(int, int)>[];
      final response = await dio.post<Map<String, dynamic>>(
        '/echo',
        data: {'type': 'json', 'value': '原文'},
        onSendProgress: (sent, total) => progress.add((sent, total)),
      );
      _expect(response.data!['utf8'] == '{"type":"json","value":"原文"}');
      _expect(progress.first.$1 == 0);
      _expect(progress.last.$1 == progress.last.$2);
      _expect(
        progress.last.$2 ==
            utf8.encode(response.data!['utf8'] as String).length,
      );
    });
    await check('URL encoded form body', () async {
      final response = await dio.post<Map<String, dynamic>>(
        '/echo',
        data: {'item': 'one two', 'value': '资料'},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final fields = Uri.splitQueryString(response.data!['utf8'] as String);
      _expect(fields['item'] == 'one two' && fields['value'] == '资料');
    });
    await check('multipart binary bytes and boundary', () async {
      final response = await dio.post<Map<String, dynamic>>(
        '/echo',
        data: FormData.fromMap({
          'label': 'upload-original',
          'file': MultipartFile.fromBytes([
            0,
            1,
            127,
            128,
            255,
          ], filename: 'original.bin'),
        }),
      );
      final body = base64Decode(response.data!['base64'] as String);
      final text = latin1.decode(body);
      _expect((response.data!['contentType'] as String).contains('boundary='));
      _expect(
        text.contains('name="label"') && text.contains('upload-original'),
      );
      _expect(text.contains('filename="original.bin"'));
      _expect(_containsBytes(body, [0, 1, 127, 128, 255]));
    });
    for (final status in [302, 307]) {
      await check('HTTP $status redirect rejected before receiver', () async {
        final error = await _error(
          dio.request<dynamic>(
            '/redirect/$status',
            data: status == 307 ? {'secret': 'synthetic-body'} : null,
            options: Options(method: status == 307 ? 'POST' : 'GET'),
          ),
        );
        _expect(error.type == DioExceptionType.connectionError);
        final stats = await dio.get<Map<String, dynamic>>('/stats');
        _expect(stats.data!['outsideRequests'] == 0);
      });
    }
    await check('in-flight cancellation aborts Fetch', () async {
      final cancel = CancelToken();
      final response = dio.get<dynamic>('/wait/cancel', cancelToken: cancel);
      final outcome = _error(response);
      await dio.get<dynamic>('/barrier/cancel');
      cancel.cancel('synthetic cancellation');
      _expect((await outcome).type == DioExceptionType.cancel);
    });
    await check('connection timeout before response headers', () async {
      final client = _client(connect: const Duration(milliseconds: 40));
      try {
        final error = await _error(
          client.get<dynamic>('/wait/connect-timeout'),
        );
        _expect(error.type == DioExceptionType.connectionTimeout);
      } finally {
        client.close(force: true);
      }
    });
    await check(
      'send timeout while preparing a stalled upload stream',
      () async {
        final stream = StreamController<Uint8List>();
        final client = _client(
          connect: Duration.zero,
          receive: Duration.zero,
          send: const Duration(milliseconds: 40),
        );
        try {
          final error = await _error(
            client.post<dynamic>(
              '/echo',
              data: stream.stream,
              options: Options(headers: {Headers.contentLengthHeader: '1'}),
            ),
          );
          _expect(error.type == DioExceptionType.sendTimeout);
        } finally {
          unawaited(stream.close());
          client.close(force: true);
        }
      },
    );
    await check(
      'send-only timeout bounds browser upload/header wait',
      () async {
        final client = _client(
          connect: Duration.zero,
          receive: Duration.zero,
          send: const Duration(milliseconds: 40),
        );
        try {
          final error = await _error(
            client.post<dynamic>(
              '/wait/send-timeout',
              data: {'upload': 'original'},
            ),
          );
          _expect(error.type == DioExceptionType.sendTimeout);
        } finally {
          client.close(force: true);
        }
      },
    );
    await check('receive timeout aborts a stalled response body', () async {
      final client = _client(receive: const Duration(milliseconds: 40));
      try {
        final error = await _error(client.get<dynamic>('/slow-body'));
        _expect(error.type == DioExceptionType.receiveTimeout);
      } finally {
        client.close(force: true);
      }
    });

    await check(
      'ordinary shorter receive still bounds response headers',
      () async {
        final client = _client(receive: const Duration(milliseconds: 40));
        try {
          final error = await _error(
            client.put<dynamic>(
              '/wait/ordinary-receive',
              data: Uint8List.fromList([1, 2]),
            ),
          );
          _expect(error.type == DioExceptionType.receiveTimeout);
          _expect(
            _abortCount('/api/wait/ordinary-receive'.toJS).toDartInt == 1,
          );
        } finally {
          client.close(force: true);
        }
      },
    );

    await check(
      'slow file send exceeds receive phase within finite total',
      () async {
        final client = _client(
          send: const Duration(seconds: 5),
          receive: const Duration(milliseconds: 80),
        );
        final bytes = Uint8List(4 * 1024 * 1024);
        final progress = <(int, int)>[];
        try {
          final operation = client
              .put<Map<String, dynamic>>(
                '/upload/slow',
                data: bytes,
                options: _fileOptions(const Duration(milliseconds: 5080)),
                onSendProgress: (sent, total) => progress.add((sent, total)),
              )
              .then<Object>(
                (response) => response,
                onError: (Object error) => error,
              );
          await client.get<dynamic>('/barrier/slow-file');
          await Future<void>.delayed(const Duration(milliseconds: 120));
          _expect(progress.isNotEmpty && progress.every((p) => p.$1 == 0));
          final outcome = await operation;
          if (outcome is! Response<Map<String, dynamic>>) throw outcome;
          final response = outcome;
          _expect(response.data!['bytes'] == bytes.length);
          _expect((response.data!['readMillis'] as num) > 80);
          _expect((response.data!['chunks'] as num) > 1);
          _expect(progress.last.$1 == bytes.length);
          observations['slowFileUpload'] = response.data;
        } finally {
          client.close(force: true);
        }
      },
    );

    await check('explicit total deadline really aborts Fetch', () async {
      final client = _client();
      try {
        final error = await _error(
          client.put<dynamic>(
            '/wait/file-total',
            data: Uint8List.fromList([1, 2]),
            options: _fileOptions(const Duration(milliseconds: 120)),
          ),
        );
        _expect(error.type == DioExceptionType.sendTimeout);
        _expect(error.message!.contains('overall'));
        _expect(_abortCount('/api/wait/file-total'.toJS).toDartInt == 1);
      } finally {
        client.close(force: true);
      }
    });

    await check(
      'same total budget covers request stream preparation',
      () async {
        final client = _client();
        var cancelled = false;
        final stream = StreamController<Uint8List>(
          onCancel: () {
            cancelled = true;
          },
        );
        try {
          final error = await _error(
            client.put<dynamic>(
              '/echo',
              data: stream.stream,
              options: Options(
                headers: {Headers.contentLengthHeader: '1'},
                extra: {
                  fileUploadOverallTimeoutKey: const Duration(milliseconds: 80),
                },
              ),
            ),
          );
          _expect(
            error.type == DioExceptionType.sendTimeout &&
                error.message!.contains('overall'),
          );
          _expect(cancelled);
        } finally {
          unawaited(stream.close());
          client.close(force: true);
        }
      },
    );

    await check(
      'total budget survives headers and bounds final response body',
      () async {
        final client = _client();
        try {
          final error = await _error(
            client.put<dynamic>(
              '/upload/slow-response',
              data: Uint8List.fromList([1]),
              options: _fileOptions(const Duration(milliseconds: 280)),
            ),
          );
          _expect(
            error.type == DioExceptionType.sendTimeout &&
                error.message!.contains('overall'),
          );
          _expect(_abortCount('/api/upload/slow-response'.toJS).toDartInt == 1);
        } finally {
          client.close(force: true);
        }
      },
    );

    await check(
      'successful final body releases the total timer and controller',
      () async {
        final client = _client();
        try {
          await client.put<dynamic>(
            '/echo',
            data: Uint8List.fromList([4, 5]),
            options: _fileOptions(const Duration(milliseconds: 150)),
          );
          await Future<void>.delayed(const Duration(milliseconds: 200));
          _expect(_abortCount('/api/echo'.toJS).toDartInt == 0);
        } finally {
          client.close(force: true);
        }
        _expect(_abortCount('/api/echo'.toJS).toDartInt == 0);
      },
    );
    await check('empty final body releases its total timer', () async {
      final client = _client();
      try {
        await client.put<dynamic>(
          '/upload/no-response-body',
          data: Uint8List.fromList([5]),
          options: _fileOptions(const Duration(milliseconds: 150)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        _expect(
          _abortCount('/api/upload/no-response-body'.toJS).toDartInt == 0,
        );
      } finally {
        client.close(force: true);
      }
    });
    await check(
      'cancellation after headers releases and aborts the original file',
      () async {
        final client = _client();
        final cancel = CancelToken();
        try {
          final response = await client.put<ResponseBody>(
            '/upload/slow-response-cancel',
            data: Uint8List.fromList([6]),
            cancelToken: cancel,
            options: Options(
              responseType: ResponseType.stream,
              extra: {
                fileUploadOverallTimeoutKey: const Duration(milliseconds: 400),
              },
            ),
          );
          await _caseEvent('stream-cancel', 'headers');
          final subscription = response.data!.stream.listen(
            (_) {},
            onError: (Object _, StackTrace _) {},
          );
          // Use the public cancellation contract while final bytes are pending;
          // Dio owns closing its internal ResponseBody and transformed listener.
          cancel.cancel('cancel original response body');
          await subscription.cancel();
          await _caseEvent('stream-cancel', 'subscription canceled');
          await Future<void>.delayed(const Duration(milliseconds: 450));
          _expect(
            _abortCount('/api/upload/slow-response-cancel'.toJS).toDartInt == 1,
          );
        } finally {
          client.close(force: true);
        }
      },
    );

    await check(
      'explicit file cancellation preserves cancel and aborts',
      () async {
        final client = _client(), cancel = CancelToken();
        try {
          final outcome = _error(
            client.put<dynamic>(
              '/wait/file-cancel',
              data: Uint8List.fromList([3]),
              cancelToken: cancel,
              options: _fileOptions(const Duration(milliseconds: 400)),
            ),
          );
          await client.get<dynamic>('/barrier/file-cancel');
          cancel.cancel('cancel original file');
          _expect((await outcome).type == DioExceptionType.cancel);
          await Future<void>.delayed(const Duration(milliseconds: 450));
          _expect(_abortCount('/api/wait/file-cancel'.toJS).toDartInt == 1);
        } finally {
          client.close(force: true);
        }
      },
    );

    await check(
      'forced close aborts active file without leaving its timer',
      () async {
        final client = _client();
        final outcome = _error(
          client.put<dynamic>(
            '/wait/file-close',
            data: Uint8List.fromList([3]),
            options: _fileOptions(const Duration(milliseconds: 400)),
          ),
        );
        await client.get<dynamic>('/barrier/file-close');
        client.close(force: true);
        _expect((await outcome).type == DioExceptionType.connectionError);
        await Future<void>.delayed(const Duration(milliseconds: 450));
        _expect(_abortCount('/api/wait/file-close'.toJS).toDartInt == 1);
      },
    );

    await check('forced close also cancels stalled file pre-read', () async {
      final client = _client();
      var cancelled = false;
      final stream = StreamController<Uint8List>(
        onCancel: () {
          cancelled = true;
        },
      );
      final outcome = _error(
        client.put<dynamic>(
          '/echo',
          data: stream.stream,
          options: Options(
            headers: {Headers.contentLengthHeader: '1'},
            extra: {fileUploadOverallTimeoutKey: const Duration(seconds: 2)},
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      client.close(force: true);
      _expect((await outcome).type == DioExceptionType.connectionError);
      _expect(cancelled);
      unawaited(stream.close());
    });

    await check(
      'explicit files never fall back to redirect-following XHR',
      () async {
        final error = await _error(
          dio.put<dynamic>(
            '/redirect/307',
            data: Uint8List.fromList([7, 8]),
            options: _fileOptions(
              const Duration(seconds: 2),
              followRedirects: true,
            ),
          ),
        );
        _expect(error.type == DioExceptionType.connectionError);
        final stats = await dio.get<Map<String, dynamic>>('/stats');
        _expect(stats.data!['outsideRequests'] == 0);
      },
    );
  } finally {
    dio.close(force: true);
  }
  final report = jsonEncode({'results': results, 'observations': observations});
  web.document.body!.textContent = report;
  await web.window
      .fetch('/report'.toJS, web.RequestInit(method: 'POST', body: report.toJS))
      .toDart;
}

Future<void> _caseEvent(String name, String event) async {
  await web.window
      .fetch(
        '/case-event'.toJS,
        web.RequestInit(
          method: 'POST',
          body: jsonEncode({'name': name, 'event': event}).toJS,
        ),
      )
      .toDart;
}

Options _fileOptions(Duration budget, {bool followRedirects = false}) =>
    Options(
      followRedirects: followRedirects,
      extra: {fileUploadOverallTimeoutKey: budget},
    );

Dio _client({
  Duration connect = const Duration(seconds: 3),
  Duration receive = const Duration(seconds: 3),
  Duration send = const Duration(seconds: 3),
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: '${web.window.location.origin}/api',
      followRedirects: false,
      connectTimeout: connect,
      receiveTimeout: receive,
      sendTimeout: send,
      headers: {'Authorization': 'Bearer synthetic-browser-token'},
    ),
  );
  dio.httpClientAdapter = wrapStreamingDownloads(dio.httpClientAdapter);
  return dio;
}

Future<DioException> _error(Future<dynamic> operation) => operation.then(
  (_) => throw StateError('Expected transport rejection'),
  onError: (Object error) {
    if (error is DioException) return error;
    throw error;
  },
);

void _expect(bool value) {
  if (!value) throw StateError('Browser transport assertion failed');
}

bool _containsBytes(List<int> bytes, List<int> expected) {
  for (var start = 0; start <= bytes.length - expected.length; start++) {
    if (List.generate(
      expected.length,
      (i) => bytes[start + i] == expected[i],
    ).every((v) => v)) {
      return true;
    }
  }
  return false;
}
