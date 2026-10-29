import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';

class _PackageAdapter implements HttpClientAdapter {
  RequestOptions? seen;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen = options;
    return ResponseBody.fromString('fixture-package', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const path = '/client-updates/11111111-1111-1111-1111-111111111111/download';
  late Dio dio;
  late _PackageAdapter adapter;
  late ApiClient api;
  setUp(() {
    adapter = _PackageAdapter();
    dio = Dio(BaseOptions(baseUrl: 'https://approved.test/api'))
      ..httpClientAdapter = adapter;
    api = ApiClient(dio);
  });
  tearDown(() => dio.close(force: true));

  test('legacy Flutter package requests keep their default path', () async {
    final stream = await api.getPackageStream(path, cancelToken: CancelToken());
    expect(await stream.expand((chunk) => chunk).toList(), isNotEmpty);
    expect(adapter.seen!.path, path);
    expect(adapter.seen!.queryParameters, isEmpty);
    expect(adapter.seen!.followRedirects, isFalse);
  });

  for (final family in ['flutter', 'wpf_legacy']) {
    test('preserves the approved $family selector on authenticated stream', () async {
      await api.getPackageStream('$path?runtimeFamily=$family', cancelToken: CancelToken());
      expect(adapter.seen!.path, path);
      expect(adapter.seen!.queryParameters, {'runtimeFamily': family});
      expect(adapter.seen!.uri.host, 'approved.test');
      expect(adapter.seen!.followRedirects, isFalse);
    });
  }

  test('rejects foreign origins and arbitrary or ambiguous selectors', () async {
    for (final invalid in [
      'https://foreign.test$path',
      '//foreign.test$path',
      '$path#fragment',
      '$path?runtimeFamily=wpf_legacy&runtimeFamily=flutter',
      '$path?runtimeFamily=wpf_legacy&token=secret',
      '$path?runtimeFamily=unknown',
      '$path?runtimeFamily=%77pf_legacy',
      '$path?',
      '$path\n',
    ]) {
      await expectLater(
        api.getPackageStream(invalid, cancelToken: CancelToken()),
        throwsFormatException,
        reason: invalid,
      );
    }
    expect(adapter.seen, isNull);
  });
}
