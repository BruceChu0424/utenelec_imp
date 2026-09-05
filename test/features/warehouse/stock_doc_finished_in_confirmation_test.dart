import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';

void main() {
  test(
    'repository sends exact warehouse accepted quantities and reason',
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
                data: {
                  'id': 'finished-in-1',
                  'docType': 'FINISHED_IN',
                  'status': 1,
                  'productionLinked': true,
                  'items': [
                    {
                      'id': 'line-1',
                      'qty': 6,
                      'reportedQty': 10,
                      'sourceDailyReportItemId': 'report-line-1',
                    },
                  ],
                },
              ),
            );
          },
        ),
      );
      final repository = StockDocRepository(
        ApiClient(dio),
        StockDocType.finishedIn,
      );

      final detail = await repository.confirmFinishedInbound(
        'finished-in-1',
        const [
          {'itemId': 'line-1', 'acceptedQty': 6},
        ],
        'finished-confirm-key-0001',
        varianceReason: ' 本次实物只交接 6 件 ',
      );

      expect(captured.method, 'POST');
      expect(captured.path, '/stock/docs/finished-in-1/finished-in/confirm');
      expect(captured.data, {
        'idempotencyKey': 'finished-confirm-key-0001',
        'lines': [
          {'itemId': 'line-1', 'acceptedQty': 6},
        ],
        'varianceReason': '本次实物只交接 6 件',
      });
      expect(detail.items.single.reportedQty, 10);
      expect(detail.items.single.qty, 6);
      expect(detail.items.single.sourceDailyReportItemId, 'report-line-1');
    },
  );

  test(
    'warehouse page exposes the dedicated acceptance wording and action',
    () {
      final source = File(
        'lib/features/warehouse/pages/stock_doc_detail_page.dart',
      ).readAsStringSync();

      expect(source, contains('确认成品实收数量'));
      expect(source, contains('已审核报工或 FQC PASS 形成的待点收上限'));
      expect(source, contains("label: '待点收上限'"));
      // 说明收进标签旁 ⓘ（fieldLabel 约定），不再 labelText+框下常驻文字。
      expect(source, contains('fieldLabel('));
      expect(source, contains("'仓库实收'"));
      expect(source, contains("'少收差异原因'"));
      expect(source, contains('少收时必须填写差异原因'));
      expect(source, contains("label: const Text('确认实收并入库')"));
      expect(source, contains('.confirmFinishedInbound('));
    },
  );

  test('production finished-in reverse uses the compensating endpoint', () {
    final repository = File(
      'lib/features/warehouse/repositories/stock_doc_repository.dart',
    ).readAsStringSync();
    final page = File(
      'lib/features/warehouse/pages/stock_doc_detail_page.dart',
    ).readAsStringSync();

    expect(repository, contains('/finished-in/reverse'));
    expect(repository, contains('reverseFinishedInbound'));
    expect(page, contains('repository.reverseFinishedInbound(widget.id)'));
    expect(page, contains('按原实收量重建待点收草稿'));
  });

  test(
    'production DRAW sends atomic first issue and audited cancellation',
    () async {
      final captured = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'id': 'draw-1',
                  'docType': 'DRAW',
                  'status': 1,
                  'productionLinked': true,
                  'items': const <Map<String, dynamic>>[],
                },
              ),
            );
          },
        ),
      );
      final repository = StockDocRepository(ApiClient(dio), StockDocType.draw);
      const lines = [
        {'itemId': 'draw-line-1', 'qty': 3},
      ];

      await repository.approveAndIssue(
        'draw-1',
        lines,
        'draw-first-issue-key-0001',
      );
      await repository.reverseIssue(
        'draw-1',
        lines,
        'draw-cancel-issue-key-0001',
        '本轮实物交接取消',
      );

      expect(captured, hasLength(2));
      expect(captured.first.method, 'POST');
      expect(captured.first.path, '/stock/docs/draw-1/approve-and-issue');
      expect(captured.first.data, {
        'lines': lines,
        'idempotencyKey': 'draw-first-issue-key-0001',
      });
      expect(captured.last.method, 'POST');
      expect(captured.last.path, '/stock/docs/draw-1/issue/reverse');
      expect(captured.last.data, {
        'lines': lines,
        'idempotencyKey': 'draw-cancel-issue-key-0001',
        'reason': '本轮实物交接取消',
      });
    },
  );
}
