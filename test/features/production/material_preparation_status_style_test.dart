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
  test(
    'subcontract MAKE preparation keeps the same phase as workshop production',
    () {
      final theme = ThemeData();
      final make = ProductionFlowStage.fromServerKey(
        'MAKE_IN_PROGRESS',
        route: ProductionFlowRoute.make,
      );
      final subcontract = ProductionFlowStage.fromServerKey(
        'MAKE_IN_PROGRESS',
        route: ProductionFlowRoute.subcontract,
      );
      expect(subcontract.label, startsWith('前置自制'));
      expect(
        MaterialPreparationStatusStyle.resolve(theme, stage: subcontract).phase,
        MaterialPreparationStatusStyle.resolve(theme, stage: make).phase,
      );
    },
  );
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
