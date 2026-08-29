import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/department/models/workforce_overview.dart';
import 'package:uten_imp/features/department/widgets/organization_workforce_overview_card.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  for (final width in <double>[375, 768, 1200]) {
    testWidgets('人员概况卡在 ${width.toInt()} 宽度无溢出', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: OrganizationWorkforceOverviewCard(
                    organizationName: '优腾制造有限公司',
                    organizationLevel: '公司',
                    loading: false,
                    overview: _overview(),
                    onRetry: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 默认收起：只显示「当前人员」一组指标。
      expect(find.text('公司人员概况'), findsOneWidget);
      expect(find.text('当前人员'), findsOneWidget);
      expect(find.text('离职率(估算)'), findsNothing);
      expect(tester.takeException(), isNull);

      // 点击标题行展开后显示完整分组。
      await tester.tap(find.text('公司人员概况'));
      await tester.pump();
      expect(find.text('离职率(估算)'), findsOneWidget);
      expect(find.text('10.3%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('深色模式显示历史覆盖提示', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: SingleChildScrollView(
              child: OrganizationWorkforceOverviewCard(
                organizationName: '财税部',
                organizationLevel: '一级部门',
                loading: false,
                overview: _overview(historyComplete: false),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('部门人员概况'), findsOneWidget);
    // 数据质量提示位于展开区域，先展开再断言。
    await tester.tap(find.text('部门人员概况'));
    await tester.pump();
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining('缺少离职事件日期'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

WorkforceOverview _overview({bool historyComplete = true}) => WorkforceOverview(
  organizationId: 'dept-1',
  organizationName: '优腾制造有限公司',
  organizationLevel: '公司',
  asOf: '2026-07-31',
  periodStart: '2025-07-31',
  periodMonths: 12,
  directCurrentEmployees: 12,
  currentEmployees: 100,
  activeEmployees: 90,
  probationEmployees: 6,
  onLeaveEmployees: 4,
  hiredEmployees: 15,
  rehiredEmployees: 2,
  departedEmployees: 10,
  transferInEmployees: 3,
  transferOutEmployees: 5,
  openingHeadcount: 95,
  averageHeadcount: 97.5,
  turnoverRatePct: 10.3,
  netChange: 5,
  descendantDepartmentCount: 8,
  contractOverdue: 1,
  contractExpiringIn30Days: 4,
  probationOverdue: 1,
  probationEndingIn30Days: 2,
  turnoverRateApproximate: true,
  historyCoverageComplete: historyComplete,
  missingHistoryRecords: historyComplete ? 0 : 3,
  dataQualityNote: historyComplete
      ? '离职率按期初与期末平均在册人数估算。'
      : '有 3 名历史离职人员缺少离职事件日期，离职率仅统计可追溯记录。',
);
