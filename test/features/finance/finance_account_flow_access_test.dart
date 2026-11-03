import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/finance/pages/finance_account_flow_page.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/uten_test_actions.dart';

const _accountRead = {
  Perm.accountView,
  Perm.accountBalanceView,
  Perm.accountFlowView,
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <String>[];
  final writes = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.startsWith('/finance/reports/')) return {};
    reads.add(path);
    return {
      'columns': [
        {'key': 'billNo', 'label': '单据号', 'type': 'text'},
      ],
      'rows': <Map<String, dynamic>>[],
      'facets': <String, dynamic>{},
      'page': 1,
      'total': 0,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add(path);
    return {};
  }
}

class _Prefs extends FinanceAccountFlowReportPrefsNotifier {
  _Prefs(this.mode);
  final String mode;

  @override
  ReportFilterPrefs build() =>
      ReportFilterPrefs(docType: mode, extra: const {'accountId': 'account-1'});
}

class _Names extends FinanceNameService {
  _Names(ApiClient api) : super(api, DioPaymentStyleRepository(api));

  @override
  Future<void> ensureLoaded({
    bool refreshAccounts = false,
    bool includeCounterparties = true,
  }) async {}

  @override
  Map<String, String> get accountEntries => const {'account-1': '测试账户'};
}

Future<_Api> _mount(
  WidgetTester tester, {
  required String mode,
  required Set<String> grants,
}) async {
  await setUtenTestSurfaceSize(tester, const Size(1800, 1200));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = _Api();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(
            userId: 'account-report-reader',
            readOnly: true,
          ),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeReportView,
          Perm.financeReportExport,
          ...grants,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        financeAccountFlowReportPrefsProvider.overrideWith(() => _Prefs(mode)),
        financeNameServiceProvider.overrideWith((ref) => _Names(api)),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: FinanceAccountFlowPage(),
      ),
    ),
  );
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  await tester.pumpAndSettle();
  return api;
}

void _expectControls(WidgetTester tester, bool enabled) {
  expect(
    tester
        .widget<UtenPrintPreviewButton>(find.byType(UtenPrintPreviewButton))
        .enabled,
    enabled,
  );
  expect(
    tester.widget<UtenExportButton>(find.byType(UtenExportButton)).enabled,
    enabled,
  );
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'statement reader can print and export without company-wide finance',
    (tester) async {
      final api = await _mount(tester, mode: 'statement', grants: _accountRead);
      expect(api.reads, contains('/finance/reports/account/statement'));
      _expectControls(tester, true);
      expect(api.writes, isEmpty);
    },
  );

  for (final missing in _accountRead) {
    testWidgets('company-wide finance cannot replace statement $missing', (
      tester,
    ) async {
      final api = await _mount(
        tester,
        mode: 'statement',
        grants: {..._accountRead, Perm.financeViewAll}..remove(missing),
      );
      _expectControls(tester, false);
      expect(api.writes, isEmpty);
    });
  }

  for (final mode in ['bankDetail', 'bankSummary']) {
    testWidgets('$mode keeps the company-wide finance boundary', (
      tester,
    ) async {
      final api = await _mount(tester, mode: mode, grants: _accountRead);
      _expectControls(tester, false);
      expect(api.writes, isEmpty);
    });
    testWidgets('$mode enables controls only with all required read grants', (
      tester,
    ) async {
      final api = await _mount(
        tester,
        mode: mode,
        grants: {..._accountRead, Perm.financeViewAll},
      );
      _expectControls(tester, true);
      expect(api.writes, isEmpty);
    });
  }
}
