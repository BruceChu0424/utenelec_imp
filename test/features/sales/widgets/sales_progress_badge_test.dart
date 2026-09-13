import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/widgets/sales_progress_badge.dart';
import 'package:uten_imp/features/sales/providers/sales_completion_count_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'reading completion messages keeps unprocessed shippable orders in badge',
    (tester) async {
      final api = _AttentionApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesOrderView,
            }),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => Column(
                  children: [
                    const SalesProgressBadge(showLabel: true),
                    TextButton(
                      onPressed: () => markSalesCompletionSeen(ref),
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
  testWidgets(
    'sales attention badge sums unresolved rejects and shippable orders once',
    (tester) async {
      final api = _AttentionApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesOrderView,
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Center(child: SalesProgressBadge(showLabel: true)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('5'), findsOneWidget);
      expect(find.byTooltip('销售待关注 5 项'), findsOneWidget);
    },
  );

  testWidgets('order work badge does not depend on notice availability', (
    tester,
  ) async {
    await _pumpBadge(tester, _AttentionApi(failNotices: true));
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets(
    'unavailable order work count is not replaced by notification count',
    (tester) async {
      await _pumpBadge(tester, _AttentionApi(failStages: true));
      expect(find.text('2'), findsNothing);
      expect(find.text('0'), findsNothing);
    },
  );
}

Future<void> _pumpBadge(WidgetTester tester, ApiClient api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.salesOrderView,
        }),
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

class _AttentionApi extends ApiClient {
  _AttentionApi({this.failNotices = false, this.failStages = false})
    : super(Dio());

  final bool failNotices;
  final bool failStages;
  int readMarks = 0;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('read-by-source')) readMarks++;
    return const {};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/notices/unread-count-by-source') {
      if (failNotices) throw StateError('notice count unavailable');
      return const {'count': 2};
    }
    if (path == '/sales/orders/progress/stage-counts') {
      if (failStages) throw StateError('stage count unavailable');
      return const {'REJECTED': 3, 'PENDING': 1, 'SHIPPABLE': 2};
    }
    return const <String, dynamic>{};
  }
}
