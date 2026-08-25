import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';
import 'package:uten_imp/shared/handover/data_handover_repository.dart';

void main() {
  test('employee preview sends optional successor', () async {
    late RequestOptions captured;
    final repository = DataHandoverRepository(
      _api((request) {
        captured = request;
        return _previewResponse(request);
      }),
    );

    final preview = await repository.employeePreview(
      'source-1',
      successorEmployeeId: 'target-1',
    );

    expect(captured.method, 'GET');
    expect(captured.path, '/org/employees/source-1/handover-preview');
    expect(captured.uri.queryParameters, {'successorEmployeeId': 'target-1'});
    expect(preview.targetEmployeeId, 'target-1');
  });

  test('admin preview sends explicit selected scopes', () async {
    late RequestOptions captured;
    final repository = DataHandoverRepository(
      _api((request) {
        captured = request;
        return _previewResponse(request);
      }),
    );

    await repository.adminPreview(
      sourceEmployeeId: 'source-1',
      targetEmployeeId: 'target-1',
      scopes: {'sales', 'client'},
    );

    expect(captured.path, '/admin/data-handovers/preview');
    expect(captured.queryParameters['sourceEmployeeId'], 'source-1');
    expect(captured.queryParameters['targetEmployeeId'], 'target-1');
    expect(captured.queryParameters['scopes'], ['client', 'sales']);
  });

  test('manual execute posts request id, reason and effective date', () async {
    late RequestOptions captured;
    final repository = DataHandoverRepository(
      _api((request) {
        captured = request;
        return Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: const {
            'id': 'handover-1',
            'sequenceNo': 12,
            'requestId': 'request-1',
            'sourceEmployeeId': 'source-1',
            'targetEmployeeId': 'target-1',
            'mode': 'MANUAL',
            'status': 'COMPLETED',
            'scopes': ['client'],
            'resultSummary': {'client.owner': 4},
            'replayed': false,
          },
        );
      }),
    );

    final result = await repository.execute(
      const DataHandoverRequest(
        requestId: 'request-1',
        sourceEmployeeId: 'source-1',
        targetEmployeeId: 'target-1',
        scopes: {'client'},
        reason: '人工交接',
        effectiveDate: '2026-08-25',
      ),
    );

    expect(captured.method, 'POST');
    expect(captured.path, '/admin/data-handovers');
    final body = captured.data as Map<String, dynamic>;
    expect(body['requestId'], 'request-1');
    expect(body['reason'], '人工交接');
    expect(result.sequenceNo, 12);
  });
}

ApiClient _api(Response<dynamic> Function(RequestOptions request) response) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(response(request)),
    ),
  );
  return ApiClient(dio);
}

Response<dynamic> _previewResponse(RequestOptions request) => Response<dynamic>(
  requestOptions: request,
  statusCode: 200,
  data: const {
    'sourceEmployeeId': 'source-1',
    'targetEmployeeId': 'target-1',
    'scopes': ['client', 'sales'],
    'items': <dynamic>[],
    'hasBlockers': false,
    'requiresTarget': true,
    'total': 0,
  },
);
