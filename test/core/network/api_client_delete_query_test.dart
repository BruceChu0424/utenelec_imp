// ApiClient.delete 可带查询参数(例如 AI 服务删除的乐观锁版本号 `?version=`), 不带时 URL 不变。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';

void main() {
  test('delete sends optional query parameters on the URL', () async {
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://example.test/api'))
      ..httpClientAdapter = adapter;
    final api = ApiClient(dio);

    await api.delete('/admin/ai/providers/p-1');
    await api.delete('/admin/ai/providers/p-1', query: {'version': 7});

    expect(adapter.sent.map((o) => o.method), ['DELETE', 'DELETE']);
    expect(
      adapter.sent.first.uri.toString(),
      'http://example.test/api/admin/ai/providers/p-1',
    );
    expect(
      adapter.sent.last.uri.toString(),
      'http://example.test/api/admin/ai/providers/p-1?version=7',
    );
  });
}

class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> sent = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add(options);
    return ResponseBody.fromString('', 204);
  }

  @override
  void close({bool force = false}) {}
}
