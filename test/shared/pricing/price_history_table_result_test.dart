import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/pricing/price_analysis_models.dart';

PriceHistoryTableResult _page(int page, String scope) =>
    PriceHistoryTableResult.fromResponse({
      'observations': [
        {
          'sourceType': 'PURCHASE_ORDER',
          'sourceId': 'order-$page',
          'sourceItemId': 'line-$page',
        },
      ],
      'page': page,
      'size': 100,
      'total': 2,
      'totalPages': 2,
      'readScopeVersion': scope,
      'totals': [
        {
          'key': 'qty',
          'label': 'authoritative',
          'type': 'number',
          'groupKey': 'unit',
          'groups': [
            {'unit': 'piece', 'value': '1234.56'},
          ],
        },
      ],
      'facets': {
        'sourceNo': [
          {'value': 'PO-1', 'count': 2},
        ],
      },
      'nullCounts': {'colorName': 1},
    });
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'typed price history preserves authorization and authoritative totals in a complete copy',
    () {
      final first = _page(1, 'same-owner'), next = _page(2, 'same-owner');
      final full = first.withRows(
        [...first.items, ...next.items],
        total: 2,
        totalPages: 1,
      );
      expect(first.readScopeVersion, 'same-owner');
      expect(full.readScopeVersion, first.readScopeVersion);
      expect(full.totals, same(first.totals));
      expect(full.totals.single.groups.single.valueText, '1234.56');
      expect(full.facets, same(first.facets));
      expect(full.facetNullCounts, {'colorName': 1});
      expect(full.items, hasLength(2));
      expect(full.metadata, same(first.metadata));
    },
  );
  test(
    'typed price history rejects mixed read scopes before publishing a complete list',
    () async {
      await expectLater(
        loadCompletePagedResult<PriceObservation>(
          isCurrent: () => true,
          idOf: (row) => row.identity,
          loadPage: (page, size) async =>
              _page(page, page == 1 ? 'owner-a' : 'owner-b'),
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'scope drift',
            'SNAPSHOT_CHANGED',
          ),
        ),
      );
    },
  );
}
