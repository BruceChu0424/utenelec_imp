import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/config/sales_doc_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/pages/sales_order_progress_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _DraftApi extends ApiClient {
  _DraftApi() : super(Dio());

  final deleted = <String>[];
  final details = <String>[];
  final changedIds = <String>{};
  final removed = <String>{};
  bool mixed = false;

  Map<String, dynamic> row(String id, {bool writable = true, int status = 0}) =>
      {
        'id': id,
        'billNo': id,
        'billDate': '2026-09-26',
        'status': status,
        'writable': writable,
        'items': <Object>[],
      };

  Map<String, dynamic> page(List<Map<String, dynamic>> items) => {
    'items': items,
    'page': 1,
    'size': 20,
    'total': items.length,
    'totalPages': 1,
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/stage-counts')) return {'DRAFT': 2};
    if (path.contains('facets') || path.endsWith('/stats')) return {};
    if (path.endsWith('/progress')) {
      return page([
        for (final id in ['draft-a', 'draft-b'])
          if (!removed.contains(id))
            {'orderId': id, 'billNo': id, 'stage': 'DRAFT'},
      ]);
    }
    if (path.contains('/draft-') || path.endsWith('/readonly')) {
      final id = path.split('/').last;
      details.add(id);
      return row(id, status: changedIds.contains(id) ? 1 : 0);
    }
    if (path.startsWith('/sales/')) {
      return page([
        for (final id in ['draft-a', 'draft-b'])
          if (!removed.contains(id)) row(id),
        if (mixed) row('readonly', writable: false),
        if (mixed) row('approved', status: 1),
        if (mixed) {...row('pending'), 'financeAudit': 1},
      ]);
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async => {};

  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    final id = path.split('/').last;
    deleted.add(id);
    removed.add(id);
  }
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget page,
    _DraftApi api,
    Set<String> permissions,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(api),
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(false),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'seller'),
          ),
          fixedBadgeSummaryOverride(),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> deleteSelected(WidgetTester tester) async {
    await tester.tap(find.textContaining('删除所选草稿 ('));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 张'), findsOneWidget);
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
  }

  for (final type in [
    SalesDocType.order,
    SalesDocType.quote,
    SalesDocType.shipment,
    SalesDocType.customerShipment,
    SalesDocType.returnDoc,
  ]) {
    testWidgets('${type.name}草稿前置全选，确认后删除并刷新', (tester) async {
      final api = _DraftApi();
      final cfg = SalesDocConfig.by(type);
      await pump(
        tester,
        SalesDocListPage(docType: type, initialStatus: 'draft'),
        api,
        {cfg.listPerm, cfg.deletePerm!},
      );
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('删除所选草稿 (2)'), findsOneWidget);
      await deleteSelected(tester);
      expect(api.deleted, ['draft-a', 'draft-b']);
      expect(api.details, ['draft-a', 'draft-b']);
      expect(find.text('draft-a'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('出货待财审、已审及只读行不能混入草稿全选', (tester) async {
    final api = _DraftApi()..mixed = true;
    await pump(
      tester,
      const SalesDocListPage(
        docType: SalesDocType.shipment,
        initialStatus: 'draft',
      ),
      api,
      {Perm.salesShipmentView, Perm.salesShipmentDelete},
    );
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<Object>>(
      find.byWidgetPredicate((w) => w is MasterDataTableView<Object>),
    );
    expect(table.selectedIds, {'draft-a', 'draft-b'});
    await deleteSelected(tester);
    expect(api.deleted, ['draft-a', 'draft-b']);
  });

  testWidgets('没有删除权限不显示勾选和删除按钮', (tester) async {
    await pump(
      tester,
      const SalesDocListPage(
        docType: SalesDocType.order,
        initialStatus: 'draft',
      ),
      _DraftApi(),
      {Perm.salesOrderView},
    );
    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('删除所选草稿'), findsNothing);
  });

  testWidgets('订货进度草稿支持删除，最新已审单保留且不发DELETE', (tester) async {
    final api = _DraftApi()..changedIds.add('draft-b');
    await pump(tester, const SalesOrderProgressPage(), api, {
      Perm.salesOrderView,
      Perm.salesOrderDelete,
    });
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await deleteSelected(tester);
    expect(api.deleted, ['draft-a']);
    final table = tester.widget<MasterDataTableView<Object>>(
      find.byWidgetPredicate(
        (w) => w is MasterDataTableView<Object>,
      ),
    );
    expect(table.selectedIds, {'draft-b'});
    expect(tester.takeException(), isNull);
  });
}
