// 销售「订单进度查询」红徽章: 数字 = 徽章汇总的 salesAttention 入口(未解决财务驳回 +
// 可分批发货待开单, 服务端算好, ADR-108); 阅读完工提醒只置通知已读, 不改变待办数。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/providers/sales_completion_count_provider.dart';
import 'package:uten_imp/features/sales/widgets/sales_progress_badge.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../../helpers/badge_summary_fixture.dart';

void main() {
  testWidgets(
    'reading completion messages keeps unprocessed shippable orders in badge',
    (tester) async {
      final api = _ReadApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            fixedBadgeSummaryOverride(
              badgeSummaryFixture(entries: {BadgeEntry.salesAttention: (5, 0)}),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    const SalesProgressBadge(showLabel: true),
                    TextButton(
                      onPressed: () => markSalesCompletionSeen(context),
                      child: const Text('阅读进度通知'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('5'), findsOneWidget);
      await tester.tap(find.text('阅读进度通知'));
      await tester.pumpAndSettle();
      expect(api.readMarks, 1);
      expect(find.text('5'), findsOneWidget);
    },
  );

  testWidgets('sales attention badge shows the server-summed count once', (
    tester,
  ) async {
    await _pumpBadge(tester, 5);
    expect(find.text('5'), findsOneWidget);
    expect(find.byTooltip('销售待关注 5 项'), findsOneWidget);
  });

  testWidgets('no attention items: badge is not rendered (never a 0)', (
    tester,
  ) async {
    await _pumpBadge(tester, 0);
    expect(find.byType(Tooltip), findsNothing);
    expect(find.text('0'), findsNothing);
  });
}

Future<void> _pumpBadge(WidgetTester tester, int count) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(entries: {BadgeEntry.salesAttention: (count, 0)}),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: SalesProgressBadge(showLabel: true)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ReadApi extends ApiClient {
  _ReadApi() : super(Dio());

  int readMarks = 0;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('read-by-source')) readMarks++;
    return const {'count': 1};
  }
}
