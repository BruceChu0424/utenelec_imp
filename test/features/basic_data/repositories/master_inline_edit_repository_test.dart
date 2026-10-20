import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/master_inline_edit_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/master_operation_history_repository.dart';

void main() {
  test(
    'flat inline request sends only changes and exact original comparisons',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: <String, dynamic>{},
                ),
              );
            },
          ),
        );
      await MasterInlineEditRepository(ApiClient(dio)).save(
        'units',
        'unit-1',
        changes: {'name': 'Carton'},
        expected: {'name': 'Box'},
      );
      expect(requests.single.method, 'PATCH');
      expect(requests.single.path, '/master/inline-edit/units/unit-1');
      expect(requests.single.data, {
        'changes': {'name': 'Carton'},
        'expected': {'name': 'Box'},
      });
    },
  );

  test(
    'party patch sends only changed fields and its original version',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: <String, dynamic>{},
                ),
              );
            },
          ),
        );
      await MasterInlineEditRepository(
        ApiClient(dio),
      ).saveParty('clients', 'client-1', {'name': 'After'}, expectedVersion: 7);
      expect(requests.single.method, 'PATCH');
      expect(requests.single.path, '/master/inline-edit/clients/client-1');
      expect(requests.single.data, {
        'expected': {'version': 7},
        'changes': {'name': 'After'},
      });
    },
  );

  test(
    'party patch rejects an invalid authority before issuing any request',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: <String, dynamic>{},
                ),
              );
            },
          ),
        );
      await expectLater(
        MasterInlineEditRepository(ApiClient(dio)).saveParty(
          'suppliers',
          'supplier-1',
          {'name': 'After'},
          expectedVersion: 1,
          isCurrent: () => false,
        ),
        throwsStateError,
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'generic history retains entity scope and versioned undo redo',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: {'entries': <dynamic>[], 'events': <dynamic>[]},
                ),
              );
            },
          ),
        );
      final history = ApiMasterOperationHistoryRepository(
        ApiClient(dio),
        'colors',
      );
      await history.list();
      await history.undo('operation-1', expectedVersion: 3);
      await history.redo('operation-1', expectedVersion: 4);
      expect(requests.first.queryParameters, {'entityType': 'colors'});
      expect(requests[1].uri.queryParameters, {'entityType': 'colors'});
      expect(requests[1].data, {'expectedVersion': 3});
      expect(
        requests.last.uri.path,
        '/master/operation-history/operation-1/redo',
      );
      expect(requests.last.data, {'expectedVersion': 4});
    },
  );
}
