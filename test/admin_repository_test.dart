import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';

void main() {
  test('listUsers forwards status to server-side pagination', () async {
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
                'page': 2,
                'size': 30,
                'total': 0,
                'totalPages': 0,
              },
            ),
          );
        },
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));
    await repository.listUsers(
      page: 2,
      size: 30,
      search: 'zhang',
      status: 'locked',
    );

    expect(captured.method, 'GET');
    expect(captured.uri.path, '/api/admin/users');
    expect(captured.uri.queryParameters, const {
      'page': '2',
      'size': '30',
      'search': 'zhang',
      'status': 'locked',
    });
  });

  test('resetPassword parses one-time temporaryPassword response', () async {
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
              data: {'temporaryPassword': 'Temp-Only-2026!'},
            ),
          );
        },
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));
    final password = await repository.resetPassword('user-1');

    expect(password, 'Temp-Only-2026!');
    expect(captured.method, 'POST');
    expect(captured.path, '/admin/users/user-1/reset-password');
  });

  test('resetPassword never sends a caller-chosen password', () async {
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
              data: {'temporaryPassword': 'Server-Random-Only-2026!'},
            ),
          );
        },
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));
    final password = await repository.resetPassword('user-1');

    expect(password, 'Server-Random-Only-2026!');
    expect(captured.method, 'POST');
    // ADR-110: 临时密码只由服务端随机生成，请求体不带任何密码字段。
    expect(captured.data, isNull);
  });

  test(
    'provisionCandidatesPage keeps readiness facts and reads one bounded department page',
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
                  'items': [
                    {
                      'employeeId': 'emp-1',
                      'name': '张三',
                      'code': 'UT0001',
                      'departmentName': '生产部',
                      'hasPhone': true,
                    },
                    {
                      'employeeId': 'emp-2',
                      'name': '李四',
                      'code': 'UT0002',
                      'departmentName': null,
                      'hasPhone': false,
                    },
                  ],
                  'page': 2,
                  'size': 100,
                  'total': 6001,
                  'totalPages': 61,
                },
              ),
            );
          },
        ),
      );

      final repository = DioAdminRepository(ApiClient(dio));
      final candidates = await repository.provisionCandidatesPage(
        search: ' 张 ',
        page: 2,
        departmentId: 'department-1',
        includeSubtree: true,
      );

      expect(captured.method, 'GET');
      expect(captured.uri.path, '/api/admin/users/provision-candidates/page');
      expect(captured.uri.queryParameters, const {
        'search': '张',
        'page': '2',
        'size': '100',
        'departmentId': 'department-1',
        'includeSubtree': 'true',
      });
      expect(candidates.totalPages, 61);
      expect(candidates.items, hasLength(2));
      expect(candidates.items.first.employeeId, 'emp-1');
      expect(candidates.items.first.provisionable, isTrue);
      expect(candidates.items.last.provisionable, isFalse);
      expect(candidates.items.last.missingHint, '缺手机号');
    },
  );

  test('resetPassword rejects an empty or missing secret', () async {
    for (final response in <Map<String, dynamic>>[
      const {},
      const {'temporaryPassword': ''},
    ]) {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: response,
            ),
          ),
        ),
      );

      final repository = DioAdminRepository(ApiClient(dio));
      await expectLater(
        repository.resetPassword('user-1'),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('getUserDataScopes parses a raw UUID string array', () async {
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
              data: const ['owner-1', 'owner-2'],
            ),
          );
        },
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));
    final scopes = await repository.getUserDataScopes('user-1', 'goods');

    expect(scopes, const ['owner-1', 'owner-2']);
    expect(captured.method, 'GET');
    expect(captured.path, '/admin/users/user-1/data-scopes?scope=goods');
    expect(captured.uri.queryParameters, const {'scope': 'goods'});
  });

  test('getUserDataScopes accepts an empty array', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: const <String>[],
          ),
        ),
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));

    expect(await repository.getUserDataScopes('user-1', 'client'), isEmpty);
  });

  test('getUserDataScopes rejects a non-string array response', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: const [1],
          ),
        ),
      ),
    );

    final repository = DioAdminRepository(ApiClient(dio));

    await expectLater(
      repository.getUserDataScopes('user-1', 'sales'),
      throwsA(isA<FormatException>()),
    );
  });

  test('updateUserDataScopes sends desired and expected CAS sets', () async {
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
              data: const <String, dynamic>{},
            ),
          );
        },
      ),
    );

    await DioAdminRepository(ApiClient(dio)).updateUserDataScopes(
      'user-1',
      'client',
      const ['owner-2'],
      expectedOwnerEmployeeIds: const ['owner-1'],
    );

    expect(captured.method, 'PUT');
    expect(captured.path, '/admin/users/user-1/data-scopes?scope=client');
    expect(captured.data, const {
      'ownerEmployeeIds': ['owner-2'],
      'expectedOwnerEmployeeIds': ['owner-1'],
    });
  });
}
