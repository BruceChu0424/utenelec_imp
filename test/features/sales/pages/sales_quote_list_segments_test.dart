// 报价列表按财务核价分桶分段(ADR-134)：草稿(红) / 财务退回(红) / 待财务核价(黄) /
// 已核价(红 = 待转订货单) / 作废(括号)，选中分段向服务端传 bucket(服务端 QuoteQueryFilter)；
// 状态列按分桶显示。订货单「从报价引入」弹窗按 bucket=AWAITING_CONVERSION 在服务端筛。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/document_status_counts_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());

  final List<Map<String, dynamic>?> listQueries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/quotes') {
      listQueries.add(query);
      return {
        'items': [
          {
            'id': 'q-returned',
            'billNo': 'XB-R',
            'billDate': '2026-09-27',
            'status': 0,
            'statusBucket': 'FINANCE_REJECTED',
            'financeReturnReason': '客户要改数量',
            'writable': true,
          },
          {
            'id': 'q-converted',
            'billNo': 'XB-C',
            'billDate': '2026-09-27',
            'status': 1,
            'convertedOrderNo': 'XD-1',
            'writable': false,
          },
        ],
        'page': 1,
        'size': 20,
        'total': 2,
        'totalPages': 1,
      };
    }
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<_Api> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(prefs),
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.salesQuoteView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          documentStatusCountsProvider.overrideWith(
            (ref, scope) async => {
              'DRAFT': 3,
              'FINANCE_REJECTED': 1,
              'PENDING_FINANCE': 2,
              'APPROVED': 7,
              'REVERSED': 4,
            },
          ),
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              entries: {BadgeEntry.salesQuoteAwaitingConversion: (5, 0)},
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: SalesDocListPage(docType: SalesDocType.quote),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  UtenSegmentBadgeLabel seg(WidgetTester tester, String label) =>
      tester.widget<UtenSegmentBadgeLabel>(
        find.byWidgetPredicate(
          (w) => w is UtenSegmentBadgeLabel && w.label == label,
        ),
      );

  testWidgets('five finance-pricing buckets with the right count forms', (
    tester,
  ) async {
    final api = await pump(tester);
    expect(api.listQueries, isEmpty, reason: 'no segment selected yet');
    expect(seg(tester, '草稿').count, 3);
    expect(seg(tester, '草稿').countForm, UtenSegmentCountForm.actionable);
    expect(seg(tester, '财务退回').count, 1);
    expect(seg(tester, '财务退回').countForm, UtenSegmentCountForm.actionable);
    expect(seg(tester, '待财务核价').count, 2);
    expect(seg(tester, '待财务核价').countForm, UtenSegmentCountForm.inProgress);
    // 已核价段的红数只数「待转订货单」，与任务中心报价大类同源。
    expect(seg(tester, '已核价').count, 5);
    expect(seg(tester, '已核价').countForm, UtenSegmentCountForm.actionable);
    expect(seg(tester, '作废').count, 4);
    expect(seg(tester, '作废').countForm, UtenSegmentCountForm.browsing);
    expect(find.text('已审'), findsNothing);
    expect(find.text('红冲'), findsNothing);
  });

  testWidgets('selecting a bucket sends bucket and shows bucket status text', (
    tester,
  ) async {
    final api = await pump(tester);
    await tester.tap(find.text('财务退回'));
    await tester.pumpAndSettle();
    expect(api.listQueries.last?['bucket'], SalesQuoteStage.financeRejected);
    expect(api.listQueries.last?.containsKey('stage'), isFalse);
    expect(api.listQueries.last?.containsKey('status'), isFalse);
    // 状态列：退回件显示「财务退回」；已转单的已核价显示「已转订货单 · 只读」。
    expect(find.text('财务退回'), findsWidgets);
    expect(find.text('已转订货单 · 只读'), findsWidgets);

    await tester.tap(find.text('待财务核价'));
    await tester.pumpAndSettle();
    expect(api.listQueries.last?['bucket'], SalesQuoteStage.pendingFinance);
  });

  testWidgets('import from quote asks the server for quotes awaiting '
      'conversion and lists only convertible ones', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _ImportApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(prefs),
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.salesOrderView,
            Perm.salesQuoteConvert,
            Perm.salesOrderCreate,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          fixedBadgeSummaryOverride(),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: SalesDocListPage(docType: SalesDocType.order),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('从报价引入'));
    await tester.pumpAndSettle();
    expect(find.text('选择已核价的报价单'), findsOneWidget);
    expect(api.quoteQueries.single?['bucket'], 'AWAITING_CONVERSION');
    expect(api.quoteQueries.single?.containsKey('status'), isFalse);
    expect(find.text('XB-MINE'), findsOneWidget);
    expect(
      find.text('XB-OTHER'),
      findsNothing,
      reason: 'not convertible by me',
    );
  });
}

class _ImportApi extends ApiClient {
  _ImportApi() : super(Dio());

  final List<Map<String, dynamic>?> quoteQueries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/quotes') {
      quoteQueries.add(query);
      return {
        'items': [
          {
            'id': 'q-mine',
            'billNo': 'XB-MINE',
            'billDate': '2026-09-27',
            'status': 1,
            'statusBucket': 'APPROVED',
            'writable': false,
            'allowedActions': ['convert', 'reopen'],
          },
          {
            'id': 'q-other',
            'billNo': 'XB-OTHER',
            'billDate': '2026-09-27',
            'status': 1,
            'statusBucket': 'APPROVED',
            'writable': false,
            'allowedActions': <String>[],
          },
        ],
        'page': 1,
        'size': 50,
        'total': 2,
        'totalPages': 1,
      };
    }
    return const {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
