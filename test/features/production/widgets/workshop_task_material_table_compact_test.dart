import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/features/production/widgets/workshop_task_material_table.dart';

// Deliberately distinct quantities: the presentation must keep server facts,
// rather than deriving shortage or requestable quantities from other columns.
const _material = ProductionWorkshopTaskMaterial(
  demandId: 'demand-1',
  goodsCode: 'V50014',
  goodsName: '开关后座',
  colorName: '深灰色',
  unitName: '个',
  supplyRoute: 'MAKE',
  directSupply: true,
  requiredQty: 11000,
  reservedQty: 113,
  requestedUnissuedQty: 227,
  requestableQty: 331,
  lineSidePendingQty: 443,
  issuedQty: 551,
  shortageQty: 667,
  directReceivedQty: 773,
  directAvailableQty: 887,
  warehouseAvailableQty: 991,
  state: 'SHORT_MAKE',
  producingSegments: 'ZX001|IN_PROGRESS、ZX002|COMPLETED',
  planningGapQty: 79,
);

class _Repository extends ProductionExecutionWorkbenchRepository {
  _Repository({this.failOnce = false, this.count = 1})
    : super(ApiClient(Dio()));

  final bool failOnce;
  final int count;
  final List<String> loadedIds = [];

  @override
  Future<List<ProductionWorkshopTaskMaterial>> workshopTaskMaterials(
    String segmentId,
  ) async {
    loadedIds.add(segmentId);
    if (failOnce && loadedIds.length == 1) throw StateError('Unavailable');
    return [
      _material,
      for (var i = 2; i <= count; i++)
        ProductionWorkshopTaskMaterial(
          demandId: 'demand-$i',
          goodsCode: 'M-$i',
          goodsName: '物料 $i',
          supplyRoute: 'BUY',
          directSupply: false,
          requiredQty: 100,
          reservedQty: 0,
          requestedUnissuedQty: 0,
          requestableQty: 0,
          lineSidePendingQty: 0,
          issuedQty: 0,
          shortageQty: 100,
          directReceivedQty: 0,
          directAvailableQty: 0,
          warehouseAvailableQty: 0,
          state: 'SHORT',
        ),
    ];
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  String segmentId = 'segment-1',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
          repository,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkshopTaskMaterialTable(
              segmentId: segmentId,
              compact: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'multiple materials show only one until expanded and can collapse again',
    (tester) async {
      final repository = _Repository(count: 4);
      await _pump(tester, repository);
      expect(find.text('开关后座'), findsOneWidget);
      expect(find.text('物料 2'), findsNothing);
      expect(find.text('物料 4'), findsNothing);
      expect(find.text('展开查看全部物料（共 4 项）'), findsOneWidget);
      final toggle = find.byKey(const Key('workshop-task-material-toggle-all'));
      expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('物料 2'), findsOneWidget);
      expect(find.text('物料 4'), findsOneWidget);
      expect(find.text('收起物料'), findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('物料 2'), findsNothing);
      expect(find.text('物料 4'), findsNothing);
      expect(repository.loadedIds, ['segment-1'], reason: '展开收起不重复加载物料');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await _pump(tester, repository, segmentId: 'segment-2');
      expect(find.text('物料 2'), findsNothing);
      expect(find.text('展开查看全部物料（共 4 项）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one material does not show an unnecessary expand button', (
    tester,
  ) async {
    await _pump(tester, _Repository());
    expect(
      find.byKey(const Key('workshop-task-material-toggle-all')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact rows highlight shortage and expand all arrival facts', (
    tester,
  ) async {
    await _pump(tester, _Repository());

    expect(
      find.byKey(const Key('workshop-task-material-table')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('workshop-task-material-state-demand-1')),
      findsOneWidget,
    );
    expect(find.text('开关后座'), findsOneWidget);
    expect(find.text('V50014 · 深灰色'), findsOneWidget);
    expect(find.text('11000 个'), findsOneWidget);
    expect(find.text('551 个'), findsOneWidget);
    expect(find.text('667 个'), findsOneWidget);
    final context = tester.element(find.text('667 个'));
    expect(
      tester.widget<Text>(find.text('667 个')).style?.color,
      Theme.of(context).colorScheme.error,
    );
    expect(find.textContaining('表头设置'), findsNothing);
    expect(find.textContaining('仓库已到'), findsNothing);
    expect(find.textContaining('子件工单'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('workshop-task-material-details-demand-1')),
    );
    await tester.pumpAndSettle();

    for (final fact in [
      '仓库已到 991 个',
      '已预留 113 个',
      '待仓库发料 227 个',
      '可申请领料 331 个',
      '直送已交接 773 个',
      '直送可分配 887 个',
      '直送料待投入 443 个',
      '计划未下单 79 个',
      '来源 同车间直送',
      '子件工单 ZX001 生产中、ZX002 已完工',
    ]) {
      expect(find.text(fact), findsOneWidget);
    }
    await tester.tap(find.text('到料明细'));
    await tester.pumpAndSettle();
    expect(find.textContaining('仓库已到'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact arrival facts wrap on a narrow dialog without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, _Repository());
      await tester.tap(find.text('到料明细'));
      await tester.pumpAndSettle();

      expect(find.text('11000 个'), findsOneWidget);
      expect(find.text('来源 同车间直送'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final horizontalScrolls = tester
          .widgetList<Scrollable>(find.byType(Scrollable))
          .where(
            (scrollable) =>
                scrollable.axisDirection == AxisDirection.left ||
                scrollable.axisDirection == AxisDirection.right,
          );
      expect(horizontalScrolls, isEmpty);
      final rowRect = tester.getRect(
        find.byKey(const ValueKey('workshop-task-material-row-demand-1')),
      );
      for (final text in ['可申请领料 331 个', '直送已交接 773 个']) {
        final rect = tester.getRect(find.text(text));
        expect(rect.left, greaterThanOrEqualTo(rowRect.left));
        expect(rect.right, lessThanOrEqualTo(rowRect.right));
      }
    },
  );

  testWidgets('failed material load can be retried from compact dialog', (
    tester,
  ) async {
    final repository = _Repository(failOnce: true);
    await _pump(tester, repository);
    expect(find.text('物料明细加载失败'), findsOneWidget);
    expect(find.byKey(const Key('workshop-task-material-table')), findsNothing);

    await tester.tap(find.byKey(const Key('workshop-task-material-retry')));
    await tester.pumpAndSettle();

    expect(repository.loadedIds, ['segment-1', 'segment-1']);
    expect(find.text('物料明细加载失败'), findsNothing);
    expect(find.text('开关后座'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'switching tasks reloads facts and clears expanded material rows',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.tap(find.text('到料明细'));
      await tester.pumpAndSettle();
      expect(find.textContaining('仓库已到'), findsOneWidget);

      await _pump(tester, repository, segmentId: 'segment-2');

      expect(repository.loadedIds, ['segment-1', 'segment-2']);
      expect(find.textContaining('仓库已到'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
