import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/production/models/production_sales_requirement.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/models/production_plan.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/widgets/production_sales_requirements.dart';

const _a = ProductionSalesRequirement(
  salesOrderItemId: 'line-a',
  salesOrderNo: 'XD-A',
  productName: '测试产品',
  orderRemark: '全单不要打字\n装配前先核对客户要求。',
  itemRemark: '这个产品使用白色面板',
);
const _b = ProductionSalesRequirement(
  salesOrderItemId: 'line-b',
  salesOrderNo: 'XD-B',
  productName: '测试产品',
  orderRemark: '此单需要打字',
  itemRemark: '这个产品使用灰色面板',
);

void main() {
  test(
    'analysis, plan and workshop preserve both remark scopes from the same contract',
    () {
      final row = <String, dynamic>{
        'salesOrderItemId': 'line-a',
        'salesOrderNo': 'XD-A',
        'productName': '产品',
        'orderRemark': '订单统一要求',
        'itemRemark': '产品单独要求',
      };
      final analysis = ProductionMaterialAnalysisView.fromJson({
        'analysisId': 'a',
        'salesRequirements': {
          'child': [row],
        },
      });
      final plan = ProductionPlanItem.fromJson({
        'id': 'p',
        'salesRequirements': [row],
      });
      final workshop = ProductionExecutionWorkbenchSegment.fromJson({
        'salesRequirements': [row],
      });
      for (final notes in [
        analysis.salesRequirements['child']!,
        plan.salesRequirements,
        workshop.salesRequirements,
      ]) {
        expect(notes.single.orderRemark, '订单统一要求');
        expect(notes.single.itemRemark, '产品单独要求');
        expect(notes.single.salesOrderItemId, 'line-a');
      }
      expect(
        ProductionSalesRequirement.parseList([
          {'itemRemark': '   '},
        ]),
        isEmpty,
      );
      expect(
        ProductionMaterialAnalysisView.fromJson({
          'analysisId': 'old',
        }).salesRequirements,
        isEmpty,
      );
    },
  );

  for (final dark in [false, true]) {
    for (final width in [360.0, 1280.0]) {
      testWidgets(
        'source instructions stay separate at width $width dark $dark and 200% text',
        (tester) async {
          tester.view.physicalSize = Size(width, 760);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? buildDarkTheme() : buildLightTheme(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: ProductionSalesRequirements(
                      requirements: [_a, _a, _b],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('XD-A · 测试产品'), findsOneWidget);
          expect(find.text('XD-B · 测试产品'), findsOneWidget);
          expect(find.text('订单统一备注'), findsNWidgets(2));
          expect(find.text('产品单独备注'), findsNWidgets(2));
          expect(find.text('这个产品使用白色面板'), findsOneWidget);
          expect(find.text('这个产品使用灰色面板'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
