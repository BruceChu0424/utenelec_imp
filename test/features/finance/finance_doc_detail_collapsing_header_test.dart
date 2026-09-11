// 钱流单据详情页 2026-09-11 折叠头改版回归：
// 有明细表的单据「先滚页面收头部（表头卡/凭证）、再滚明细表内部」；
// 客户预收（无明细表）保持整页滚动；三视口叠 textScale 1.5 不溢出。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/collapsing_header_harness.dart';

class _ReceiptApi extends ApiClient {
  _ReceiptApi({this.prepayment = false}) : super(Dio());

  static const documentId = 'e65a0a91-4302-430b-adc6-f8277a947893';
  static const makerId = '88c21312-0a3e-4e03-a872-9acbff33cf37';
  final bool prepayment;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('scope')) {
      return {
        'scope': 'finance',
        'writeAll': false,
        'writableOwnerIds': [makerId],
      };
    }
    return {
      'id': documentId,
      'billNo': 'SK-20260911-001',
      'billDate': '2026-09-11',
      'makerId': makerId,
      'status': 0,
      'closed': false,
      'receiptKind': prepayment ? 'CUSTOMER_PREPAYMENT' : 'RECEIVABLE',
      'items': <Object>[
        for (var i = 0; i < 16; i++)
          <String, dynamic>{
            'id': 'fi-$i',
            'amountLocal': (i + 1) * 100,
            'remark': '收款行$i',
          },
      ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
  bool prepayment = false,
}) async {
  useUtenViewport(tester, size);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(
          _ReceiptApi(prepayment: prepayment),
        ),
        currentPermissionsProvider.overrideWithValue(const <String>{
          Perm.financeReceiptView,
          Perm.financeReceiptEdit,
          Perm.financeViewAll,
          Perm.customerPrepaymentView,
          Perm.attachmentView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: utenTextScaleBuilder(textScale),
        home: const FinanceDocDetailPage(
          docType: FinanceDocType.receipt,
          id: 'route-id',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('收款单详情：上滚先收表头卡，明细表接着内滚', (tester) async {
    await _pump(tester, size: const Size(1280, 900));

    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    expect(find.text('明细 (16)'), findsOneWidget);
    await expectUtenHeaderCollapses(
      tester,
      headerAnchor: find.text('单据号'),
      bodyAnchor: find.byType(MasterDataTableView<FinanceDocItem>),
    );
    expect(find.text('明细 (16)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('客户预收（无明细表）保持整页滚动，不套折叠容器', (tester) async {
    await _pump(tester, size: const Size(1280, 900), prepayment: true);

    expect(find.byType(UtenCollapsingHeaderScrollView), findsNothing);
    expect(find.byType(MasterDataTableView<FinanceDocItem>), findsNothing);
    expect(find.text('单据号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final viewport in utenCollapsingViewports) {
    testWidgets('收款单详情 ${viewport.label} · textScale 1.5 不溢出', (tester) async {
      await _pump(tester, size: viewport.size, textScale: 1.5);
      await expectUtenBodyReachable(
        tester,
        bodyAnchor: find.byType(MasterDataTableView<FinanceDocItem>),
      );
    });
  }
}
