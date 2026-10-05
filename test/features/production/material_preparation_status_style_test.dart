import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_flow_stage.dart';
import 'package:uten_imp/features/production/widgets/material_preparation_status_style.dart';

void main() {
  for (final brightness in Brightness.values) {
    test(
      'matching preparation stages share colors across routes $brightness',
      () {
        final theme = ThemeData(brightness: brightness);
        for (final keys in [
          ['MAKE_PENDING_ISSUE', 'BUY_PENDING_ISSUE', 'SC_PENDING_ISSUE'],
          ['MAKE_IN_PROGRESS', 'BUY_REQUESTED', 'SC_REQUESTED'],
          ['MAKE_WAIT_STOCK_IN', 'BUY_WAIT_STOCK_IN', 'SC_WAIT_STOCK_IN'],
          ['MAKE_COMPLETED', 'BUY_STOCKED', 'SC_STOCKED'],
          ['ROUTE_PENDING', 'ROUTE_PENDING', 'ROUTE_PENDING'],
        ]) {
          final styles = [
            for (var i = 0; i < 3; i++)
              MaterialPreparationStatusStyle.resolve(
                theme,
                stage: ProductionFlowStage.fromServerKey(
                  keys[i],
                  route: ProductionFlowRoute.values[i],
                ),
              ),
          ];
          expect(styles.map((style) => style.background).toSet(), hasLength(1));
          expect(styles.map((style) => style.foreground).toSet(), hasLength(1));
          expect(styles.map((style) => style.icon).toSet(), hasLength(1));
        }
        for (final phase in MaterialPreparationStatusPhase.values) {
          final style = MaterialPreparationStatusStyle.resolve(
            theme,
            phase: phase,
          );
          final a = style.foreground.computeLuminance(),
              b = style.background.computeLuminance();
          final contrast = ((a > b ? a : b) + 0.05) / ((a > b ? b : a) + 0.05);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: '$phase contrast',
          );
        }
      },
    );
  }
  test('subcontract draw stages follow the workshop drawing phases', () {
    ProductionFlowStage sc(String key) => ProductionFlowStage.fromServerKey(
      key,
      route: ProductionFlowRoute.subcontract,
    );
    MaterialPreparationStatusPhase phase(ProductionFlowStage stage) =>
        materialPreparationStatusPhase(stage: stage);

    expect(
      phase(sc('SC_WAITING_MATERIAL')),
      phase(
        ProductionFlowStage.fromServerKey(
          'MAKE_WAITING_MATERIAL',
          route: ProductionFlowRoute.make,
        ),
      ),
    );
    expect(sc('SC_WAITING_MATERIAL').label, '已审批 · 等待物料');
    expect(sc('SC_WAITING_DRAW').label, '物料可领 · 待委外领料');
    expect(sc('SC_WAITING_DRAW').tone, ProductionFlowTone.toDraw);
    expect(
      phase(sc('SC_WAITING_DRAW')),
      MaterialPreparationStatusPhase.processing,
    );
    expect(sc('SC_WAIT_OUTBOUND').label, '已提交领料 · 等仓库发料');
    expect(
      phase(sc('SC_WAIT_OUTBOUND')),
      MaterialPreparationStatusPhase.processing,
    );
    expect(sc('SC_WAIT_RETURN').label, '委外加工中 · 等待回厂');
    expect(
      phase(sc('SC_WAIT_RETURN')),
      MaterialPreparationStatusPhase.awaitingReceipt,
    );
    // 委外不再有「前置自制」：MAKE_* 键只按自制链显示，不加前缀。
    expect(
      ProductionFlowStage.fromServerKey(
        'MAKE_IN_PROGRESS',
        route: ProductionFlowRoute.subcontract,
      ).label,
      '生产中 · 可报工',
    );
    // 服务端新增的委外阶段键先按通用「委外进行中」显示，不报「状态待确认」。
    expect(sc('SC_SOMETHING_NEW').label, '委外进行中');
    expect(sc('SC_SOMETHING_NEW').route, ProductionFlowRoute.subcontract);
  });
  test('cancelled and unknown states remain distinct from completed', () {
    final stage = ProductionFlowStage.forProduct(
      planExecutionStatus: 'IN_PROGRESS',
    );
    expect(
      materialPreparationStatusPhase(stage: stage, actualState: 'CANCELLED'),
      MaterialPreparationStatusPhase.cancelled,
    );
    expect(
      materialPreparationStatusPhase(facetKey: 'blocked'),
      MaterialPreparationStatusPhase.blocked,
    );
    expect(
      materialPreparationStatusPhase(),
      MaterialPreparationStatusPhase.unknown,
    );
  });
  testWidgets(
    'shared status content preserves the business text and paired foreground',
    (tester) async {
      final style = MaterialPreparationStatusStyle.resolve(
        ThemeData(),
        phase: MaterialPreparationStatusPhase.awaitingReceipt,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ColoredBox(
              color: style.background,
              child: MaterialPreparationStatusLabel(
                label: '品质已通过 · 等待入库',
                style: style,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.text('品质已通过 · 等待入库')).style?.color,
        style.foreground,
      );
      expect(tester.widget<Icon>(find.byType(Icon)).color, style.foreground);
    },
  );
}
