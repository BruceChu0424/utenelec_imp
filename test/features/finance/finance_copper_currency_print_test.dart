import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/report/shared/report_print_preview.dart';

class _CopperApi extends ApiClient {
  _CopperApi() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'page': 1,
    'size': 500,
    'total': 2,
    'totalPages': 1,
    'columns': [
      {'key': 'rowNo', 'label': '序号', 'type': 'int'},
      {'key': 'goodsName', 'label': '产品名称', 'type': 'text'},
      {'key': 'unit', 'label': '单位', 'type': 'text'},
      {'key': 'qty', 'label': '数量', 'type': 'number', 'unitKey': 'unit'},
      {
        'key': 'price',
        'label': '单价',
        'type': 'money',
        'unitKey': 'currencyCode',
      },
      {
        'key': 'amount',
        'label': '金额',
        'type': 'money',
        'unitKey': 'currencyCode',
      },
    ],
    'rows': [
      for (final currency in ['USD', '人民币'])
        {
          'rowNo': currency == 'USD' ? 1 : 2,
          'goodsName': '匿名铜柱',
          'unit': '只',
          'qty': '3',
          'price': '100',
          'amount': '12345678901234.123456789012345678901234',
          'currencyCode': currency,
          '__showCurrencyInOriginal': true,
        },
    ],
  };
}

void main() {
  test(
    'original six-column print snapshot preserves per-row currency without changing source numbers',
    () async {
      final table = await loadBoundedReportPrintPreview(
        api: _CopperApi(),
        endpointOf: () => '/finance/reports/cost/copper-fee',
        queryOf: () => {'layout': 'template'},
        isCurrent: () => true,
        includeValueUnits: false,
      );
      expect(table.headers, ['序号', '产品名称', '单位', '数量', '单价', '金额']);
      expect(table.rows[0].sublist(2, 5), ['只', '3', '100.00 美金']);
      expect(table.rows[1].sublist(2, 5), ['只', '3', '100.00 元']);
      expect(table.rows[0][5], '12345678901234.123456789012345678901234 美金');
      expect(table.rows[1][5], '12345678901234.123456789012345678901234 元');
      expect(
        table.factValues![0]['amount'],
        '12345678901234.123456789012345678901234',
      );
    },
  );
}
