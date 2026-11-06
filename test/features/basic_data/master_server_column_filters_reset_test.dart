import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_server_column_filters.dart';

void main() {
  for (final boundary in ['reset', 'owner']) {
    test(
      'an eager facet HTTP read is cancelled on $boundary rather than merely rejecting its late buckets',
      () async {
        final filters = MasterServerColumnFilters();
        final dio = Dio();
        final api = ApiClient(dio);
        final entered = Completer<CancelToken>();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              entered.complete(options.cancelToken!);
              options.cancelToken!.whenCancel.then(handler.reject);
            },
          ),
        );
        var owner = true, callbacks = 0;
        final pending = filters.loadFacets(
          () async {
            await api.get('/facet-lifecycle-fixture');
            return {
              'billNo': const [MasterFacetBucket(value: 'old', count: 1)],
            };
          },
          isCurrent: () => owner,
          onLoaded: () => callbacks++,
        );
        final cancellation = await entered.future;
        if (boundary == 'reset') {
          filters.reset();
        } else {
          owner = false;
        }
        await cancellation.whenCancel;
        await pending;
        expect(cancellation.isCancelled, true);
        expect(filters.buckets, isEmpty);
        expect(callbacks, 0);
      },
    );
  }
  test(
    'reset prevents an old document facet from reappearing without a new request',
    () async {
      final filters = MasterServerColumnFilters();
      final gate = Completer<Map<String, List<MasterFacetBucket>>>();
      var callbacks = 0;
      final pending = filters.loadFacets(
        () => gate.future,
        onLoaded: () => callbacks++,
      );
      filters.setValue('billNo', 'old-bill');
      filters.reset();
      gate.complete({
        'billNo': const [
          MasterFacetBucket(
            value: 'private-old-bill',
            label: 'Old bill',
            count: 1,
          ),
        ],
      });
      await pending;
      expect(filters.values, isEmpty);
      expect(filters.buckets, isEmpty);
      expect(callbacks, 0);
    },
  );
}
