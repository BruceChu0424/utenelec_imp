// Synthetic only: no business API or database connections.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/widgets/sales_batch_ship_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  runApp(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue(
          Uri.base.resolve('/b1-synthetic-batch-api').toString(),
        ),
        salesMasterNameServiceProvider.overrideWithValue(_Names(api)),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'b1-synthetic-sales'),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.salesShipmentCreate,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(
          InMemorySharedPreferences(),
        ),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: _Harness(api),
      ),
    ),
  );
}

class _Names extends SalesMasterNameService {
  _Names(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsNames(Iterable<String> ids) async {}
  @override
  Future<void> loadClientNames(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '合成产品$id';
  @override
  String client(String? id) => '合成客户';
  @override
  String color(String? id) => '';
  @override
  String unit(String? id) => '箱';
}

class _Api extends ApiClient {
  _Api()
    : super(
        Dio(
          BaseOptions(
            baseUrl: Uri.base.resolve('/b1-synthetic-batch-api').toString(),
          ),
        ),
      );
  final changed = ValueNotifier<int>(0);
  final pageQueries = <Map<String, dynamic>>[];
  final commands = <Map<String, dynamic>>[];
  final ledger = <String, String>{};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  bool loseFirstSubmit = true;
  void notify() => Future<void>.delayed(Duration.zero, () => changed.value++);
  List<int> matches(Map<String, dynamic> query) {
    final keyword = query['keyword']?.toString() ?? '';
    return [
      for (var index = 1; index <= 1000; index++)
        if (keyword.isEmpty ||
            keyword == '合法' && index <= 500 ||
            keyword == '末端' && index >= 999 ||
            'SO-${index.toString().padLeft(4, '0')}'.contains(keyword))
          index,
    ];
  }

  Map<String, dynamic> line(int index) => {
    'orderItemId': 'line-$index',
    'orderId': 'order-$index',
    'billNo': 'SO-${index.toString().padLeft(4, '0')}',
    'goodsId': '$index',
    'clientId': 'synthetic-client',
    'reservedQty': 10,
    'writable': true,
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/sales/orders/shippable-lines/page') return {};
    final parameters = Map<String, dynamic>.of(query!);
    pageQueries.add(parameters);
    notify();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final ids = matches(parameters);
    final page = parameters['page'] as int;
    final size = parameters['size'] as int;
    return {
      'items': ids.skip((page - 1) * size).take(size).map(line).toList(),
      'page': page,
      'size': size,
      'total': ids.length,
      'totalPages': (ids.length / size).ceil(),
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path != '/sales/orders/shippable-lines/selection') {
      throw StateError('Harness forbids business writes');
    }
    final ids = matches(Map<String, dynamic>.from(body! as Map));
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    if (ids.length > 500) {
      throw ApiException(
        'VALIDATION_FAILED',
        '可发行超过单批500行，请按客户或关键词收窄后再全选',
        httpStatus: 400,
      );
    }
    return {
      'items': ids.map(line).toList(),
      'page': 1,
      'size': 500,
      'total': ids.length,
      'totalPages': ids.isEmpty ? 0 : 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    if (path != '/sales/shipments/batch') {
      throw StateError('Harness forbids business writes');
    }
    final request = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(body)) as Map,
    );
    commands.add(request);
    notify();
    final key = request['idempotencyKey'] as String;
    final encoded = jsonEncode(request);
    if (ledger[key] != null && ledger[key] != encoded) {
      throw StateError('Frozen command changed');
    }
    ledger[key] = encoded;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (loseFirstSubmit) {
      loseFirstSubmit = false;
      throw NetworkTimeoutException();
    }
    return [
      {'id': 'synthetic-shipment'},
    ];
  }
}

class _Harness extends ConsumerWidget {
  const _Harness(this.api);
  final _Api api;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('B1 批量发货纯合成验证')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '1000行，每页100；全选超过500必须收窄。搜索“合法”得到500行，搜索“末端”得到999/1000行。第一次合成提交丢失回执，再次确认必须保持原键、日期、全部行。',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => showSalesBatchShipPanel(context, ref),
            child: const Text('打开合成批量发货'),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<int>(
            valueListenable: api.changed,
            builder: (_, _, _) => SelectableText(
              '浏览请求 ${api.pageQueries.length} 次，开单请求 ${api.commands.length} 次，唯一幂等键 ${api.ledger.length} 个\n'
              '全部请求纯内存，无业务网络或数据库写入。\n'
              '${api.commands.map((command) => jsonEncode(command)).join('\n')}',
            ),
          ),
        ],
      ),
    ),
  );
}
