import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Epoch extends ExportContextEpoch {
  @override int build() => 0;
}
class _View extends ConsumerStatefulWidget {
  const _View({super.key});
  @override ConsumerState<_View> createState()=>_ViewState();
}
class _ViewState extends ConsumerState<_View> with ScopedPagedReadViewMixin<_View> {
  String query='A';
  Future<PagedResult<int>> read() => readScopedPage<int>(
    1,
    query:[query],
    currentQuery:()=>[query],
    fetchPage:(_) async=>const PagedResult<int>(items:[101],page:1,size:1,total:1,totalPages:1),
  );
  @override Widget build(BuildContext context)=>const SizedBox();
}

void main() {
  for(final retire in ['unchanged','query-only','explicit-invalidate']) {
    testWidgets('same event immediate result $retire', (tester) async {
      final container=ProviderContainer(overrides:[exportContextEpochProvider.overrideWith(_Epoch.new)]);
      addTearDown(container.dispose);
      final key=GlobalKey<_ViewState>();
      await tester.pumpWidget(UncontrolledProviderScope(container:container,child:MaterialApp(home:_View(key:key))));
      final state=key.currentState!;
      await tester.runAsync(() async {
        final pending=state.read();
        if(retire!='unchanged')state.query='B';
        if(retire=='explicit-invalidate')state.invalidateScopedPageReads();
        if(retire=='unchanged') {
          final result=await pending;
          expect(result.items,[101]);
        } else {
          await expectLater(pending,throwsA(isA<UiWorkCancelled>()),
              reason:'currentQuery is required specifically to retire results for a changed live query');
        }
      });
    });
  }
}
