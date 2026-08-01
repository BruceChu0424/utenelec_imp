import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/models/finance_asset_models.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_workbench_repository.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_ui.dart';

void main() {
  test('form length guards match the persisted asset columns', () {
    expect(validateMaxLength('x'.padRight(160, 'x'), 160, '序列号'), isNull);
    expect(validateMaxLength('x'.padRight(161, 'x'), 160, '序列号'), isNotNull);
    expect(validateMaxLength('x'.padRight(300, 'x'), 300, '地点'), isNull);
    expect(
      validateRequiredMaxLength('x'.padRight(161, 'x'), 160, '政策名称'),
      isNotNull,
    );
  });

  test(
    'list forwards every filter and keeps BigDecimal values as strings',
    () async {
      late RequestOptions captured;
      final repository = ApiFinanceAssetWorkbenchRepository(
        _api((request) {
          captured = request;
          return {
            'items': [
              {
                'id': 'asset-1',
                'code': 'FA-001',
                'name': '注塑机',
                'status': 'ACTIVE',
                'originalValue': '9007199254740991.23',
                'netBookValue': '8000000000000000.11',
                'allowedActions': <String>[],
              },
            ],
            'page': 4,
            'size': 100,
            'total': 301,
            'totalPages': 4,
          };
        }),
      );

      final page = await repository.list(
        FinanceAssetLedger.fixedAsset,
        query: const FinanceAssetQuery(
          page: 4,
          size: 100,
          q: '注塑',
          status: 'ACTIVE',
          categoryId: 'category-1',
          departmentId: 'department-1',
        ),
      );

      expect(captured.path, '/finance/fixed-assets');
      expect(captured.queryParameters, {
        'page': 4,
        'size': 100,
        'q': '注塑',
        'status': 'ACTIVE',
        'categoryId': 'category-1',
        'departmentId': 'department-1',
      });
      expect(page.total, 301);
      expect(page.items.single.originalValue, '9007199254740991.23');
      expect(page.items.single.netBookValue, '8000000000000000.11');
    },
  );

  test(
    'detail reads the nested summary and top-level action contract',
    () async {
      final repository = ApiFinanceAssetWorkbenchRepository(
        _api(
          (_) => {
            'summary': {
              'id': 'asset-1',
              'code': 'FA-001',
              'name': '注塑机',
              'status': 'DRAFT',
              'originalValue': '120000.00',
              'netBookValue': '120000.00',
            },
            'allowedActions': ['EDIT', 'SUBMIT'],
            'books': <Object?>[],
            'schedule': <Object?>[],
            'approvalSteps': <Object?>[],
            'events': <Object?>[],
            'voucherNumbers': <Object?>[],
            'documentReferences': <Object?>[],
          },
        ),
      );

      final detail = await repository.detail(
        FinanceAssetLedger.fixedAsset,
        'asset-1',
      );

      expect(detail.summary.id, 'asset-1');
      expect(detail.summary.code, 'FA-001');
      expect(detail.summary.allowedActions, {'EDIT', 'SUBMIT'});
    },
  );

  test(
    'deferred draft preserves structured source and responsibility fields',
    () async {
      final requests = <RequestOptions>[];
      final repository = ApiFinanceAssetWorkbenchRepository(
        _api((request) {
          requests.add(request);
          return {
            'id': 'deferred-1',
            'status': 'DRAFT',
            'version': 0,
            'allowedActions': ['EDIT', 'DELETE', 'SUBMIT'],
          };
        }),
      );

      await repository.createDraft(
        FinanceAssetLedger.deferredExpense,
        const FinanceAssetDraftInput(
          ledger: FinanceAssetLedger.deferredExpense,
          categoryId: null,
          name: '厂房装修费',
          amount: '100000.25',
          usefulMonths: 36,
          startPeriod: '2026-09',
          benefitStartDate: '2026-09-01',
          benefitEndDate: '2029-08-31',
          departmentId: 'department-1',
          responsibleEmployeeId: 'employee-1',
          location: '一号厂房',
          costCenterCode: 'CC-01',
          sourceType: 'CONTRACT',
          sourceId: '11111111-1111-1111-1111-111111111111',
          sourceRef: 'HT-2026-008',
          sourceLineRef: 'LINE-3',
          sourceDocumentDate: '2026-08-01',
        ),
      );

      expect(requests.single.path, '/finance/deferred-expenses');
      expect(requests.single.data, containsPair('totalAmount', '100000.25'));
      expect(requests.single.data, isNot(contains('categoryId')));
      expect(
        requests.single.data,
        containsPair('responsibleEmployeeId', 'employee-1'),
      );
      expect(requests.single.data, isNot(contains('custodianId')));
      expect(requests.single.data, containsPair('sourceType', 'CONTRACT'));
      expect(requests.single.data, containsPair('sourceRef', 'HT-2026-008'));
      expect(requests.single.data, containsPair('sourceLineRef', 'LINE-3'));
    },
  );

  test(
    'workflow, posting and period commands use versioned endpoints',
    () async {
      final requests = <RequestOptions>[];
      final repository = ApiFinanceAssetWorkbenchRepository(
        _api((request) {
          requests.add(request);
          if (request.path.endsWith('/preview')) {
            return {
              'id': 'run-1',
              'status': 'PREVIEWED',
              'token': 'preview-token',
              'itemCount': 1,
              'totalAmount': '321.09',
              'exceptions': <Object?>[],
              'lines': [
                {
                  'objectId': 'asset-1',
                  'code': 'FA-001',
                  'name': '注塑机',
                  'amount': '321.09',
                  'status': 'READY',
                },
              ],
              'version': 2,
            };
          }
          return {
            'id': 'run-1',
            'status': 'POSTED',
            'version': 3,
            'allowedActions': <String>[],
          };
        }),
      );

      final preview = await repository.previewPosting(
        runType: AssetPostingRunType.depreciation,
        period: '2026-08',
        bookType: 'CORPORATE',
      );
      await repository.postPostingRun(
        preview.runId,
        token: preview.token,
        expectedVersion: preview.version,
      );
      await repository.reopenPeriod(
        '2026-08',
        reason: '审计调整',
        expectedVersion: 4,
      );
      await repository.deleteDraft(
        FinanceAssetLedger.fixedAsset,
        'asset-draft',
        expectedVersion: 7,
      );

      expect(preview.lines.single.assetId, 'asset-1');
      expect(requests[0].path, '/finance/asset-posting-runs/preview');
      expect(requests[0].data, {
        'runType': 'DEPRECIATION',
        'period': '2026-08',
        'bookType': 'CORPORATE',
      });
      expect(requests[1].path, '/finance/asset-posting-runs/run-1/post');
      expect(requests[1].data, {
        'token': 'preview-token',
        'expectedVersion': 2,
      });
      expect(requests[2].path, '/finance/asset-periods/2026-08/reopen');
      expect(requests[2].data, {'reason': '审计调整', 'expectedVersion': 4});
      expect(requests[3].method, 'DELETE');
      expect(
        requests[3].path,
        '/finance/fixed-assets/asset-draft?expectedVersion=7',
      );
      expect(requests[3].queryParameters, isEmpty);
    },
  );
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: responder(request),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}
