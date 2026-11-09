import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/inbound_registration_line.dart';
import 'package:uten_imp/features/warehouse/models/production_finished_inbound_task.dart';
import 'package:uten_imp/features/warehouse/widgets/production_finished_inbound_tasks_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _total = 120;

Map<String, dynamic> _task(int index, {required bool registration}) => {
  'taskStage': registration ? 'ARRIVAL_REGISTRATION' : 'FINAL_COUNT',
  'taskId': 'task-$index',
  'reportId': registration ? 'rep-$index' : null,
  'documentId': registration ? null : 'doc-$index',
  'documentNo': 'CP2026090100$index',
  'documentDate': '2026-09-01',
  'warehouseId': 'warehouse-1',
  'warehouseName': '一号仓',
  'planNo': 'PP$index',
  'reportNos': 'RB$index',
  'goodsSummary': '面板 $index',
  'lineCount': 1,
  'pendingQty': 5,
  'createdAt': '2026-09-01T02:00:00Z',
  'residualTask': false,
};

/// Offset-exact finished-inbound tasks. While [continuation] is set, every
/// batch after the first waits for it, so the first batch stays a growing
/// prefix of the read.
class _Api extends ApiClient {
  _Api({required this.registration}) : super(Dio());

  final bool registration;
  final queries = <Map<String, dynamic>>[];
  Completer<void>? continuation;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.productionFinishedInboundTasks) {
      return const <String, dynamic>{'items': <Map<String, dynamic>>[]};
    }
    queries.add({...?query});
    final page = query!['page'] as int;
    final size = query['size'] as int;
    if ((page - 1) * size > 0) await continuation?.future;
    return {
      'items': [
        for (var i = (page - 1) * size; i < page * size && i < _total; i++)
          _task(i, registration: registration),
      ],
      'page': page,
      'size': size,
      'total': _total,
      'totalPages': (_total + size - 1) ~/ size,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

Future<ValueNotifier<String>> _mount(WidgetTester tester, _Api api) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final keyword = ValueNotifier('');
  addTearDown(keyword.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const <String>{
          Perm.stockDocView,
          Perm.stockDocApprove,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: keyword,
            builder: (_, value, _) =>
                ProductionFinishedInboundTasksView(keyword: value),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return keyword;
}

MasterDataTableView<ProductionFinishedInboundTask> _table(
  WidgetTester tester,
) => tester.widget(
  find.byKey(const Key('production-finished-inbound-task-table')),
);

/// A new keyword keeps the selection while its read grows: the first batch is
/// on screen and the following batch waits for [_Api.continuation].
Future<void> _growNewQuery(
  WidgetTester tester,
  _Api api,
  ValueNotifier<String> keyword,
) async {
  api.continuation = Completer<void>();
  final reads = api.queries.length;
  keyword.value = 'CP';
  for (var frame = 0; frame < 60; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (api.queries.length >= reads + 2) break;
  }
  await tester.pump(const Duration(milliseconds: 16));
  expect(api.queries.skip(reads).map((query) => query['keyword']), [
    'CP',
    'CP',
  ]);
}

void main() {
  testWidgets(
    'batch final count waits for the complete result while the rows grow; '
    'the kept selection is not taken from the shown prefix',
    (tester) async {
      final api = _Api(registration: false);
      final keyword = await _mount(tester, api);
      UtenButton confirm() => tester.widget(
        find.byKey(const Key('production-finished-inbound-batch-confirm')),
      );

      _table(tester).onSelectedIdsChanged!({'doc:doc-0', 'doc:doc-90'});
      await tester.pump();
      expect(find.text('批量全量点收入库(2)'), findsOneWidget);
      expect(confirm().onPressed, isNotNull);

      await _growNewQuery(tester, api, keyword);
      // doc-90 is beyond the first 50 rows: acting now would take only the
      // shown half of the selection.
      expect(_table(tester).selectedIds, {'doc:doc-0', 'doc:doc-90'});
      expect(confirm().onPressed, isNull);

      api.continuation!.complete();
      await tester.pumpAndSettle();
      expect(_table(tester).selectedIds, {'doc:doc-0', 'doc:doc-90'});
      expect(confirm().onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch registration waits for the complete result while the rows grow',
    (tester) async {
      final api = _Api(registration: true);
      final keyword = await _mount(tester, api);
      UtenButton register() =>
          tester.widget(find.byKey(InboundRoute.inspectFirst.batchKey));

      _table(tester).onSelectedIdsChanged!({'reg:rep-0', 'reg:rep-90'});
      await tester.pump();
      expect(register().onPressed, isNotNull);

      await _growNewQuery(tester, api, keyword);
      // Judging "所选任务状态已变化" against the shown prefix would be false for
      // rep-90; the entry waits instead.
      expect(_table(tester).selectedIds, {'reg:rep-0', 'reg:rep-90'});
      expect(register().onPressed, isNull);

      api.continuation!.complete();
      await tester.pumpAndSettle();
      expect(register().onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
}
