import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/responsive_json_decoder.dart';
import 'package:uten_imp/core/network/responsive_json_transformer.dart';
import 'package:uten_imp/core/network/streaming_download_contract.dart';

class _Adapter implements HttpClientAdapter {
  late Future<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}

void main() {
  const path =
      '/report-export-jobs/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/download';
  late Dio dio;
  late _Adapter adapter;
  late ResponsiveJsonDecoder decoder;
  late ApiClient client;
  setUp(() {
    adapter = _Adapter();
    decoder = ResponsiveJsonDecoder();
    dio = Dio(BaseOptions(baseUrl: 'https://stream.fixture/api'))
      ..httpClientAdapter = adapter
      ..transformer = ResponsiveJsonTransformer(decoder);
    client = ApiClient(dio, streamingDownloads: true);
  });
  tearDown(() {
    dio.close(force: true);
    decoder.dispose();
  });
  test(
    'authenticated Dio request preserves the binary stream and exact endpoint contract',
    () async {
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, next) {
            options.headers['X-Fixture-Guard'] = 'same-client';
            next.next(options);
          },
        ),
      );
      adapter.respond = (options) async {
        expect(options.headers['X-Fixture-Guard'], 'same-client');
        expect(options.data, {'password': 'fixture'});
        expect(options.extra[streamingDownloadRequestKey], isTrue);
        expect(options.followRedirects, isFalse);
        return ResponseBody(
          Stream.fromIterable([
            Uint8List.fromList([0, 255]),
            Uint8List.fromList([128, 1]),
          ]),
          200,
          headers: {
            Headers.contentLengthHeader: ['4'],
          },
        );
      };
      final chunks = await client
          .downloadExportStream(path, body: {'password': 'fixture'})
          .toList();
      expect(chunks.expand((c) => c), [0, 255, 128, 1]);
      await expectLater(
        client.downloadExportStream('/other/download').drain<void>(),
        throwsFormatException,
      );
    },
  );
  test(
    'truncated bodies fail instead of publishing a successful partial artifact',
    () async {
      adapter.respond = (_) async => ResponseBody(
        Stream.value(Uint8List.fromList([1, 2])),
        200,
        headers: {
          Headers.contentLengthHeader: ['3'],
        },
      );
      await expectLater(
        client.downloadExportStream(path).drain<void>(),
        throwsFormatException,
      );
    },
  );
  test(
    'JSON refusal reaches the normal auth/MFA interceptor path before conversion',
    () async {
      Object? seen;
      dio.interceptors.add(
        InterceptorsWrapper(
          onError: (error, next) {
            seen = error.response?.data;
            next.next(error);
          },
        ),
      );
      adapter.respond = (_) async => ResponseBody.fromString(
        jsonEncode({'code': 'MFA_REQUIRED', 'message': 'fixture refusal'}),
        403,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
      await expectLater(
        client.downloadExportStream(path).drain<void>(),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'MFA_REQUIRED'),
        ),
      );
      expect(seen, isA<Map<String, dynamic>>().having((m) => m['code'], 'code', 'MFA_REQUIRED'));
    },
  );
  test(
    'closing a read cancels its transport and does not wait for the entire artifact',
    () async {
      final cancelled = Completer<void>();
      final chunks = StreamController<Uint8List>(
        onCancel: () {
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      adapter.respond = (_) async => ResponseBody(chunks.stream, 200);
      final first = client.downloadExportStream(path).take(1).drain<void>();
      chunks.add(Uint8List.fromList([1]));
      await first;
      await cancelled.future;
      await chunks.close();
    },
  );
}
