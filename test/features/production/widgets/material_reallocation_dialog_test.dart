import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/material_reallocation_dialog.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets(
    'wide dialog validates impact and submits source plus target CAS once',
    (tester) async {
      final repository = _FakeRepository();
      await _pumpLauncher(
        tester,
        repository,
        size: const Size(1200, 900),
        textScale: 1.2,
        dark: true,
      );

      await tester.tap(find.byKey(const Key('open-cross-reallocation')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-cross-reallocation-dialog')),
        findsOneWidget,
      );
      expect(find.text('跨计划让料'), findsOneWidget);

      await tester.tap(
        find.byKey(
          const ValueKey(
            'cross-reallocation-candidate-target-analysis-target-material',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_fieldText(tester, const Key('cross-reallocation-qty')), '4');
      await tester.enterText(
        find.byKey(const Key('cross-reallocation-reason')),
        '客户订单加急',
      );
      await tester.pump();

      expect(find.textContaining('优先待补'), findsWidgets);
      expect(find.textContaining('接受计划无需返还'), findsWidgets);
      expect(
        tester
            .getSize(find.byKey(const Key('cross-reallocation-confirm')))
            .height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.byKey(const Key('cross-reallocation-confirm')));
      await tester.pumpAndSettle();
      expect(repository.createCalls, 1);
      expect(repository.lastSource?.analysisId, 'source-analysis');
      expect(repository.lastSource?.version, 1);
      expect(repository.lastTarget?.targetAnalysisId, 'target-analysis');
      expect(repository.lastTarget?.targetVersion, 3);
      expect(repository.lastQty, 4);
      expect(repository.lastReason, '客户订单加急');
      expect(
        find.byKey(const Key('material-cross-reallocation-dialog')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'compact sheet keeps form draft and rebases both CAS after conflict',
    (tester) async {
      final repository = _FakeRepository(conflictOnce: true);
      await _pumpLauncher(
        tester,
        repository,
        size: const Size(375, 812),
        textScale: 1.4,
      );

      await tester.tap(find.byKey(const Key('open-cross-reallocation')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-cross-reallocation-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('material-cross-reallocation-dialog')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(
          const ValueKey(
            'cross-reallocation-candidate-target-analysis-target-material',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('cross-reallocation-qty')),
        '3.5',
      );
      await tester.enterText(
        find.byKey(const Key('cross-reallocation-reason')),
        '临时插单优先',
      );
      final formScrollable = find
          .ancestor(
            of: find.byKey(const Key('cross-reallocation-reason')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.tap(find.byKey(const Key('cross-reallocation-confirm')));
      await tester.pumpAndSettle();

      expect(repository.createCalls, 1);
      expect(repository.detailCalls, 1);
      await tester.drag(formScrollable, const Offset(0, -360));
      await tester.pumpAndSettle();
      expect(find.textContaining('数量和原因已保留'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cross-reallocation-confirm')));
      await tester.pumpAndSettle();
      expect(repository.createCalls, 2);
      expect(repository.lastSource?.version, 2);
      expect(repository.lastTarget?.targetVersion, 4);
      expect(repository.lastQty, 3.5);
      expect(repository.lastReason, '临时插单优先');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('candidate failure has retry and honest empty state', (
    tester,
  ) async {
    final repository = _FakeRepository(
      candidateFailures: 1,
      emptyAfterFailure: true,
    );
    await _pumpLauncher(tester, repository, size: const Size(900, 720));

    await tester.tap(find.byKey(const Key('open-cross-reallocation')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('cross-reallocation-candidates-error')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('cross-reallocation-candidates-retry')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('cross-reallocation-candidates-empty')),
      findsOneWidget,
    );
    expect(find.textContaining('同仓库、同货品/颜色/单位'), findsOneWidget);
  });
}

Future<void> _pumpLauncher(
  WidgetTester tester,
  _FakeRepository repository, {
  required Size size,
  double textScale = 1,
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
      ),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const Key('open-cross-reallocation'),
              onPressed: () => showMaterialReallocationDialog(
                context: context,
                repository: repository,
                sourceAnalysis: _sourceAnalysis,
                sourceMaterial: _sourceMaterial,
                sourceProductLabel: '来源计划产品',
                sourcePathLabel: '来源计划产品 / 共享电机',
                qtyText: _qty,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
}

String _fieldText(WidgetTester tester, Key key) => tester
    .widget<EditableText>(
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText)),
    )
    .controller
    .text;

String _qty(double? value) {
  if (value == null) return '—';
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

const _sourceMaterial = ProductionMaterialAnalysisMaterial(
  materialLineId: 'source-material',
  analysisLineId: 'source-product',
  goodsId: 'goods-1',
  goodsCode: 'M-001',
  goodsName: '共享电机',
  unitName: '件',
  level: 1,
  requiredQty: 10,
  allocatedAvailableQty: 10,
  actionable: true,
);

const _sourceAnalysis = ProductionMaterialAnalysisView(
  analysisId: 'source-analysis',
  version: 1,
  fingerprint:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  warehouseId: 'warehouse-1',
  materials: [_sourceMaterial],
  allowedActions: {'REALLOCATE'},
);

ProductionMaterialAnalysisView _latestSource() =>
    const ProductionMaterialAnalysisView(
      analysisId: 'source-analysis',
      version: 2,
      fingerprint:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      warehouseId: 'warehouse-1',
      materials: [_sourceMaterial],
      allowedActions: {'REALLOCATE'},
    );

MaterialCrossReallocationCandidate _candidate(int version) =>
    MaterialCrossReallocationCandidate(
      targetAnalysisId: 'target-analysis',
      targetVersion: version,
      targetFingerprint: version == 3 ? 'c' * 64 : 'd' * 64,
      targetMaterialLineId: 'target-material',
      analysisLabel: '订单 XS-002',
      productLabel: '加急产品',
      pathLabel: '加急产品 / 共享电机',
      warehouseId: 'warehouse-1',
      warehouseName: '主仓',
      deliveryDate: '2026-08-25',
      shortageQty: 5,
      sourceLendableQty: 4,
    );

class _FakeRepository extends ProductionPlanRepository {
  _FakeRepository({
    this.conflictOnce = false,
    this.candidateFailures = 0,
    this.emptyAfterFailure = false,
  }) : super(ApiClient(Dio()));

  final bool conflictOnce;
  int candidateFailures;
  final bool emptyAfterFailure;
  int candidateCalls = 0;
  int createCalls = 0;
  int detailCalls = 0;
  ProductionMaterialAnalysisView? lastSource;
  MaterialCrossReallocationCandidate? lastTarget;
  double? lastQty;
  String? lastReason;

  @override
  Future<PagedResult<MaterialCrossReallocationCandidate>>
  materialCrossReallocationCandidates({
    required String sourceAnalysisId,
    required String sourceMaterialLineId,
    int page = 1,
    int size = 20,
    String keyword = '',
  }) async {
    candidateCalls++;
    if (candidateFailures > 0) {
      candidateFailures--;
      throw NetworkException('候选加载失败');
    }
    final items = emptyAfterFailure
        ? const <MaterialCrossReallocationCandidate>[]
        : [_candidate(candidateCalls > 1 ? 4 : 3)];
    return PagedResult(
      items: items,
      page: 1,
      size: size,
      total: items.length,
      totalPages: items.isEmpty ? 0 : 1,
    );
  }

  @override
  Future<ProductionMaterialAnalysisView> createMaterialCrossReallocation({
    required ProductionMaterialAnalysisView sourceAnalysis,
    required MaterialCrossReallocationCandidate target,
    required String sourceMaterialLineId,
    required double qty,
    required String reason,
    required String idempotencyKey,
  }) async {
    createCalls++;
    lastSource = sourceAnalysis;
    lastTarget = target;
    lastQty = qty;
    lastReason = reason;
    if (conflictOnce && createCalls == 1) {
      throw ApiException('CONFLICT', '两份物料分析已更新，请重新加载');
    }
    return _latestSource();
  }

  @override
  Future<ProductionMaterialAnalysisView> materialAnalysisDetail(
    String analysisId,
  ) async {
    detailCalls++;
    return _latestSource();
  }
}
