import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_detail_summary_card.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/native_detail_reader_overrides.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import '../../support/uten_test_actions.dart';

const _captureParty = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_PARTY');

void main() {
  for (final type in [FinanceDocType.receipt, FinanceDocType.payment]) {
    for (final mode in ['list', 'detail', 'edit']) {
      testWidgets(
        '${type.name} $mode shows authorized document party when master lookup is forbidden',
        (tester) async {
          final api = await _open(tester, type, mode, 0);
          expect(
            find.text(type == FinanceDocType.receipt ? '客户甲' : '供应商甲'),
            findsWidgets,
          );
          expect(tester.takeException(), isNull);
          expect(api.writes, 0);
          expect(api.forbiddenPartyReads, greaterThan(0));
          await api.closeFixture!();
        },
      );
    }
  }
  for (final entry in {0: '待审核金额', 1: '已审核金额', -1: '历史金额'}.entries) {
    testWidgets(
      'receipt status${entry.key} keeps original amount names and adjacent state hint',
      (tester) async {
        final api = await _open(
          tester,
          FinanceDocType.receipt,
          'detail',
          entry.key,
        );
        expect(find.text(entry.value), findsOneWidget);
        final metrics = tester
            .widgetList<UtenSummaryField>(find.byType(UtenSummaryField))
            .where(
              (w) => const [
                '本批客户支付/核销原币',
                '本批客户已付',
                '真实账户实际入账',
                '实际入账本位币',
              ].any((prefix) => w.label.startsWith(prefix)),
            )
            .toList();
        expect(metrics, hasLength(4));
        final amounts = metrics
            .map((m) => m.value?.replaceAll(',', '') ?? '')
            .toList();
        expect(amounts.where((v) => v.startsWith('400')), hasLength(2));
        expect(amounts.where((v) => v.startsWith('2800')), hasLength(2));
        for (final metric in metrics) {
          expect(metric.info, contains('本收款单结算批次'));
          expect(
            metric.info,
            contains(
              entry.key == 0
                  ? '尚未计入系统账户流水'
                  : entry.key == 1
                  ? '已审核'
                  : '历史金额',
            ),
          );
          expect(metric.info, contains('银行实际到账为账户金额'));
        }
        expect(tester.takeException(), isNull);
        if (_captureParty) {
          await saveAuditScreenshot(
            tester,
            api.captureKey,
            'finance-receipt-state-${entry.key}-fx-400-2800',
          );
        }
        await api.closeFixture!();
      },
    );
  }
}

Future<_Api> _open(
  WidgetTester tester,
  FinanceDocType type,
  String mode,
  int status,
) async {
  await setUtenTestSurfaceSize(tester, const Size(1440, 1000));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  if (_captureParty) {
    await loadAuditScreenshotFonts(tester);
  }
  SharedPreferences.setMockInitialValues({});
  final api = _Api(type, status);
  final permissions = {
    Perm.financeViewAll,
    type == FinanceDocType.receipt
        ? Perm.financeReceiptView
        : Perm.financePaymentView,
    if (mode == 'edit')
      type == FinanceDocType.receipt
          ? Perm.financeReceiptEdit
          : Perm.financePaymentEdit,
  };
  final container = ProviderContainer(
    overrides: [
      ...nativeDetailReaderOverrides(),
      apiClientProvider.overrideWithValue(api),
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
    ],
  );
  final router = GoRouter(
    initialLocation: '/fixture',
    routes: [
      GoRoute(
        path: '/fixture',
        builder: (_, _) => mode == 'list'
            ? FinanceDocListPage(docType: type, initialStatus: 'draft')
            : mode == 'edit'
            ? FinanceDocEditPage(docType: type, id: 'test-document')
            : FinanceDocDetailPage(docType: type, id: 'test-document'),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: api.captureKey,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: auditScreenshotTheme(buildLightTheme()),
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  var closed = false;
  api.closeFixture = () async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    container.dispose();
  };
  addTearDown(() => api.closeFixture!());
  return api;
}

class _Api extends ApiClient {
  _Api(this.type, this.status) : super(Dio());
  final FinanceDocType type;
  final int status;
  final captureKey = GlobalKey();
  int writes = 0;
  int forbiddenPartyReads = 0;
  Future<void> Function()? closeFixture;
  Map<String, dynamic> get document => {
    'id': 'test-document',
    'billNo': 'FIN-EXAMPLE',
    'version': 0,
    'makerId': 'native-detail-reader',
    'status': status,
    'billDate': '2026-11-05',
    if (type == FinanceDocType.receipt) ...{
      'receiptKind': 'AR_SETTLEMENT',
      'clientId': '10000000-0000-0000-0000-000000000001',
      'clientName': '客户甲',
    } else ...{
      'supplierId': '20000000-0000-0000-0000-000000000002',
      'supplierName': '供应商甲',
    },
    'accountId': 'bank',
    'currencyId': 'usd',
    'exchangeRate': 7,
    'amountOriginal': 400,
    'amountLocal': 2800,
    'settlementGrossLocal': 2800,
    'settlementAuthorityVersion': 2,
    'amountAuthorityVersion': 2,
    'settlementChannel': 'DIRECT_ACCOUNT',
    'accountCurrencyId': 'usd',
    'accountAmount': 400,
    'accountAmountLocal': 2800,
    'accountExchangeRate': 7,
    'items': [
      {
        'id': 'line',
        'appliedLedgerId': 'ar',
        'appliedBillNo': 'AR-EXAMPLE',
        'currencyId': 'usd',
        'amountOriginal': 400,
        'amountLocal': 2800,
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/test-document')) {
      return document;
    }
    if (path == '/finance/${type.pathSegment}') {
      return {
        'items': [document],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    return {
      'items': <dynamic>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/clients') || path.contains('/suppliers')) {
      forbiddenPartyReads++;
      throw ApiException('FORBIDDEN', 'No party master authority');
    }
    if (path.contains('accounts')) {
      return [
        {
          'id': 'bank',
          'name': '授权收付款账户',
          'currencyId': 'usd',
          'currencyName': '美元',
          'status': '使用',
        },
      ];
    }
    if (path.contains('currencies')) {
      return [
        {
          'id': 'usd',
          'name': '美元',
          'code': 'USD',
          'exchangeRate': 7,
          'baseCurrency': false,
        },
        {
          'id': 'cny',
          'name': '人民币',
          'code': 'CNY',
          'exchangeRate': 1,
          'baseCurrency': true,
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    writes++;
    return {};
  }
}
