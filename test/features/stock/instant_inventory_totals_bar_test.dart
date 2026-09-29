// 即时库存页「表格下方合计」契约。
//
// 即时库存是本轮唯一一个非报表服务页也接上合计条的地方，它踩的正是最容易出错的那个坑：
// 一行 = 一个货品×颜色跨仓聚合，所以合计必须与表格**同一批行**（同一分类/仓库/含不良品仓/
// 关键字筛选）在**整个结果集**上算，而不是对当前这一页求和。
//
// 这里刻意让「当前页 2 行合计 12」而服务端合计是「900 个 · 20 箱」：哪天有人把合计改成
// 前端对当前页求和，第一个断言就会红。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('服务端分页：合计条显示服务端合计，而不是对当前页求和', (tester) async {
    await _pumpPage(tester, const Size(1500, 1000));

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

    // 重量 (千克) 按显示单位换算 (默认自动 → 吨)；含估算前缀「≈」，未称项数并进同一项，
    // 两个伴随计数项不单独占位。
    expect(find.text('≈3.52 t (另有 12 项未称)'), findsOneWidget);
    expect(find.text('重量未知'), findsNothing);
    expect(find.text('重量含估算'), findsNothing);
  });

  testWidgets('后端未下发 totals 时合计条整条不渲染（不伪造 0、不退化成本页合计）', (tester) async {
    await _pumpPage(tester, const Size(1500, 1000), withTotals: false);
    expect(find.byType(UtenTotalsSummaryBar), findsNothing);
  });

  testWidgets('窄屏 + 1.5× 字号：合计条仍在且不溢出', (tester) async {
    await _pumpPage(tester, const Size(375, 812), textScale: 1.5);

    expect(find.byType(UtenTotalsSummaryBar), findsOneWidget);
    expect(find.text('900 个 · 20 箱'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPage(
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
        apiClientProvider.overrideWithValue(
          _InstantInventoryApi(withTotals: withTotals),
        ),
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
        home: const InstantInventoryPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _InstantInventoryApi extends ApiClient {
  _InstantInventoryApi({required this.withTotals}) : super(Dio());

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
    if (!path.contains('instant-inventory')) return <String, dynamic>{};
    return <String, dynamic>{
      // 当前页只有 2 行（数量合计 12），全集 137 行——合计条必须显示服务端的 900/20。
      'items': <Object?>[
        <String, dynamic>{
          'goodsId': '11111111-1111-1111-1111-111111111111',
          'name': '螺丝',
          'unitName': '个',
          'qty': 10,
          'weight': 1.5,
          'weightEstimated': true,
        },
        <String, dynamic>{
          'goodsId': '22222222-2222-2222-2222-222222222222',
          'name': '包装箱',
          'unitName': '箱',
          'qty': 2,
          'weight': 3,
        },
      ],
      'page': 1,
      'size': 20,
      'total': 137,
      'totalPages': 7,
      if (withTotals)
        'totals': <Object?>[
          <String, dynamic>{
            'key': 'weight',
            'label': '合计库存重量',
            'type': 'weight',
            'groupKey': null,
            'groups': <Object?>[
              <String, dynamic>{'unit': null, 'value': 3520},
            ],
          },
          <String, dynamic>{
            'key': 'weight_unknown_rows',
            'label': '重量未知',
            'type': 'count',
            'groupKey': null,
            'groups': <Object?>[
              <String, dynamic>{'unit': null, 'value': 12},
            ],
          },
          <String, dynamic>{
            'key': 'weight_estimated_rows',
            'label': '重量含估算',
            'type': 'count',
            'groupKey': null,
            'groups': <Object?>[
              <String, dynamic>{'unit': null, 'value': 3},
            ],
          },
          <String, dynamic>{
            'key': 'qty',
            'label': '合计库存数量',
            'type': 'number',
            'groupKey': 'unit_name',
            'groups': <Object?>[
              <String, dynamic>{'unit': '个', 'value': 900},
              <String, dynamic>{'unit': '箱', 'value': 20},
            ],
          },
        ],
    };
  }
}
