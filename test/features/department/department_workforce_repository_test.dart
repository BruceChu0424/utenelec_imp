import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';

void main() {
  test('workforceOverview 请求组织统计端点并解析空离职率', () async {
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
              data: {
                'organizationId': 'dept-1',
                'organizationName': '财税部',
                'organizationLevel': '一级部门',
                'asOf': '2026-07-31',
                'periodStart': '2025-07-31',
                'periodMonths': 12,
                'directCurrentEmployees': 4,
                'currentEmployees': 4,
                'activeEmployees': 3,
                'probationEmployees': 1,
                'onLeaveEmployees': 0,
                'hiredEmployees': 1,
                'rehiredEmployees': 0,
                'departedEmployees': 0,
                'transferInEmployees': 0,
                'transferOutEmployees': 0,
                'openingHeadcount': 3,
                'averageHeadcount': 3.5,
                'turnoverRatePct': null,
                'netChange': 1,
                'descendantDepartmentCount': 0,
                'contractExpiringIn30Days': 0,
                'probationEndingIn30Days': 1,
                'turnoverRateApproximate': true,
                'historyCoverageComplete': true,
                'missingHistoryRecords': 0,
                'dataQualityNote': '估算口径',
              },
            ),
          );
        },
      ),
    );

    final repository = DioDepartmentRepository(ApiClient(dio));
    final overview = await repository.workforceOverview('dept-1');

    expect(captured.method, 'GET');
    expect(captured.path, '/org/departments/dept-1/workforce-overview');
    expect(overview.currentEmployees, 4);
    expect(overview.turnoverRatePct, isNull);
    expect(overview.probationEndingIn30Days, 1);
  });
}
