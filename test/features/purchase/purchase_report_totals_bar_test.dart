// 报表表格下方合计条（服务端合计）契约 —— 以采购报表页为代表，口径对全部 8 个
// ReportData 报表页一致（销售/采购/委外/仓库/生产/钱流报表 + 钱流账户流水/对账单）。
//
// 最要命的一条：**完整连续表格必须显示服务端合计**。这里让全部 137 行仅前两行
// 有数量（合计 12），而服务端合计是「900 个 · 20 箱」，若改成对已加载行求和，
// 第一个断言就会红。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import '../../support/pump_until.dart';
import '../../support/uten_test_actions.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/features/purchase/config/purchase_report_config.dart';
import 'package:uten_imp/features/purchase/pages/purchase_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('服务端分页：合计条显示服务端合计，而不是对当前页求和', (tester) async {
    await _pumpReport(tester, const Size(1500, 1000));

    final appBar = tester.widget<UtenAppBar>(find.byType(UtenAppBar));
    expect(find.text(appBar.title!), findsOneWidget);
    expect(find.textContaining('共 137'), findsNothing);

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);

    // 服务端合计（整个结果集 137 行）——不是已加载 137 行的 10+2=12。
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
    expect(find.text('1234.50 元 · 200.00 美金'), findsOneWidget);
    expect(find.textContaining('1434.50'), findsNothing);
    expect(find.textContaining('1,434'), findsNothing);
  });

  testWidgets('后端未下发 totals 时合计条整条不渲染（不伪造 0、不退化成本页合计）', (tester) async {
    await _pumpReport(tester, const Size(1500, 1000), withTotals: false);
    expect(find.byType(UtenTotalsSummaryBar), findsNothing);
  });

  // 合计条沿完整连续表体的末行展示，窄屏/大字号滚到末尾仍必须可见。
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
  final api = _ReportApi(withTotals: withTotals);

  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
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
  final tableFinder = find.byType(MasterDataTableView<Map<String, dynamic>>);
  await pumpUntil(
    tester,
    () {
      if (tableFinder.evaluate().length != 1) return false;
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        tableFinder,
      );
      return !table.isLoading && table.items.length == 137;
    },
    reason: 'The complete137-row report did not publish its accepted table',
  );
  // A complete continuous result has137 rows. The existing inline server
  // summary belongs to its real terminal row, and is virtualized with it.
  final beforeScrollReads = api.reportQueries.length;
  if (withTotals) {
    final body = find.descendant(
      of: tableFinder,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is UtenPageScrollbarSource &&
            widget.debugLabel == 'master-table-body',
      ),
    );
    expect(body, findsOneWidget);
    utenTestTableBodyController(tester, tableFinder);
    final viewport =
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
    for (
      var attempt = 0;
      find.byType(UtenTotalsSummaryBar).evaluate().isEmpty && attempt < 20;
      attempt++
    ) {
      final visible = tester.getRect(body).intersect(viewport);
      expect(visible.height, greaterThan(0));
      await tester.dragFrom(visible.center, const Offset(0, -700));
      await tester.pumpAndSettle();
    }
    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
    await tester.ensureVisible(find.byType(UtenTotalsSummaryBar));
    await tester.pumpAndSettle();
    expect(find.text('900 个 · 20 箱').hitTestable(), findsOneWidget);
  }
  expect(
    api.reportQueries,
    hasLength(beforeScrollReads),
    reason: '完整表的末行合计只在本地滚动展示，不发HTTP',
  );
  // One complete read in the shared progressive ladder: (1,50) (2,50) (2,100).
  final batches = _progressiveBatches(_ReportApi._totalRows);
  expect(api.reportQueries.map((query) => query['page']), <int>[
    for (final (page, _) in batches) page,
  ]);
  expect(api.reportQueries.map((query) => query['size']), <int>[
    for (final (_, size) in batches) size,
  ]);
}

/// The (page, size) requests of one complete read under the shared
/// progressive plan: 50 → 50 → 100 → 200 …, each batch at its exact offset.
List<(int, int)> _progressiveBatches(int total) {
  const plan = CompleteReadBatchPlan.progressive;
  final batches = <(int, int)>[];
  var offset = 0;
  do {
    final size = plan.sizeAt(offset);
    batches.add((offset ~/ size + 1, size));
    offset += size;
  } while (offset < total);
  return batches;
}

class _ReportApi extends ApiClient {
  _ReportApi({required this.withTotals}) : super(Dio());

  final bool withTotals;
  static const _totalRows = 137;
  final reportQueries = <Map<String, dynamic>>[];

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
    final page = (query?['page'] as num?)?.toInt() ?? 1;
    final size = (query?['size'] as num?)?.toInt() ?? 50;
    reportQueries.add(<String, dynamic>{'page': page, 'size': size});
    final start = (page - 1) * size;
    final end = start + size < _totalRows ? start + size : _totalRows;
    return <String, dynamic>{
      'columns': <Object?>[
        <String, dynamic>{'key': 'billNo', 'label': '单号', 'type': 'text'},
        <String, dynamic>{'key': 'qty', 'label': '数量', 'type': 'number'},
        <String, dynamic>{'key': 'unitName', 'label': '单位', 'type': 'text'},
      ],
      // 全集按同一批大小读取 137 个唯一身份；仅前两行有数量，仍不能据此求合计。
      'rows': <Object?>[
        for (var index = start; index < end; index++)
          <String, dynamic>{
            'id': 'purchase-report-row-${index + 1}',
            'billNo': 'PR-${(index + 1).toString().padLeft(3, '0')}',
            'qty': index == 0 ? 10 : (index == 1 ? 2 : 0),
            'unitName': index == 1 ? '箱' : '个',
          },
      ],
      'facets': <String, dynamic>{},
      'page': page,
      'size': size,
      'total': _totalRows,
      'totalPages': (_totalRows + size - 1) ~/ size,
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
