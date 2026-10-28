import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/quality/repositories/quality_pending_queue_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';

void main() {
  test(
    'complete queue keeps typed headers and the server page metadata',
    () async {
      final api = _QueueApi();
      final result = await QualityPendingQueueRepository(api).query(
        page: 61,
        keyword: '材料 %_ 订单',
        docType: 'SUBCONTRACT',
        status: '委外提交待核对',
        columns: const {
          'search.itemCount': ' >=9007199254740993.0001 ',
          'search.enteredAt': '2026-10-01..2026-10-28',
          'search.party': ' 同名_供应商% ',
          'search.goods': '  ',
          'status': 'ignored-local-filter',
        },
        sort: 'enteredAt',
        ascending: false,
        draftStatuses: const {'iqc:SUBCONTRACT:receipt-601': '提交待核对'},
      );

      expect(api.path, '/quality/pending-disposals/query');
      expect(api.body, {
        'page': 61,
        'size': 10,
        'keyword': '材料 %_ 订单',
        'docType': 'SUBCONTRACT',
        'status': '委外提交待核对',
        'columns': {
          'itemCount': '>=9007199254740993.0001',
          'enteredAt': '2026-10-01..2026-10-28',
          'party': '同名_供应商%',
        },
        'sort': 'enteredAt',
        'order': 'desc',
        'draftStatuses': {'iqc:SUBCONTRACT:receipt-601': '提交待核对'},
      });
      expect(result.page, 61);
      expect(result.total, 1953);
      expect(result.totalPages, 196);
      expect(result.items.single.identity, 'iqc:SUBCONTRACT:receipt-601');
      expect(result.items.single.values['pendingQty'], '2 件 · 3 米');
      expect(result.items.single.payload['receiptId'], 'receipt-601');
      expect(result.facets['status']!.single.count, 1953);
      expect(result.sourceCounts['FQC'], 1302);
    },
  );

  test(
    'receipt metadata uses its identity endpoint beyond the old list cap',
    () async {
      final api = _QueueApi();
      final value = await DioProcurementInspectionRepository(
        api,
      ).pendingReceiptSummary('SUBCONTRACT', 'receipt-601');
      expect(
        api.path,
        '/procurement/inspection/pending-receipts/SUBCONTRACT/receipt-601',
      );
      expect(value!.receiptId, 'receipt-601');
      expect(value.pendingQtyText, '2 件 · 3 米');
      expect(value.goodsCodeSummary, 'G-601');
    },
  );

  test('only an absent pending receipt becomes null', () async {
    final api = _QueueApi()..failure = ApiException('NOT_FOUND', '已完成');
    final repository = DioProcurementInspectionRepository(api);
    expect(
      await repository.pendingReceiptSummary('PURCHASE', 'finished'),
      isNull,
    );
    api.failure = ApiException('FORBIDDEN', '无权读取');
    await expectLater(
      repository.pendingReceiptSummary('PURCHASE', 'hidden'),
      throwsA(
        isA<ApiException>().having((value) => value.code, 'code', 'FORBIDDEN'),
      ),
    );
  });
}

class _QueueApi extends ApiClient {
  _QueueApi() : super(Dio());
  String? path;
  Map<String, dynamic>? body;
  ApiException? failure;

  static const receipt = {
    'receiptType': 'SUBCONTRACT',
    'receiptId': 'receipt-601',
    'billNo': 'WR-0601',
    'itemCount': 2,
    'pendingQtyText': '2 件 · 3 米',
    'goodsCodeSummary': 'G-601',
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    if (failure != null) throw failure!;
    return receipt;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.body = Map<String, dynamic>.from(body! as Map);
    return {
      'items': [
        {
          'source': 'IQC',
          'identity': 'iqc:SUBCONTRACT:receipt-601',
          'kind': 'SUBCONTRACT',
          'status': '委外提交待核对',
          'values': {'pendingQty': '2 件 · 3 米', 'itemCount': 2},
          'payload': receipt,
        },
      ],
      'page': 61,
      'total': 1953,
      'totalPages': 196,
      'facets': {
        'status': [
          {'value': '委外提交待核对', 'label': '委外提交待核对', 'count': 1953},
        ],
      },
      'sourceCounts': {'PURCHASE': 650, 'SUBCONTRACT': 1, 'FQC': 1302},
    };
  }
}
