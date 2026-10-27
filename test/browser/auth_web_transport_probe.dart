// Compiled and run in a real headless browser by tool/verify_auth_web_transport.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;
import 'package:uten_imp/core/network/streaming_download_adapter_web.dart';

Future<void> main() async {
  final results = <Map<String, Object?>>[];
  final dio = _client();
  Future<void> check(String name, Future<void> Function() action) async {
    try {
      await action();
      results.add({'name': name, 'passed': true});
    } catch (error) {
      results.add({'name': name, 'passed': false, 'error': error.toString()});
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
  } finally {
    dio.close(force: true);
  }
  final report = jsonEncode({'results': results});
  web.document.body!.textContent = report;
  await web.window
      .fetch('/report'.toJS, web.RequestInit(method: 'POST', body: report.toJS))
      .toDart;
}

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
