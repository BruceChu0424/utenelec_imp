import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_operation_history_repository.dart';

void main() {
  test(
    'history and versioned undo/redo use the shared server response',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://company.invalid/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'entries': [
                    {
                      'id': 'operation-1',
                      'operationType': 'GOODS_DELETE',
                      'label': '删除货品',
                      'summary': 'G001 socket',
                      'createdAt': '2026-10-16T00:00:00Z',
                      'state': 'UNDONE',
                      'version': 8,
                      'affectedCount': 2,
                      'canUndo': false,
                      'canRedo': true,
                    },
                  ],
                  'events': [
                    {
                      'id': 'event-1',
                      'operationId': 'operation-1',
                      'action': 'UNDO',
                      'operationType': 'GOODS_DELETE',
                      'label': '删除货品',
                      'createdAt': '2026-10-16T01:00:00Z',
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
      final repository = ApiGoodsOperationHistoryRepository(ApiClient(dio));

      final history = await repository.list();
      expect(requests.single.method, 'GET');
      expect(requests.single.path, '/master/goods/history');
      expect(history.entries.single.summary, 'G001 socket');
      expect(history.entries.single.canRedo, isTrue);
      expect(history.events.single.action, 'UNDO');
      expect(history.events.single.operationType, 'GOODS_DELETE');

      await repository.undo('operation-1', expectedVersion: 7);
      expect(requests.last.method, 'POST');
      expect(requests.last.path, '/master/goods/history/operation-1/undo');
      expect(requests.last.data, {'expectedVersion': 7});
      final restored = await repository.redo('operation-1', expectedVersion: 8);
      expect(requests.last.path, '/master/goods/history/operation-1/redo');
      expect(requests.last.data, {'expectedVersion': 8});
      expect(restored.entries.single.version, 8);
      expect(requests, hasLength(3));
    },
  );
}
