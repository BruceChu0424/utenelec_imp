import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/paging/scoped_category_read.dart';

void main() {
  test(
    'retiring a shared category owner cancels one shared HTTP read without retry',
    () async {
      final adapter = _CategoryAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final api = ApiClient(dio);
      final reader = ScopedCategoryRead();
      addTearDown(() {
        reader.dispose();
        dio.close(force: true);
      });
      final first = reader.read(
        query: ['actor-a', 'warehouse-a'],
        fetch: () => api.get('/counts'),
      );
      final same = reader.read(
        query: ['actor-a', 'warehouse-a'],
        fetch: () => api.get('/counts'),
      );
      expect(identical(first, same), isTrue);
      final rejected = expectLater(first, throwsA(isA<ApiException>()));
      for (var attempt = 0; adapter.requests == 0 && attempt < 20; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(adapter.requests, 1);
      reader.dispose();
      await rejected;
      expect(adapter.cancelled, isTrue);
      expect(adapter.requests, 1);
      adapter.gate.complete(ResponseBody.fromString('{}', 200));
    },
  );

  test(
    'exact warehouse, source and keyword scopes share pending reads only with themselves',
    () async {
      final reader = ScopedCategoryRead();
      addTearDown(reader.dispose);
      final gate = Completer<Map<String, int>>();
      var reads = 0;
      Future<Map<String, int>> fetch() {
        reads++;
        return gate.future;
      }

      final a = reader.read(
        query: [
          'TASK',
          'a',
          {'keyword': 'x'},
        ],
        fetch: fetch,
      );
      final same = reader.read(
        query: [
          'TASK',
          'a',
          {'keyword': 'x'},
        ],
        fetch: fetch,
      );
      final b = reader.read(
        query: [
          'TASK',
          'b',
          {'keyword': 'x'},
        ],
        fetch: () async => {'OPEN': 2},
      );
      expect(identical(a, same), isTrue);
      expect(reads, 1);
      gate.complete({'OPEN': 7});
      expect(await a, {'OPEN': 7});
      expect(await b, {'OPEN': 2});
      expect(
        await reader.read(
          query: [
            'TASK',
            'a',
            {'keyword': 'x'},
          ],
          fetch: fetch,
        ),
        {'OPEN': 7},
      );
      expect(reads, 1);
      expect(
        await reader.read(
          query: [
            'TASK',
            'a',
            {'keyword': 'x'},
          ],
          force: true,
          fetch: () async => {'OPEN': 8},
        ),
        {'OPEN': 8},
      );
    },
  );
  test(
    'retired readers reject late responses and failed reads can retry',
    () async {
      final reader = ScopedCategoryRead();
      await expectLater(
        reader.read<int>(
          query: 'a',
          fetch: () async => throw StateError('offline'),
        ),
        throwsStateError,
      );
      expect(await reader.read(query: 'a', fetch: () async => 2), 2);
      final gate = Completer<int>();
      final old = reader.read(query: 'b', fetch: () => gate.future);
      final rejected = expectLater(
        old,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'shared owner retirement',
            'SESSION_CHANGED',
          ),
        ),
      );
      reader.dispose();
      gate.complete(3);
      await rejected;
    },
  );
}

class _CategoryAdapter implements HttpClientAdapter {
  final gate = Completer<ResponseBody>();
  int requests = 0;
  bool cancelled = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests++;
    cancelFuture?.then((_) => cancelled = true);
    return gate.future;
  }

  @override
  void close({bool force = false}) {}
}
