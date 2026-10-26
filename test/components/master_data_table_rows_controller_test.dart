import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/master_data_table_rows_controller.dart';

void main() {
  testWidgets('typed adaptation forwards reading intent and real layout wait', (
    tester,
  ) async {
    final rows = MasterDataTableRowsController<String>();
    final adapted = rows.adapt<int>((items) => items.map((item) => '$item'));
    final owner = Object();
    final layout = Completer<void>();
    var intents = 0;
    adapted.bindPagination(
      owner,
      () async {},
      false,
      currentPage: 79,
      totalPages: 120,
      onScrollIntent: () => intents++,
      settlePresentation: () => layout.future,
    );
    adapted.update([79]);
    expect(rows.items, ['79']);
    rows.noteScrollIntent();
    expect(intents, 1);
    var settled = false;
    final waiting = rows.settled.then((_) => settled = true);
    await tester.pump();
    expect(settled, isFalse);
    layout.complete();
    await waiting;
    expect(settled, isTrue);
    adapted.detachPagination(Object());
    rows.noteScrollIntent();
    expect(intents, 2, reason: 'a different owner cannot detach the adapter');
    adapted.detachPagination(owner);
    rows.noteScrollIntent();
    expect(intents, 2);
    await rows.settled;
    await tester.pump();
    expect(rows.pagination.value, isNull);
  });
}
