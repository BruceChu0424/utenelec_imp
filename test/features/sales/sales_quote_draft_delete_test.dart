import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/sales/services/sales_draft_delete.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  int revision = 4;
  bool canDelete = true;
  Map<String, dynamic> extra = {};
  int deletes = 0;
  Map<String, dynamic>? deletedQuery;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'id': 'q',
    'status': 0,
    'writable': true,
    'reviewRevision': revision,
    'allowedActions': [if (canDelete) 'delete'],
    'items': <Object>[],
    ...extra,
  };
  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    deletes++;
    deletedQuery = query;
  }
}

void main() {
  test(
    'sealed or historical orders never enter draft deletion even with stale writable=true',
    () async {
      for (final fields in [
        <String, dynamic>{'historyReadOnly': true},
        <String, dynamic>{'requotedToId': 'new-quote'},
      ]) {
        final api = _Api()..extra = fields;
        final row = SalesDocListItem.fromJson(await api.get('/sales/orders/q'));
        expect(isDeletableSalesDraftRow(row, SalesDocType.order), isFalse);
        await expectLater(
          deleteSalesDraft(
            SalesRepository(api, SalesDocType.order),
            SalesDocType.order,
            'q',
          ),
          throwsA(isA<ApiException>()),
        );
        expect(api.deletes, 0);
      }
    },
  );
  test('delete retains the version selected by the user', () async {
    final api = _Api();
    await deleteSalesDraft(
      SalesRepository(api, SalesDocType.quote),
      SalesDocType.quote,
      'q',
      expectedRevision: 4,
    );
    expect(api.deletedQuery, {'expectedRevision': 4});
  });

  test(
    'changed version and missing selected version are rejected before deletion',
    () async {
      for (final selected in [null, 3]) {
        final api = _Api();
        await expectLater(
          deleteSalesDraft(
            SalesRepository(api, SalesDocType.quote),
            SalesDocType.quote,
            'q',
            expectedRevision: selected,
          ),
          throwsA(isA<ApiException>()),
        );
        expect(api.deletedQuery, isNull);
      }
    },
  );

  test(
    'returned or previously submitted quote cannot be deleted as a draft',
    () async {
      final api = _Api()..canDelete = false;
      await expectLater(
        deleteSalesDraft(
          SalesRepository(api, SalesDocType.quote),
          SalesDocType.quote,
          'q',
          expectedRevision: 4,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(api.deletedQuery, isNull);
    },
  );
}
