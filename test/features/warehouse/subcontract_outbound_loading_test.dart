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
        issueIds: ['1', '2', '3', '4', '5', '1'],
        taskDetail: (id) async {
          taskReads.add(id);
          await delay();
          return OutboundTaskDetail.fromJson({
            'issueId': id,
            'orderId': 'order-$id',
            'lines': <Object>[],
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
      expect(documentReads, ['1', '2', '3', '4', '5']);
      // 每张领料单的拣货视图与它自己的出仓单草稿是同一个 id, 按原顺序配对。
      expect(bundles.map((bundle) => bundle.task.issueId), taskReads);
      expect(bundles.map((bundle) => bundle.document.id), documentReads);
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
    // 每次真实返回都重新校验；其它设备的写入不能由本机修订号或短 TTL 排除。
    container.read(pageResumeProvider.notifier).state = (
      location: '/warehouse/subcontract-outbound/issue-1',
      tick: 2,
    );
    await tester.pump();
    container.read(pageResumeProvider.notifier).state = (
      location: '/warehouse/tasks/outbound',
      tick: 3,
    );
    await tester.pumpAndSettle();
    expect(find.text('revision:1'), findsOneWidget);
    // 在出仓页办了出仓后返回，同样只执行一次返回刷新。
    container.read(pageResumeProvider.notifier).state = (
      location: '/warehouse/subcontract-outbound/issue-1',
      tick: 4,
    );
    await tester.pump();
    container.read(dataWriteRevisionProvider.notifier).state++;
    container.read(pageResumeProvider.notifier).state = (
      location: '/warehouse/tasks/outbound',
      tick: 5,
    );
    await tester.pumpAndSettle();
    expect(find.text('revision:2'), findsOneWidget);
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
      {
        'id': 'leaf',
        'name': '实际仓',
        'status': 'active',
        'selectableForNew': true,
      },
    ];
  }
}
