import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_server_column_filters.dart';

void main() {
  test(
    'reset prevents an old document facet from reappearing without a new request',
    () async {
      final filters = MasterServerColumnFilters();
      final gate = Completer<Map<String, List<MasterFacetBucket>>>();
      var callbacks = 0;
      final pending = filters.loadFacets(
        () => gate.future,
        onLoaded: () => callbacks++,
      );
      filters.setValue('billNo', 'old-bill');
      filters.reset();
      gate.complete({
        'billNo': const [
          MasterFacetBucket(
            value: 'private-old-bill',
            label: 'Old bill',
            count: 1,
          ),
        ],
      });
      await pending;
      expect(filters.values, isEmpty);
      expect(filters.buckets, isEmpty);
      expect(callbacks, 0);
    },
  );
}
