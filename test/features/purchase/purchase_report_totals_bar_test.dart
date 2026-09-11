// 报表表格下方合计条（服务端合计）契约 —— 以采购报表页为代表，口径对全部 8 个
// ReportData 报表页一致（销售/采购/委外/仓库/生产/钱流报表 + 钱流账户流水/对账单）。
//
// 最要命的一条：**服务端分页的表格必须显示服务端合计**。这里刻意让「当前页只有 2 行、
// 合计 12」而服务端合计是「900 个 · 20 箱」，如果哪天有人把合计改成对当前页求和，
// 第一个断言就会红。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/config/purchase_report_config.dart';
import 'package:uten_imp/features/purchase/pages/purchase_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('服务端分页：合计条显示服务端合计，而不是对当前页求和', (tester) async {
    await _pumpReport(tester, const Size(1500, 1000));

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);

    // 服务端合计（整个结果集 137 行）——不是当前页这 2 行的 10+2=12。
    expect(find.text('900 个 · 20 箱'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(UtenTotalsSummaryBar),
        matching: find.text('12'),
      ),
      findsNothing,
    );

    // 920 = 跨单位相加，绝不允许出现。
    expect(find.textContaining('920'), findsNothing);

    // 金额按币种分组，同样不合并。
    expect(find.text('1,234.50 CNY · 200.00 USD'), findsOneWidget);
    expect(find.textContaining('1,434'), findsNothing);
  });

  testWidgets('后端未下发 totals 时合计条整条不渲染（不伪造 0、不退化成本页合计）', (tester) async {
    await _pumpReport(tester, const Size(1500, 1000), withTotals: false);
    expect(find.byType(UtenTotalsSummaryBar), findsNothing);
  });

  // 合计条挂在表体（内部滚动）之外、翻页条之上，所以窄屏/大字号下都必须还在。
  for (final size in const [
    Size(375, 812), // 手机
    Size(834, 1112), // 平板
    Size(1500, 1000), // 桌面
  ]) {
    testWidgets('${size.width.toInt()}px 视口下合计条可见且不溢出', (tester) async {
      await _pumpReport(tester, size);

      expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
      expect(find.text('900 个 · 20 箱'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('1.5× 字号下合计条可见且不溢出', (tester) async {
    await _pumpReport(tester, const Size(375, 812), textScale: 1.5);

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
    expect(find.text('900 个 · 20 箱'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpReport(
  WidgetTester tester,
  Size size, {
  bool withTotals = true,
  double textScale = 1.0,
}) async {
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();

  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_ReportApi(withTotals: withTotals)),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(const <String>{}),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const PurchaseReportTablePage(kind: PurchaseReportKind.detail),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ReportApi extends ApiClient {
  _ReportApi({required this.withTotals}) : super(Dio());

  final bool withTotals;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.contains('/purchase/reports/')) return <String, dynamic>{};
    return <String, dynamic>{
      'columns': <Object?>[
        <String, dynamic>{'key': 'billNo', 'label': '单号', 'type': 'text'},
        <String, dynamic>{'key': 'qty', 'label': '数量', 'type': 'number'},
        <String, dynamic>{'key': 'unitName', 'label': '单位', 'type': 'text'},
      ],
      // 当前页只有 2 行（合计 12），全集 137 行——合计条必须显示服务端的 900/20。
      'rows': <Object?>[
        <String, dynamic>{'billNo': 'PR-001', 'qty': 10, 'unitName': '个'},
        <String, dynamic>{'billNo': 'PR-002', 'qty': 2, 'unitName': '箱'},
      ],
      'facets': <String, dynamic>{},
      'page': 1,
      'size': 50,
      'total': 137,
      'totalPages': 3,
      if (withTotals)
        'totals': <Object?>[
          <String, dynamic>{
            'key': 'qty',
            'label': '合计数量',
            'type': 'number',
            'groupKey': 'unitName',
            'groups': <Object?>[
              <String, dynamic>{'unit': '个', 'value': 900},
              <String, dynamic>{'unit': '箱', 'value': 20},
            ],
          },
          <String, dynamic>{
            'key': 'amount',
            'label': '合计金额',
            'type': 'money',
            'groupKey': 'currencyCode',
            'groups': <Object?>[
              <String, dynamic>{'unit': 'CNY', 'value': 1234.5},
              <String, dynamic>{'unit': 'USD', 'value': 200},
            ],
          },
        ],
    };
  }
}
