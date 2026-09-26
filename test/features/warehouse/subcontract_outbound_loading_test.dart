import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';
import 'package:uten_imp/features/warehouse/repositories/subcontract_outbound_detail_loader.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_task_center_scaffold.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test(
    'warehouse-only load deduplicates and does not wait for unrelated dictionaries',
    () async {
      final api = _DictionaryApi();
      final names = MasterNameService(api);
      await Future.wait([
        names.ensureWarehousesLoaded(),
        names.ensureWarehousesLoaded(),
      ]);
      expect(api.paths, [ApiEndpoints.warehousesDict]);
      expect(names.warehouseHierarchy.single.id, 'leaf');
    },
  );

  test(
    'task and draft reads run at bounded concurrency with stable order',
    () async {
      var active = 0;
      var maxActive = 0;
      final taskReads = <String>[];
      final documentReads = <String>[];
      Future<void> delay() async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(Duration.zero);
        active--;
      }

      final bundles = await loadSubcontractOutboundDetails(
        planIds: ['1', '2', '3', '4', '5', '1'],
        taskDetail: (id) async {
          taskReads.add(id);
          await delay();
          return OutboundTaskDetail.fromJson({
            'planId': id,
            'orderId': 'order-$id',
            'status': 'OPEN',
            'drafts': [
              {'issueId': 'd-$id', 'status': 0},
            ],
          });
        },
        documentDetail: (id) async {
          documentReads.add(id);
          await delay();
          return SubcontractDocDetail.fromJson({
            'id': id,
            'status': 0,
            'items': <Object>[],
          });
        },
      );
      expect(maxActive, 4);
      expect(taskReads, ['1', '2', '3', '4', '5']);
      expect(documentReads, ['d-1', 'd-2', 'd-3', 'd-4', 'd-5']);
      expect(
        bundles.map((bundle) => bundle.documents.single.id),
        documentReads,
      );
    },
  );

  testWidgets('the first real return refreshes a task center immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pageResumeProvider.overrideWith(
            (ref) => (location: '/warehouse/tasks/outbound', tick: 1),
          ),
        ],
        child: MaterialApp(
          home: WarehouseTaskCenterScaffold(
            title: '出库任务中心',
            searchHint: '搜索',
            location: '/warehouse/tasks/outbound',
            segments: const [
              WarehouseTaskSegmentSpec(value: 'subcontract', label: '委外出库'),
            ],
            initialSegment: 'subcontract',
            bodyBuilder: (_, _, tick, _) => Text('revision:$tick'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('revision:0'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WarehouseTaskCenterScaffold)),
    );
    // 只进去看了一眼就返回(期间本端没有写、未满 30 秒): 不重拉(ADR-108)。
    container.read(pageResumeProvider.notifier).state = (
      location: '/warehouse/subcontract-outbound/task',
      tick: 2,
    );
    await tester.pump();
    container.read(pageResumeProvider.notifier).state = (
      location: '/warehouse/tasks/outbound',
      tick: 3,
    );
    await tester.pumpAndSettle();
    expect(find.text('revision:0'), findsOneWidget);
    // 在出仓页办了出仓(网络层推进写修订号)后返回: 第一次真正的返回就立即重拉。
    container.read(pageResumeProvider.notifier).state = (
      location: '/warehouse/subcontract-outbound/task',
      tick: 4,
    );
    await tester.pump();
    container.read(dataWriteRevisionProvider.notifier).state++;
    container.read(pageResumeProvider.notifier).state = (
      location: '/warehouse/tasks/outbound',
      tick: 5,
    );
    await tester.pumpAndSettle();
    expect(find.text('revision:1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _DictionaryApi extends ApiClient {
  _DictionaryApi() : super(Dio());
  final paths = <String>[];
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    if (path != ApiEndpoints.warehousesDict) {
      throw StateError('unrelated dictionary');
    }
    return [
      {'id': 'leaf', 'name': '实际仓', 'status': 'active'},
    ];
  }
}
