import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test(
    'a 503 does not discard successful dictionaries and only the failed dictionary retries',
    () async {
      final calls = <String, int>{};
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final count = calls.update(
                options.path,
                (value) => value + 1,
                ifAbsent: () => 1,
              );
              if (options.path == ApiEndpoints.unitsDict && count == 1) {
                handler.reject(
                  DioException.badResponse(
                    statusCode: 503,
                    requestOptions: options,
                    response: Response(
                      requestOptions: options,
                      statusCode: 503,
                    ),
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: [
                      if (options.path.endsWith('/lookup'))
                        for (final id
                            in (options.queryParameters['ids'] as String).split(
                              ',',
                            ))
                          {'id': id, 'name': 'available', 'status': '使用'}
                      else
                        {'id': options.path, 'name': 'available'},
                    ],
                  ),
                );
              }
            },
          ),
        );
      final service = MasterNameService(ApiClient(dio));
      await service.ensureLoaded();
      expect(service.warehouse(ApiEndpoints.warehousesDict), 'available');
      await service.loadSupplierNames([ApiEndpoints.suppliersDict]);
      expect(service.supplier(ApiEndpoints.suppliersDict), 'available');
      expect(service.unit(ApiEndpoints.unitsDict), '—');
      await service.ensureLoaded();
      expect(service.unit(ApiEndpoints.unitsDict), 'available');
      expect(calls[ApiEndpoints.unitsDict], 2);
      expect(
        calls.entries
            .where((entry) => entry.key != ApiEndpoints.unitsDict)
            .every((entry) => entry.value == 1),
        isTrue,
      );
    },
  );

  test(
    'concurrent callers share each request and sales client failures recover independently',
    () async {
      final api = _DeferredApi();
      final service = SalesMasterNameService(api);
      final first = Future.wait([
        service.ensureLoaded(),
        service.loadClientNames(['client']),
      ]);
      final second = Future.wait([
        service.ensureLoaded(),
        service.loadClientNames(['client']),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(api.requests, hasLength(5));
      for (final request in List.of(api.requests)) {
        if (request.path == '/master/clients/lookup') {
          request.result.completeError(StateError('temporary client failure'));
        } else {
          request.result.complete([
            {'id': 'id', 'name': 'retained'},
          ]);
        }
      }
      await Future.wait([first, second]);
      expect(service.warehouse('id'), 'retained');
      final retry = service.loadClientNames(['client']);
      await Future<void>.delayed(Duration.zero);
      expect(api.requests, hasLength(6));
      expect(api.requests.last.path, '/master/clients/lookup');
      api.requests.last.result.complete([
        {'id': 'client', 'name': 'recovered'},
      ]);
      await retry;
      expect(service.client('client'), 'recovered');
    },
  );

  test(
    'old session completion cannot populate the new service instance',
    () async {
      final api = _DeferredApi();
      final identity = StateProvider<String>((ref) => 'A');
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          masterDataSessionKeyProvider.overrideWith(
            (ref) => ref.watch(identity),
          ),
        ],
      );
      addTearDown(container.dispose);
      final first = container.read(masterNameServiceProvider);
      final firstLoad = Future.wait([
        first.ensureLoaded(),
        first.loadSupplierNames(['shared']),
      ]);
      await Future<void>.delayed(Duration.zero);
      container.read(identity.notifier).state = 'B';
      final second = container.read(masterNameServiceProvider);
      expect(identical(first, second), isFalse);
      final secondLoad = Future.wait([
        second.ensureLoaded(),
        second.loadSupplierNames(['shared']),
      ]);
      await Future<void>.delayed(Duration.zero);
      for (final request in api.requests.skip(6)) {
        request.result.complete([
          {'id': 'shared', 'name': 'B'},
        ]);
      }
      await secondLoad;
      for (final request in api.requests.take(6)) {
        request.result.complete([
          {'id': 'shared', 'name': 'A'},
        ]);
      }
      await firstLoad;
      expect(second.warehouse('shared'), 'B');
      expect(second.supplier('shared'), 'B');
      expect(
        first.warehouse('shared'),
        '—',
        reason: 'A disposed identity cannot repopulate its old dictionary',
      );
    },
  );
}

class _Request {
  _Request(this.path);
  final String path;
  final result = Completer<List<Map<String, dynamic>>>();
}

class _DeferredApi extends ApiClient {
  _DeferredApi() : super(Dio());
  final requests = <_Request>[];
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) {
    final request = _Request(path);
    requests.add(request);
    return request.result.future;
  }
}
