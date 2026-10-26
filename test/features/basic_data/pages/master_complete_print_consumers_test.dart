import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/features/basic_data/pages/account_workspace_page.dart';
import 'package:uten_imp/features/basic_data/pages/client_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/color_page.dart';
import 'package:uten_imp/features/basic_data/pages/currency_page.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/supplier_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/pages/warehouse_page.dart';
import 'package:uten_imp/features/basic_data/pages/settlement_method_page.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../shared/drafts/memory_form_draft_storage.dart';

const _domains = [
  'goods',
  'clients',
  'suppliers',
  'accounts',
  'currencies',
  'colors',
  'units',
  'moulds',
  'warehouses',
  'settlement_methods',
];
const _permissions = {
  'goods:view',
  'client:view',
  'supplier:view',
  'account:view',
  'currency:view',
  'color:view',
  'unit:view',
  'mould:view',
  'warehouse:view',
  'stock:view',
  'settlement_method:view',
};

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'synthetic-print',
      code: 'SYNTHETIC',
      name: '合成查看员',
      permissions: _permissions.toList(),
    ),
  );
}

class _Fixture {
  _Fixture(this.domain) {
    final dio = Dio(BaseOptions(baseUrl: 'https://synthetic.invalid/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          final path = request.path;
          Object value = <String, dynamic>{};
          final root = domain == 'settlement_methods'
              ? '/master/reference-methods/settlement-admin'
              : '/master/$domain';
          if (path == root || path == '$root/search' || path == '$root/page') {
            final page =
                (request.queryParameters['page'] as num?)?.toInt() ?? 1;
            final size =
                ((request.queryParameters['size'] as num?)?.toInt() ?? 20)
                    .clamp(1, 100);
            calls.add((page: page, size: size));
            if (page == 2 && size == 100) await holdSecond?.future;
            value = {
              'items': rows.skip((page - 1) * size).take(size).toList(),
              'page': page,
              'size': size,
              'total': rows.length,
              'totalPages': (rows.length / size).ceil(),
            };
          } else if (path == '$root/dict') {
            value = rows;
          } else if (path.endsWith('/tree') || path.endsWith('/subtree')) {
            value = path.contains('categories') ? [category] : <Object>[];
          } else if (path.contains('categories') && !path.endsWith('/facets')) {
            value = category;
          } else if (path.endsWith('/facets')) {
            value = {
              'fields': <String, Object>{},
              'nullCounts': <String, int>{},
            };
          } else if (path.endsWith('/dict') ||
              path.endsWith('/lookup') ||
              path.endsWith('/scopes') ||
              path.endsWith('/assignments') ||
              path.contains('/reference-methods/') ||
              path.endsWith('/workshops')) {
            value = <Object>[];
          } else if (path.contains('/stock/')) {
            value = {
              'items': <Object>[],
              'page': 1,
              'size': 100,
              'total': 0,
              'totalPages': 0,
            };
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: value,
            ),
          );
        },
      ),
    );
    api = ApiClient(dio);
  }
  final String domain;
  late final ApiClient api;
  final calls = <({int page, int size})>[];
  Completer<void>? holdSecond;
  static const category = {
    'id': '20000000-0000-4000-8000-000000000001',
    'code': 'CAT',
    'name': '合成类别',
    'level': 0,
    'path': '/CAT/',
    'children': <Object>[],
    'childCount': 0,
  };
  late final rows = List.generate(
    601,
    (index) => <String, dynamic>{
      'id': '10000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
      'code': domain == 'warehouses' && index == 0 ? '001' : 'CODE$index',
      'name': '合成原名龘$index',
      'status': '使用',
      'categoryId': category['id'],
      'version': 1,
      'writable': false,
      'exchangeRate': 1,
      'baseCurrency': index == 0,
      'parentId': index == 0 ? null : '10000000-0000-4000-8000-000000000000',
      'accountable': true,
      'lineSide': false,
      'defective': false,
      'selectableForNew': true,
      'accountType': 'BANK',
      'currencyName': '人民币',
      'fullName': '合成原名龘$index',
    },
  );
}

Widget _page(String domain) => switch (domain) {
  'goods' => const ProductCategoryPage(),
  'clients' => const ClientCategoryPage(),
  'suppliers' => const SupplierCategoryPage(),
  'accounts' => const AccountPage(),
  'currencies' => const CurrencyPage(),
  'colors' => const ColorPage(),
  'units' => const UnitPage(),
  'moulds' => const MouldCategoryPage(),
  'warehouses' => const WarehousePage(),
  'settlement_methods' => const SettlementMethodPage(),
  _ => throw StateError(domain),
};

Future<ProviderContainer> _pump(WidgetTester tester, _Fixture fixture) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'synthetic-print'),
        ),
        currentPermissionsProvider.overrideWithValue(_permissions),
        isSuperAdminProvider.overrideWithValue(false),
        apiClientProvider.overrideWithValue(fixture.api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _page(fixture.domain),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(_page(fixture.domain).runtimeType)),
  );
}

void main() {
  for (final domain in _domains) {
    testWidgets(
      '$domain actual page prints every authorized server page beyond 500',
      (tester) async {
        final fixture = _Fixture(domain);
        await _pump(tester, fixture);
        fixture.calls.clear();
        expect(find.text('预览打印'), findsWidgets);
        await tester.tap(find.text('预览打印').first);
        await tester.pumpAndSettle();
        expect(find.textContaining('共 601 行'), findsWidgets);
        expect(
          fixture.calls
              .where((call) => call.size == 100)
              .map((call) => call.page),
          orderedEquals([1, 2, 3, 4, 5, 6, 7]),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a scope revision during a real shared pane print never publishes its late pages',
    (tester) async {
      final fixture = _Fixture('goods')..holdSecond = Completer<void>();
      final container = await _pump(tester, fixture);
      await tester.tap(find.text('预览打印').first);
      await tester.pump(const Duration(milliseconds: 100));
      container.read(readScopeRevisionProvider.notifier).state++;
      await tester.pump();
      fixture.holdSecond!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('共 601 行'), findsNothing);
      expect(find.text('账号、服务器或权限已变化，请关闭后重新预览'), findsOneWidget);
    },
  );
}
