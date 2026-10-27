import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/settlement_method_admin.dart';
import 'package:uten_imp/features/basic_data/pages/settlement_method_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Api extends ApiClient {
  _Api()
    : super(
        Dio(BaseOptions(baseUrl: 'https://settlement-synthetic.invalid/api')),
      );
  final calls = <({int page, String keyword})>[];
  Completer<Map<String, dynamic>>? nextPage;
  String marker = '结算方式';
  int writes = 0;
  Map<String, dynamic> row(int id, {String? name}) => {
    'id': 'method-$id',
    'code': 'M$id',
    'name': name ?? '$marker$id',
    'status': '使用',
    'termsBase': 'RECEIPT_DATE',
    'dueRule': 'NET_DAYS',
    'defaultDueDays': 0,
    'monthsAhead': 0,
  };
  Map<String, dynamic> page(int page, {String keyword = ''}) => {
    'items': keyword.isEmpty
        ? [for (var n = (page - 1) * 100 + 1; n <= page * 100; n++) row(n)]
        : [row(9999, name: '全库末端')],
    'page': page,
    'size': 100,
    'total': keyword.isEmpty ? 10000 : 1,
    'totalPages': keyword.isEmpty ? 100 : 1,
    'readScopeVersion': 'fixture-v1',
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/settlement-admin/page')) {
      final number = (query?['page'] as num?)?.toInt() ?? 1;
      final keyword = query?['keyword']?.toString() ?? '';
      calls.add((page: number, keyword: keyword));
      final gate = nextPage;
      nextPage = null;
      if (gate != null) return await gate.future;
      return page(number, keyword: keyword);
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/settlement-admin')) {
      throw StateError('UI must use bounded pages');
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes++;
    return {};
  }
}

Future<ProviderContainer> _pump(WidgetTester tester, _Api api) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue(
        'https://settlement-synthetic.invalid/api',
      ),
      sharedPreferencesProvider.overrideWithValue(prefs),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'synthetic-reader'),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.settlementMethodView,
        Perm.settlementMethodEdit,
        Perm.settlementMethodCreate,
        Perm.settlementMethodExport,
      }),
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshots.new),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettlementMethodPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder get _table =>
    find.byType(MasterDataTableView<SettlementMethodAdminItem>);
Finder get _search => find.descendant(
  of: find.byType(UtenSearchBar),
  matching: find.byType(TextField),
);
void main() {
  testWidgets(
    'settlement prepares two adjacent pages and search wins over a delayed old page',
    (tester) async {
      final api = _Api();
      await _pump(tester, api);
      expect(api.calls, [
        (page: 1, keyword: ''),
        (page: 2, keyword: ''),
        (page: 3, keyword: ''),
      ]);
      expect(
        tester
            .widget<MasterDataTableView<SettlementMethodAdminItem>>(_table)
            .currentPage,
        1,
      );
      expect(
        tester
            .widget<MasterDataTableView<SettlementMethodAdminItem>>(_table)
            .items,
        hasLength(100),
      );
      final gate = Completer<Map<String, dynamic>>();
      api.nextPage = gate;
      tester
          .widget<MasterDataTableView<SettlementMethodAdminItem>>(_table)
          .onPageChange!(4);
      await tester.pump();
      expect(api.calls.last, (page: 4, keyword: ''));
      await tester.enterText(_search, '末端');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(api.calls, [
        (page: 1, keyword: ''),
        (page: 2, keyword: ''),
        (page: 3, keyword: ''),
        (page: 4, keyword: ''),
        (page: 1, keyword: '末端'),
      ]);
      expect(
        tester
            .widget<MasterDataTableView<SettlementMethodAdminItem>>(_table)
            .items
            .single
            .id,
        'method-9999',
      );
      gate.complete(api.page(4));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MasterDataTableView<SettlementMethodAdminItem>>(_table)
            .items
            .single
            .id,
        'method-9999',
      );
      expect(tester.widget<TextField>(_search).controller!.text, '末端');
      expect(
        tester
            .widget<MasterDataTableView<SettlementMethodAdminItem>>(_table)
            .currentPage,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'same-reader scope ABA retires old page and late responses without resetting auth',
    (tester) async {
      final api = _Api();
      final container = await _pump(tester, api);
      final identity = container.read(authenticatedScopeProvider),
          permissions = container.read(currentPermissionsProvider);
      final stale = api.page(1);
      final gate = Completer<Map<String, dynamic>>();
      api.nextPage = gate;
      container.read(readScopeRevisionProvider.notifier).state++;
      await tester.pump();
      await tester.pump();
      api.marker = '新范围';
      container.read(readScopeRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();
      gate.complete(stale);
      await tester.pumpAndSettle();
      expect(container.read(authenticatedScopeProvider), identity);
      expect(container.read(currentPermissionsProvider), permissions);
      expect(
        tester
            .widget<MasterDataTableView<SettlementMethodAdminItem>>(_table)
            .items
            .first
            .name,
        '新范围1',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a terms modal keeps its form but a scope ABA cannot submit the old callback',
    (tester) async {
      final api = _Api();
      final container = await _pump(tester, api);
      final view = tester
          .widget<MasterDataTableView<SettlementMethodAdminItem>>(_table);
      expect(view.onRowTap, isNotNull);
      view.onRowTap!(view.items.first);
      await tester.pumpAndSettle();
      final form = tester.state(find.byType(MasterEditForm));
      final save = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '保存'))
          .onPressed!;
      container.read(readScopeRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();
      container.read(readScopeRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();
      expect(find.text('原输入已保留，此窗口不会提交'), findsOneWidget);
      expect(
        tester.state(find.byType(MasterEditForm, skipOffstage: false)),
        same(form),
      );
      await Future<void>.sync(save);
      await tester.pumpAndSettle();
      expect(api.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
