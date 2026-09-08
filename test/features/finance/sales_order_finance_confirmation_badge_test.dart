import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/providers/sales_order_finance_confirmation_count_provider.dart';
import 'package:uten_imp/features/finance/widgets/sales_order_finance_confirmation_badge.dart';

Future<ProviderContainer> _pumpBadge(
  WidgetTester tester, {
  required bool? changesOnly,
  required FutureOr<int> Function() count,
  Locale locale = const Locale('zh'),
}) async {
  final container = ProviderContainer(
    overrides: [
      if (changesOnly == null)
        salesOrderFinanceConfirmationCountProvider.overrideWith(
          (ref) => count(),
        )
      else
        salesOrderFinanceQueueCountProvider(
          changesOnly,
        ).overrideWith((ref) => count()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SalesOrderFinanceConfirmationBadge(changesOnly: changesOnly),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void _refresh(ProviderContainer container, bool? changesOnly) {
  if (changesOnly == null) {
    container.invalidate(salesOrderFinanceConfirmationCountProvider);
  } else {
    container.invalidate(salesOrderFinanceQueueCountProvider(changesOnly));
  }
}

void main() {
  for (final entry in <bool?, String>{
    null: '销售订单财务确认',
    false: '销售订单首次财务确认',
    true: '销售订单修改',
  }.entries) {
    final changesOnly = entry.key;
    final queue = entry.value;

    testWidgets('$queue loading announces an unknown count, never zero', (
      tester,
    ) async {
      final pending = Completer<int>();
      await _pumpBadge(
        tester,
        changesOnly: changesOnly,
        count: () => pending.future,
      );

      expect(find.byTooltip('正在加载$queue待办数量'), findsOneWidget);
      expect(find.bySemanticsLabel('正在加载$queue待办数量'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('没有待')), findsNothing);
      expect(find.byType(UtenNotificationBadge), findsNothing);
      pending.complete(0);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('没有待处理的$queue'), findsOneWidget);
    });

    testWidgets('$queue failure stays explicit and existing refresh recovers', (
      tester,
    ) async {
      var calls = 0;
      final next = Completer<int>();
      final container = await _pumpBadge(
        tester,
        changesOnly: changesOnly,
        count: () => ++calls == 1
            ? Future<int>.error(StateError('internal failure detail'))
            : next.future,
      );
      await tester.pumpAndSettle();

      final message = '$queue待办数量加载失败，请进入任务页重试';
      expect(find.byTooltip(message), findsOneWidget);
      expect(find.bySemanticsLabel(message), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('没有待')), findsNothing);
      expect(find.textContaining('internal failure detail'), findsNothing);
      expect(find.byType(UtenNotificationBadge), findsNothing);

      _refresh(container, changesOnly);
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel('正在加载$queue待办数量'), findsOneWidget);
      next.complete(3);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('3'), findsOneWidget);
      expect(find.bySemanticsLabel('待处理$queue：3项'), findsOneWidget);
      expect(find.byIcon(Icons.sync_problem_outlined), findsNothing);
    });

    testWidgets('$queue confirmed zero becomes loading again on invalidation', (
      tester,
    ) async {
      var calls = 0;
      final next = Completer<int>();
      final container = await _pumpBadge(
        tester,
        changesOnly: changesOnly,
        count: () => ++calls == 1 ? 0 : next.future,
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('没有待处理的$queue'), findsOneWidget);
      expect(find.text('0'), findsNothing);

      _refresh(container, changesOnly);
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel('正在加载$queue待办数量'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('没有待')), findsNothing);
      next.complete(12);
      await tester.pumpAndSettle();
      expect(find.text('12'), findsOneWidget);
      expect(find.bySemanticsLabel('待处理$queue：12项'), findsOneWidget);
    });
  }

  for (final entry in <String, String>{
    'en': 'Pending sales order changes: 2',
    'ko': '대기 중인 판매 주문 변경: 2건',
  }.entries) {
    testWidgets('change badge is localized in ${entry.key}', (tester) async {
      await _pumpBadge(
        tester,
        changesOnly: true,
        count: () => 2,
        locale: Locale(entry.key),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(entry.value), findsOneWidget);
    });
  }

  test(
    'finance hub descriptions match the shared queues and bank transfer',
    () {
      final zh = lookupAppLocalizations(const Locale('zh'));
      final en = lookupAppLocalizations(const Locale('en'));
      final ko = lookupAppLocalizations(const Locale('ko'));
      expect(zh.financeHubTaskApprovalSub, '采购与委外订货审批');
      expect(
        en.financeHubTaskApprovalSub,
        'Purchase and subcontract order approvals',
      );
      expect(ko.financeHubTaskApprovalSub, '구매 및 외주 주문 승인');
      expect(zh.financeHubDocBankTransferSub, '账户之间转账');
    },
  );
}
