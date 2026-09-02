import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/client_access_models.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';

void main() {
  test('client access GET parses owner, viewers and CAS version', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: const {
                'clientId': 'client-1',
                'ownerEmployeeId': 'owner-1',
                'ownerEmployeeName': '负责人甲',
                'accessVersion': 4,
                'viewers': [
                  {'employeeId': 'viewer-1', 'name': '协同人乙'},
                ],
              },
            ),
          );
        },
      ),
    );

    final result = await DioClientRepository(ApiClient(dio)).access('client-1');

    expect(captured.method, 'GET');
    expect(captured.path, '/master/clients/client-1/access');
    expect(result.accessVersion, 4);
    expect(result.ownerEmployeeName, '负责人甲');
    expect(result.viewers.single.employeeId, 'viewer-1');
  });

  test(
    'client access PUT sends exact owner/viewer/version/reason body',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const {
                  'clientId': 'client-1',
                  'ownerEmployeeId': 'owner-2',
                  'ownerEmployeeName': '负责人丙',
                  'accessVersion': 5,
                  'viewers': <dynamic>[],
                },
              ),
            );
          },
        ),
      );

      final result = await DioClientRepository(ApiClient(dio)).updateAccess(
        'client-1',
        const ClientAccessUpdate(
          ownerEmployeeId: 'owner-2',
          viewerEmployeeIds: ['viewer-2'],
          expectedAccessVersion: 4,
          reason: '客户交接',
        ),
      );

      expect(captured.method, 'PUT');
      expect(captured.path, '/master/clients/client-1/access');
      expect(captured.data, {
        'ownerEmployeeId': 'owner-2',
        'viewerEmployeeIds': ['viewer-2'],
        'expectedAccessVersion': 4,
        'reason': '客户交接',
      });
      expect(result.accessVersion, 5);
    },
  );

  test(
    'client list defaults to excluding legacy finance placeholders',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const {
                  'items': <dynamic>[],
                  'page': 1,
                  'size': 20,
                  'total': 0,
                  'totalPages': 0,
                },
              ),
            );
          },
        ),
      );

      await DioClientRepository(ApiClient(dio)).list('category-1');
      expect(captured.queryParameters['excludeLegacyFinanceStub'], isTrue);
      expect(captured.queryParameters['selectableOnly'], isFalse);
    },
  );

  test(
    'internal reconciliation can explicitly include legacy placeholders',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: const {
                  'items': <dynamic>[],
                  'page': 1,
                  'size': 20,
                  'total': 0,
                  'totalPages': 0,
                },
              ),
            );
          },
        ),
      );

      await DioClientRepository(ApiClient(dio))
          .search('legacy', excludeLegacyFinanceStub: false);
      expect(captured.queryParameters['excludeLegacyFinanceStub'], isFalse);
      expect(captured.queryParameters['selectableOnly'], isFalse);
    },
  );

  test('picker search requests server-side selectable pagination', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: const {
                'items': <dynamic>[],
                'page': 1,
                'size': 100,
                'total': 0,
                'totalPages': 0,
              },
            ),
          );
        },
      ),
    );

    await DioClientRepository(ApiClient(dio))
        .search('客户', size: 100, selectableOnly: true);

    expect(captured.path, '/master/clients');
    expect(captured.queryParameters['excludeLegacyFinanceStub'], isTrue);
    expect(captured.queryParameters['selectableOnly'], isTrue);
    expect(captured.queryParameters['size'], 100);
  });
}
