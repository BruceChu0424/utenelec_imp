import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/pages/finance_applications_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'finance-user',
      employeeId: 'finance-employee',
      code: 'F001',
      name: '财务经办',
      department: '财务',
    ),
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  final List<({String path, Map<String, dynamic>? query})> queries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add((path: path, query: query));
    if (path.endsWith('/catalog')) return <String, dynamic>{};
    return <String, dynamic>{
      'rows': [
        {
          'id': 'fa-1',
          'application_no': 'FK20261104000001',
          'kindLabel': '付款申请',
          'title': '样例付款',
          'status': 'PENDING',
        },
      ],
      'total': 1,
    };
  }
}

Future<void> _pump(WidgetTester tester, _Api api) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://finance.test/api'),
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeApplicationReview,
          Perm.financeApplicationApply,
        }),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: const FinanceApplicationsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'refresh sits in the app bar and the category row keeps only create',
    (tester) async {
      // 2026-11-04 刷新按钮归位：不再放分类栏行尾，与其他任务中心同位右上角
      // AppBar；行尾只保留「新增」。同时分类行进折叠头（上滑先把表格钉顶）。
      final api = _Api();
      await _pump(tester, api);
      final refresh = find.byType(UtenRefreshButton);
      expect(refresh, findsOneWidget);
      expect(
        find.ancestor(of: refresh, matching: find.byType(UtenAppBar)),
        findsOneWidget,
        reason: '刷新按钮应位于右上角 AppBar',
      );
      // 全页唯一的「刷新」按钮（AppBar 形态 UtenButton）就在 AppBar 里，
      // 分类栏行尾不再出现第二个。
      expect(
        find.widgetWithText(UtenButton, '刷新'),
        findsOneWidget,
        reason: '全页只保留一枚刷新按钮',
      );
      expect(
        find.descendant(
          of: find.byType(UtenAppBar),
          matching: find.widgetWithText(UtenButton, '刷新'),
        ),
        findsOneWidget,
        reason: '刷新按钮应位于右上角 AppBar，不在分类栏行内',
      );
      expect(find.widgetWithText(UtenButton, '新增'), findsOneWidget);
      expect(
        find.byType(UtenCollapsingHeaderScrollView),
        findsOneWidget,
        reason: '分类行应进折叠头，上滑先把表格钉顶',
      );
      expect(
        api.queries.where((q) => q.path == '/finance/applications'),
        isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
