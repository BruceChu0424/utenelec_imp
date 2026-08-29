import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/widgets/sales_progress_badge.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'sales attention badge sums unresolved rejects and unread completion',
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

  testWidgets('rejection badge survives a notice-count failure', (
    tester,
  ) async {
    await _pumpBadge(tester, _AttentionApi(failNotices: true));
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('completion badge survives a stage-count failure', (
    tester,
  ) async {
    await _pumpBadge(tester, _AttentionApi(failStages: true));
    expect(find.text('2'), findsOneWidget);
  });
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
      return const {'REJECTED': 3, 'PENDING': 1};
    }
    return const <String, dynamic>{};
  }
}
