import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/pricing/price_analysis_models.dart';

// An offset-exact server over one fixed dataset: page `p` of size `s` returns
// observations (p-1)*s … min(p*s, total)-1 with unique identities, echoing
// page/size/total and totalPages = ceil(total / size).
PriceHistoryTableResult _page(
  int page,
  String scope, {
  int size = 100,
  int total = 2,
}) => PriceHistoryTableResult.fromResponse({
  'observations': [
    for (
      var index = (page - 1) * size;
      index < page * size && index < total;
      index++
    )
      {
        'sourceType': 'PURCHASE_ORDER',
        'sourceId': 'order-$index',
        'sourceItemId': 'line-$index',
      },
  ],
  'page': page,
  'size': size,
  'total': total,
  'totalPages': (total + size - 1) ~/ size,
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
      final first = _page(1, 'same-owner', size: 1);
      final next = _page(2, 'same-owner', size: 1);
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
      // 60 rows need a continuation batch after the progressive first batch;
      // the server's read scope changes between them.
      final requests = <(int, int)>[];
      final reportedHasMore = <bool>[];
      await expectLater(
        loadCompletePagedResult<PriceObservation>(
          isCurrent: () => true,
          idOf: (row) => row.identity,
          loadPage: (page, size) async {
            requests.add((page, size));
            return _page(
              page,
              page == 1 ? 'owner-a' : 'owner-b',
              size: size,
              total: 60,
            );
          },
          onBatch: (rows, total, hasMore) => reportedHasMore.add(hasMore),
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'scope drift',
            'SNAPSHOT_CHANGED',
          ),
        ),
      );
      // The drift is caught on the continuation batch itself: (1,50) (2,50).
      // Only the first batch was ever reported, still incomplete; the drifted
      // rows never joined and no complete list was published.
      expect(requests, [(1, 50), (2, 50)]);
      expect(reportedHasMore, [true]);
    },
  );
}
