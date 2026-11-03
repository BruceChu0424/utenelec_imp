import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/models/sales_order_progress.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/shared/paging/prepared_page_read.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  var billNo = 'OLD-SOURCE';
  var reads = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads++;
    return {
      'items': [
        {'id': billNo, 'orderId': billNo, 'billNo': billNo},
      ],
      'page': 1,
      'size': query?['size'] ?? 20,
      'total': 1,
      'totalPages': 1,
    };
  }
}

void main() {
  test(
    'a replacement sales list repository cannot adopt another instance preparation',
    () async {
      final api = _Api();
      final prepared = PreparedPageRead<SalesDocListItem>();
      addTearDown(prepared.dispose);
      final old = SalesRepository(
        api,
        SalesDocType.shipment,
        preparedLists: prepared,
      );
      await old.prepareList(filter: const SalesDocFilter(status: 0));
      api.billNo = 'NEW-SOURCE';
      final next = SalesRepository(
        api,
        SalesDocType.shipment,
        preparedLists: prepared,
      );
      final result = await next.list(
        filter: const SalesDocFilter(status: 0),
        preferPrepared: true,
      );
      expect(result.items.single.billNo, 'NEW-SOURCE');
      expect(api.reads, 2);
    },
  );

  test(
    'a replacement progress repository cannot adopt another instance preparation',
    () async {
      final api = _Api();
      final prepared = PreparedPageRead<SalesOrderProgressRow>();
      addTearDown(prepared.dispose);
      final old = SalesRepository(
        api,
        SalesDocType.order,
        preparedProgress: prepared,
      );
      await old.prepareProgress('DRAFT');
      api.billNo = 'NEW-SOURCE';
      final next = SalesRepository(
        api,
        SalesDocType.order,
        preparedProgress: prepared,
      );
      final result = await next.progress(
        stage: 'DRAFT',
        size: 50,
        preferPrepared: true,
      );
      expect(result.items.single.billNo, 'NEW-SOURCE');
      expect(api.reads, 2);
    },
  );
}
