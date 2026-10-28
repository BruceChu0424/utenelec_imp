import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/payroll/repositories/payroll_repository.dart';
import 'package:uten_imp/features/hr_task/repositories/hr_task_repository.dart';

void main() {
  test(
    'personal salary API preserves the original status and exact typed header expression',
    () async {
      final requests = <RequestOptions>[];
      final dio = _api(requests);
      await DioPayrollRepository(ApiClient(dio)).listSlips(
        status: 'UNVIEWED',
        page: 2,
        columnSearch: {
          'search.netIncome': '>=9007199254740993.0001',
          'search.period': '2026-10',
        },
        sort: 'netIncome',
        order: 'desc',
      );
      expect(requests.single.path, '/payroll/slips');
      expect(
        requests.single.queryParameters,
        containsPair('status', 'UNVIEWED'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.netIncome', '>=9007199254740993.0001'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.period', '2026-10'),
      );
      expect(requests.single.queryParameters, containsPair('page', 2));
      expect(
        requests.single.queryParameters,
        containsPair('sort', 'netIncome'),
      );
    },
  );
  test(
    'celebration history keeps its authorized type while forwarding snapshot and exact date filters',
    () async {
      final requests = <RequestOptions>[];
      await HrTaskRepository(ApiClient(_api(requests))).celebrationHistory(
        type: 'birthday',
        page: 2,
        columnSearch: {
          'search.employeeName': '王',
          'search.publishedAt': '2026-10-01..2026-10-28',
        },
        sort: 'publishedAt',
        ascending: false,
      );
      expect(requests.single.path, '/org/hr-tasks/celebrations/history');
      expect(requests.single.queryParameters, containsPair('type', 'birthday'));
      expect(
        requests.single.queryParameters,
        containsPair('search.employeeName', '王'),
      );
      expect(
        requests.single.queryParameters,
        containsPair('search.publishedAt', '2026-10-01..2026-10-28'),
      );
      expect(requests.single.queryParameters, containsPair('order', 'desc'));
    },
  );
}

Dio _api(List<RequestOptions> requests) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: {
              'items': <Object?>[],
              'page': 2,
              'size': 20,
              'total': 0,
              'totalPages': 0,
            },
          ),
        );
      },
    ),
  );
  return dio;
}
