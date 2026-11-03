// Explicit local UI acceptance entry point. All records and APIs are synthetic.
// Pass contracts/business-master-references/v1.json in PICKER_FIXTURE via
// --dart-define-from-file. No request is sent to a business server.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _baseGrants = {
  Perm.salesOrderCreate,
  Perm.salesOrderView,
  Perm.salesOrderEdit,
  Perm.salesOrderPriceView,
};

class _Mode extends Notifier<String> {
  @override
  String build() => 'both';
  void choose(String value) => state = value;
}

final _mode = NotifierProvider<_Mode, String>(_Mode.new);
Set<String> _grants(String mode) => {
  ..._baseGrants,
  if (mode != 'no-price') Perm.goodsPriceView,
  if (mode != 'no-discount') Perm.goodsDiscountView,
}..removeAll(mode == 'no-sales-price' ? {Perm.salesOrderPriceView} : {});

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fixture =
      jsonDecode(
            utf8.decode(
              base64Decode(const String.fromEnvironment('PICKER_FIXTURE')),
            ),
          )
          as Map<String, dynamic>;
  final api = _FixtureApi(fixture['goods'] as Map<String, dynamic>);
  final preferences = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://synthetic.invalid/api'),
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_HarnessSession.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'synthetic-picker-acceptance'),
        ),
        currentPermissionsProvider.overrideWith((ref) {
          final grants = _grants(ref.watch(_mode));
          api.grants = grants;
          return grants;
        }),
        isSuperAdminProvider.overrideWithValue(false),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
      ],
      child: const _App(),
    ),
  );
}

class _HarnessSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _App extends ConsumerStatefulWidget {
  const _App();
  @override
  ConsumerState<_App> createState() => _AppState();
}

class _AppState extends ConsumerState<_App> {
  late final router = GoRouter(
    initialLocation: '/sales/orders/new',
    routes: [
      GoRoute(
        path: '/sales/orders/new',
        builder: (_, _) => const SalesDocEditPage(docType: SalesDocType.order),
      ),
      GoRoute(
        path: '/sales/orders',
        builder: (_, state) => SalesDocListPage(
          docType: SalesDocType.order,
          initialStatus: state.uri.queryParameters['status'],
        ),
      ),
      GoRoute(
        path: '/:rest(.*)',
        builder: (_, _) => const Scaffold(body: Center(child: Text('合成验收结束'))),
      ),
    ],
  );
  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    routerConfig: router,
    theme: buildLightTheme(),
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.digit1, alt: true): () =>
            ref.read(_mode.notifier).choose('both'),
        const SingleActivator(LogicalKeyboardKey.digit2, alt: true): () =>
            ref.read(_mode.notifier).choose('no-price'),
      },
      child: Stack(
        children: [
          Column(
            children: [
              Material(
                child: SafeArea(
                  bottom: false,
                  child: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('合成验收 · 1201货品 · 未连接业务服务器'),
                      for (final entry in {
                        'both': '价格和折扣',
                        'no-price': '无货品价格',
                        'no-discount': '无货品折扣',
                        'no-sales-price': '无销售价格',
                      }.entries)
                        TextButton(
                          onPressed: () =>
                              ref.read(_mode.notifier).choose(entry.key),
                          child: Text(entry.value),
                        ),
                      Text('当前: ${ref.watch(_mode)}'),
                    ],
                  ),
                ),
              ),
              Expanded(child: child!),
            ],
          ),
          const Positioned(
            top: 40,
            left: 16,
            right: 16,
            child: AppNotificationHost(),
          ),
        ],
      ),
    ),
  );
}

class _FixtureApi extends ApiClient {
  _FixtureApi(this.goods) : super(Dio());
  final Map<String, dynamic> goods;
  Set<String> grants = _grants('both');
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (path == '/business-references/goods') {
      final keyword = '${query?['keyword'] ?? ''}';
      final size = (query?['size'] as num?)?.toInt() ?? 20;
      final page = (query?['page'] as num?)?.toInt() ?? 1;
      final all =
          List.generate(
                1201,
                (index) => {
                  ...goods,
                  if (index > 0) 'id': 'synthetic-goods-$index',
                  if (index > 0)
                    'name': '合成货品${index.toString().padLeft(4, '0')}',
                  if (index > 0) 'code': '${2801011241 + index}',
                },
              )
              .where(
                (row) =>
                    keyword.isEmpty ||
                    '${row['name']} ${row['code']}'.contains(keyword),
              )
              .toList();
      return {
        'items': all.skip((page - 1) * size).take(size).map((row) {
          if (!grants.contains(Perm.goodsPriceView)) row.remove('price');
          if (!grants.contains(Perm.goodsDiscountView)) row.remove('discount');
          row.remove('stockQty');
          return row;
        }).toList(),
        'page': page,
        'size': size,
        'total': all.length,
        'totalPages': (all.length / size).ceil(),
      };
    }
    if (path.endsWith('/facets')) return {};
    if (path.endsWith('/last-terms')) {
      return {'currencyId': 'cny', 'settlementMethodId': 'cash'};
    }
    return {
      'items': <Map<String, dynamic>>[],
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
    if (path == '/business-references/goods/categories') {
      return [
        {
          'id': goods['categoryId'],
          'code': '28',
          'name': '合成成品',
          'level': 0,
          'children': <Object>[],
        },
      ];
    }
    if (path.contains('currencies')) {
      return [
        {
          'id': 'cny',
          'code': 'CNY',
          'name': '人民币',
          'baseCurrency': true,
          'exchangeRate': 1,
        },
      ];
    }
    if (path.contains('settlement')) {
      return [
        {'id': 'cash', 'code': 'CASH', 'name': '现金'},
      ];
    }
    if (path.contains('units')) {
      return [
        {'id': goods['unitId'], 'code': 'PCS', 'name': '个'},
      ];
    }
    if (path.contains('colors')) {
      return [
        {'id': goods['colorId'], 'name': '灰色'},
      ];
    }
    return [];
  }

  @override
  Future<List<String>> getStringList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [goods['categoryId'] as String];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async => throw StateError('合成验收不提交业务数据');
}
