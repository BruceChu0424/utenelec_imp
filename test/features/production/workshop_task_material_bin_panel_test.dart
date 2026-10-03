import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/features/production/models/workshop_task_stock_readiness.dart';
import 'package:uten_imp/features/production/repositories/workshop_material_choice_repository.dart';
import 'package:uten_imp/features/production/widgets/workshop_task_material_bin_panel.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';

class _Choices extends WorkshopMaterialChoiceRepository {
  _Choices(this.readiness) : super(ApiClient(Dio()));

  final WorkshopTaskStockReadiness readiness;
  int reads = 0;

  @override
  Future<WorkshopTaskStockReadiness> stockReadiness(String segmentId) async {
    expect(segmentId, 'segment-1');
    reads++;
    return readiness;
  }
}

class _Materials extends WorkshopMaterialRepository {
  _Materials() : super(ApiClient(Dio()));

  List<Map<String, dynamic>>? submittedLines;
  String? submittedKind;
  String? submittedWorkshop;

  @override
  Future<PagedResult<WmMaterialOption>> requestMaterials(
    String workshopId, {
    String keyword = '',
    List<String> goodsIds = const [],
    int page = 1,
    int size = 50,
  }) async {
    final rows = (await materials(
      workshopId,
    )).where((m) => goodsIds.isEmpty || goodsIds.contains(m.goodsId)).toList();
    return PagedResult(
      items: rows,
      page: 1,
      size: size,
      total: rows.length,
      totalPages: 1,
    );
  }

  @override
  Future<List<WmMaterialOption>> materials(String workshopId) async {
    expect(workshopId, 'workshop-1');
    return const [
      WmMaterialOption(
        goodsId: 'pp',
        goodsName: 'PP 颗粒',
        colorId: 'black',
        colorName: '黑',
        unitName: '千克',
        bulkPackageQty: 25,
        warehouseAvailableQty: 1000,
      ),
      WmMaterialOption(goodsId: 'abs', goodsName: 'ABS 颗粒'),
    ];
  }

  @override
  Future<WmRequisition> createRequisition({
    required String kind,
    required String workshopDepartmentId,
    required List<Map<String, dynamic>> lines,
    String? remark,
    required String idempotencyKey,
  }) async {
    submittedKind = kind;
    submittedWorkshop = workshopDepartmentId;
    submittedLines = lines;
    return const WmRequisition(
      id: 'request-1',
      requestNo: 'LL-1',
      kind: 'ISSUE',
      status: 'PENDING',
    );
  }
}

Future<(_Choices, _Materials)> _mount(
  WidgetTester tester, {
  String status = 'ESTIMATED_ENOUGH',
  bool requestAllowed = true,
  bool unknown = false,
  Map<String, dynamic> rowOverrides = const {},
}) async {
  tester.view
    ..physicalSize = const Size(1400, 1000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final choices = _Choices(
    WorkshopTaskStockReadiness.fromJson({
      'workshopDepartmentId': 'workshop-1',
      'workshopName': '生产一车间',
      'binWarehouseId': 'bin-1',
      'estimateIncomplete': unknown,
      'allowedActions': [if (requestAllowed) 'REQUEST'],
      'rows': [
        {
          'goodsId': 'pp',
          'goodsName': 'PP 颗粒',
          'colorId': 'black',
          'colorName': '黑',
          'unitName': '千克',
          'bookQty': 100,
          'estimatedRemainingQty': unknown ? null : 80,
          'requiredQty': unknown
              ? null
              : status == 'ESTIMATED_SHORT'
              ? 100
              : 2,
          'shortageQty': unknown
              ? null
              : status == 'ESTIMATED_SHORT'
              ? 20
              : 0,
          'status': status,
          'estimateIncomplete': unknown,
          'reason': unknown ? '存在未审报工，库存估计不完整' : null,
          ...rowOverrides,
        },
      ],
    }),
  );
  final materials = _Materials();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workshopMaterialChoiceRepositoryProvider.overrideWithValue(choices),
        workshopMaterialRepositoryProvider.overrideWithValue(materials),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkshopTaskMaterialBinPanel(segmentId: 'segment-1'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (choices, materials);
}

void main() {
  testWidgets('enough stock still allows advance bulk request with exact '
      'material and no work order quantity cap', (tester) async {
    final (choices, materials) = await _mount(tester);
    expect(find.text('预计足够'), findsOneWidget);
    expect(find.text('本任务预计还需：2 千克'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('workshop-task-request-bin-material')),
    );
    await tester.pumpAndSettle();
    final qty = find.byKey(const ValueKey('wm-line-qty-r1'));
    expect(qty, findsOneWidget);
    expect(tester.widget<TextField>(qty).controller!.text, isEmpty);
    await tester.enterText(qty, '250');
    await tester.tap(find.byKey(const Key('wm-request-submit')));
    await tester.pumpAndSettle();
    expect(materials.submittedKind, 'ISSUE');
    expect(materials.submittedWorkshop, 'workshop-1');
    expect(materials.submittedLines!.single['goodsId'], 'pp');
    expect(materials.submittedLines!.single['colorId'], 'black');
    expect(materials.submittedLines!.single['qty'], 250);
    expect(materials.submittedLines!.single.containsKey('segmentId'), isFalse);
    expect(choices.reads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short stock remains a prompt with the same request entry', (
    tester,
  ) async {
    await _mount(tester, status: 'ESTIMATED_SHORT');
    expect(find.text('预计不足 20 千克'), findsOneWidget);
    expect(find.text('新建补料申请'), findsOneWidget);
    expect(find.textContaining('不要求每张工单先去仓库领料'), findsOneWidget);
  });

  testWidgets('unknown quantities remain unknown and do not hide requests', (
    tester,
  ) async {
    await _mount(tester, status: 'UNKNOWN', unknown: true);
    expect(find.text('暂不能判断是否足够'), findsOneWidget);
    expect(find.text('内料仓估计还剩：暂不能估算'), findsOneWidget);
    expect(find.text('存在未审报工，库存估计不完整'), findsOneWidget);
    expect(find.text('新建补料申请'), findsOneWidget);
    expect(find.text('预计足够'), findsNothing);
    expect(find.textContaining('0 千克'), findsNothing);
  });

  testWidgets('request visibility follows the server action', (tester) async {
    await _mount(tester, requestAllowed: false);
    expect(find.text('预计足够'), findsOneWidget);
    expect(find.text('新建补料申请'), findsNothing);
  });

  for (final sample in [
    (unit: '千克', qty: 0.0032, text: '0.0032 千克'),
    (unit: '克', qty: 3.2, text: '3.2 克'),
  ]) {
    testWidgets('small per-piece quantities keep precision in ${sample.unit}', (
      tester,
    ) async {
      await _mount(
        tester,
        rowOverrides: {'unitName': sample.unit, 'requiredQty': sample.qty},
      );
      expect(find.text('本任务预计还需：${sample.text}'), findsOneWidget);
    });
  }

  testWidgets('tiny nonzero shortage never displays as zero', (tester) async {
    await _mount(
      tester,
      status: 'ESTIMATED_SHORT',
      rowOverrides: {
        'unitName': 'kg',
        'estimatedRemainingQty': -0.0000002,
        'shortageQty': 0.0000002,
      },
    );
    expect(find.text('预计不足 小于0.000001 kg'), findsOneWidget);
    expect(find.text('内料仓估计还剩：负值，绝对值小于0.000001 kg'), findsOneWidget);
    expect(find.text('预计不足 0 kg'), findsNothing);
  });
}
