import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/file_upload_contract.dart';
import 'package:uten_imp/core/network/interceptors/safe_request_retry_interceptor.dart';
import 'package:uten_imp/core/network/interceptors/write_deadline_interceptor.dart';
import 'package:uten_imp/core/network/network_policy.dart';

class _Capture implements HttpClientAdapter {
  late RequestOptions request;
  List<int>? wireBytes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    if (requestStream != null) {
      wireBytes = await requestStream.expand((bytes) => bytes).toList();
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Dio dio;
  late _Capture capture;
  late ApiClient api;
  setUp(() {
    dio = Dio(buildApiBaseOptions('https://fixture.test/api'));
    capture = _Capture();
    dio.httpClientAdapter = capture;
    api = ApiClient(dio);
  });
  tearDown(() => dio.close(force: true));

  test(
    'client file keeps original ID and finite 35 minute browser budget',
    () async {
      dio.interceptors.add(const WriteDeadlineInterceptor(enabled: true));
      await api.uploadClientPackage(
        '/admin/client-releases/original-id/package',
        Uint8List.fromList([1, 2, 3]),
        onProgress: (_, _) {},
      );
      expect(
        capture.request.path,
        '/admin/client-releases/original-id/package',
      );
      expect(capture.request.sendTimeout, const Duration(minutes: 30));
      expect(capture.request.receiveTimeout, const Duration(minutes: 5));
      expect(capture.request.connectTimeout, const Duration(minutes: 5));
      expect(
        capture.request.extra[fileUploadOverallTimeoutKey],
        const Duration(minutes: 35),
      );
      expect(capture.request.extra[safeRequestRetryDisabledKey], isTrue);
    },
  );

  test(
    'AI-sized byte upload preserves native phases and has four minute total',
    () async {
      await api.postBytes(
        '/ai/jobs',
        Uint8List.fromList([1, 2]),
        sendTimeout: const Duration(minutes: 3),
        receiveTimeout: const Duration(minutes: 1),
      );
      expect(capture.request.connectTimeout, apiConnectTimeout);
      expect(capture.request.sendTimeout, const Duration(minutes: 3));
      expect(capture.request.receiveTimeout, const Duration(minutes: 1));
      expect(
        capture.request.extra[fileUploadOverallTimeoutKey],
        const Duration(minutes: 4),
      );
      expect(capture.request.extra[safeRequestRetryDisabledKey], isTrue);
    },
  );

  test('multipart files share the finite upload contract', () async {
    await api.postMultipartFile(
      '/ocr',
      Uint8List.fromList([0, 255]),
      'original.png',
      'image/png',
      receiveTimeout: const Duration(minutes: 2),
    );
    expect(capture.request.sendTimeout, apiSendTimeout);
    expect(capture.request.receiveTimeout, const Duration(minutes: 2));
    expect(
      capture.request.extra[fileUploadOverallTimeoutKey],
      const Duration(seconds: 150),
    );
    expect(capture.request.extra[safeRequestRetryDisabledKey], isTrue);
    expect((capture.request.data as FormData).files.map((entry) => entry.key), [
      'file',
    ]);
  });
  test(
    'typed JSON parts retain exact decimal strings and original file bytes',
    () async {
      await api.postMultipartFile(
        '/finance/statement-documents/reviews/original/counterpart',
        Uint8List.fromList([0, 255, 7]),
        'original.pdf',
        'application/pdf',
        jsonParts: {
          'input': {
            'documentSha256': 'a' * 64,
            'signatoryName': '实际签署人',
            'sourceReference': '原回传确认依据',
            'amount': '12345678901234567890.123456789012345678901234',
          },
        },
      );
      final form = capture.request.data as FormData;
      expect(form.files.map((entry) => entry.key), ['input', 'file']);
      final wire = latin1.decode(capture.wireBytes!);
      expect(wire, contains('application/json'));
      expect(wire, contains('12345678901234567890.123456789012345678901234'));
      expect(wire, contains(String.fromCharCodes([0, 255, 7])));
      expect(capture.request.extra[safeRequestRetryDisabledKey], isTrue);
      expect(capture.request.extra[fileUploadOverallTimeoutKey], isNotNull);
    },
  );

  test(
    'disabled byte phase limits cannot create an unbounded explicit upload',
    () async {
      await api.postBytes(
        '/import',
        Uint8List.fromList([1]),
        sendTimeout: Duration.zero,
        receiveTimeout: Duration.zero,
      );
      expect(capture.request.sendTimeout, Duration.zero);
      expect(capture.request.receiveTimeout, Duration.zero);
      expect(
        capture.request.extra[fileUploadOverallTimeoutKey],
        const Duration(seconds: 75),
      );
    },
  );

  test('ordinary JSON requests do not inherit a file upload budget', () async {
    await api.post('/production/plan/approve', body: {'revision': 1});
    expect(
      capture.request.extra.containsKey(fileUploadOverallTimeoutKey),
      isFalse,
    );
    expect(capture.request.sendTimeout, apiSendTimeout);
    expect(capture.request.receiveTimeout, apiReceiveTimeout);
  });
}
