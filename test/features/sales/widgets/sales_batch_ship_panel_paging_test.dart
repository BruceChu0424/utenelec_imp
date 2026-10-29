import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/layout/uten_paged_picker_list.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/sales/widgets/sales_batch_ship_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../../helpers/badge_summary_fixture.dart';

final _permissions = StateProvider<Set<String>>(
  (ref) => {Perm.salesShipmentCreate},
);

final _server = StateProvider<String>((ref) => 'https://fixture.invalid/api');
final _identity = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'sales-reader'),
);

class _Names extends SalesMasterNameService {
  _Names(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsNames(Iterable<String> ids) async {}
  @override
  Future<void> loadClientNames(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '产品$id';
  @override
  String client(String? id) => '客户$id';
  @override
  String color(String? id) => '';
  @override
  String unit(String? id) => '箱';
}

class _Api extends ApiClient {
  _Api({this.total = 301})
    : super(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));
  final int total;
  final queries = <Map<String, dynamic>>[];
  final selections = <Map<String, dynamic>>[];
  final commands = <Map<String, dynamic>>[];
  Set<int> readOnly = {};
  bool loseFirstSubmit = false;
  Completer<void>? pageGate;
  Completer<void>? selectionGate;
  Completer<void>? submitGate;
  int? truncatedSelection;
  Object? pageError;

  Map<String, dynamic> line(int index) => {
    'orderItemId': 'line-$index',
    'orderId': 'order-$index',
    'billNo': 'SO-$index',
    'clientId': 'client-a',
    'goodsId': 'goods-$index',
    'reservedQty': 10,
    'writable': !readOnly.contains(index),
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/sales/orders/shippable-lines/page') return {};
    final parameters = Map<String, dynamic>.of(query!);
    queries.add(parameters);
    await pageGate?.future;
    if (pageError != null) throw pageError!;
    final page = parameters['page'] as int;
    final size = parameters['size'] as int;
    final matches = parameters['keyword'] == 'none' ? 0 : total;
    return {
      'items': [
        for (
          var i = (page - 1) * size + 1;
          i <= page * size && i <= matches;
          i++
        )
          line(i),
      ],
      'page': page,
      'size': size,
      'total': matches,
      'totalPages': (matches / size).ceil(),
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/sales/orders/shippable-lines/selection');
    selections.add(Map<String, dynamic>.from(body! as Map));
    await selectionGate?.future;
    final rows = [
      for (var i = 1; i <= total; i++)
        if (!readOnly.contains(i)) line(i),
    ];
    if (rows.length > 500) {
      throw ApiException(
        'VALIDATION_FAILED',
        '可发行超过单批500行，请按客户或关键词收窄后再全选',
        httpStatus: 400,
      );
    }
    return {
      'items': truncatedSelection == null
          ? rows
          : rows.take(truncatedSelection!).toList(),
      'page': 1,
      'size': 500,
      'total': rows.length,
      'totalPages': rows.isEmpty ? 0 : 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> postList(
    String path, {
    Object? body,
  }) async {
    expect(path, '/sales/shipments/batch');
    commands.add(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(body)) as Map),
    );
    await submitGate?.future;
    if (loseFirstSubmit) {
      loseFirstSubmit = false;
      throw NetworkTimeoutException();
    }
    return [
      {'id': 'created-shipment'},
    ];
  }
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  _Api api, {
  Size size = const Size(1440, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(_Names(api)),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => showSalesBatchShipPanel(context, ref),
              child: const Text('打开批量发货'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开批量发货'));
  if (api.pageGate == null) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

UtenPagedPickerList<ShippableLine> _picker(WidgetTester tester) =>
    tester.widget(find.byKey(const Key('sales-batch-lines')));
TextField _field(WidgetTester tester, String kind, int index) => tester.widget(
  find.descendant(
    of: find.byKey(ValueKey('sales-batch-$kind-line-$index')),
    matching: find.byType(TextField),
  ),
);
Finder _input(String kind, int index) => find.descendant(
  of: find.byKey(ValueKey('sales-batch-$kind-line-$index')),
  matching: find.byType(TextField),
);

void main() {
  test(
    'repository pages 100 and selection forwards the same normalized scope',
    () async {
      final api = _Api(total: 500);
      final repository = SalesRepository(api, SalesDocType.order);
      final page = await repository.shippableLinesPage(
        page: 3,
        keyword: '  order  ',
        clientId: 'client-a',
      );
      expect(api.queries.single, {
        'page': 3,
        'size': 100,
        'keyword': 'order',
        'clientId': 'client-a',
      });
      expect(page.items, hasLength(100));
      final all = await repository.shippableLinesSelection(
        keyword: '  order  ',
        clientId: 'client-a',
      );
      expect(api.selections.single, {
        'keyword': 'order',
        'clientId': 'client-a',
      });
      expect(all.items, hasLength(500));
      expect(all.total, 500);
    },
  );

  testWidgets(
    'legal full selection includes all 500 with original edited first row',
    (tester) async {
      final api = _Api(total: 500);
      await _open(tester, api);
      expect(
        api.queries.where((query) => query['page'] == 1).single['size'],
        100,
      );
      expect(_picker(tester).items, hasLength(100));
      await tester.tap(find.byKey(const ValueKey('sales-batch-select-line-1')));
      await tester.pumpAndSettle();
      await tester.enterText(_input('qty', 1), '0002.5000');
      await tester.enterText(_input('weight', 1), '0004.00');
      await tester.tap(find.byKey(const Key('sales-batch-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('生成出货单(500 行)'), findsOneWidget);
      expect(_field(tester, 'qty', 1).controller!.text, '0002.5000');
      await tester.tap(find.byKey(const Key('sales-batch-confirm')));
      await tester.pumpAndSettle();
      expect(api.commands.single['lines'], hasLength(500));
      expect((api.commands.single['lines'] as List).first, {
        'orderItemId': 'line-1',
        'qty': 2.5,
        'weight': 4.0,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'select all over limit preserves prior selection and never takes first 500',
    (tester) async {
      final api = _Api(total: 601);
      await _open(tester, api);
      await tester.tap(find.byKey(const ValueKey('sales-batch-select-line-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sales-batch-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('可发行超过单批500行，请按客户或关键词收窄后再全选'), findsOneWidget);
      expect(find.text('生成出货单(1 行)'), findsOneWidget);
      expect(api.commands, isEmpty);
    },
  );

  testWidgets(
    'incomplete selection response is rejected without partial selection',
    (tester) async {
      final api = _Api()..truncatedSelection = 100;
      await _open(tester, api);
      await tester.tap(find.byKey(const Key('sales-batch-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('生成出货单(0 行)'), findsOneWidget);
      expect(api.commands, isEmpty);
    },
  );

  testWidgets(
    'selection and raw inputs survive evicted pages and submit every chosen row',
    (tester) async {
      final api = _Api(total: 701);
      await _open(tester, api);
      await tester.tap(find.byKey(const ValueKey('sales-batch-select-line-1')));
      await tester.pumpAndSettle();
      await tester.enterText(_input('qty', 1), '0003.2500');
      await tester.enterText(_input('weight', 1), '2.75');
      await _picker(tester).onPageChange(7);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('sales-batch-select-line-601')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(_input('qty', 601), '4.1250');
      await _picker(tester).onPageChange(1);
      await tester.pumpAndSettle();
      expect(_field(tester, 'qty', 1).controller!.text, '0003.2500');
      expect(_field(tester, 'weight', 1).controller!.text, '2.75');
      expect(find.text('生成出货单(2 行)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sales-batch-confirm')));
      await tester.pumpAndSettle();
      expect(api.commands.single['lines'], [
        {'orderItemId': 'line-1', 'qty': 3.25, 'weight': 2.75},
        {'orderItemId': 'line-601', 'qty': 4.125},
      ]);
    },
  );

  testWidgets(
    'unknown submit retries identical original key/date/lines without requery',
    (tester) async {
      final api = _Api(total: 1)..loseFirstSubmit = true;
      await _open(tester, api);
      await tester.tap(find.byKey(const ValueKey('sales-batch-select-line-1')));
      await tester.pumpAndSettle();
      await tester.enterText(_input('qty', 1), '0001.2500');
      await tester.tap(find.byKey(const Key('sales-batch-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('重试确认开单'), findsOneWidget);
      expect(_field(tester, 'qty', 1).enabled, isFalse);
      expect(_field(tester, 'qty', 1).controller!.text, '0001.2500');
      await tester.tap(find.text('重试确认开单'));
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(2));
      expect(api.commands[1], api.commands[0]);
      expect(api.queries, hasLength(1));
      expect(api.selections, isEmpty);
    },
  );

  for (final phase in ['page', 'selection', 'submit']) {
    for (final boundary in [
      'permission',
      'server',
      'account',
      'impersonation',
    ]) {
      testWidgets('$phase response cannot revive after $boundary ABA', (
        tester,
      ) async {
        final gate = Completer<void>();
        final api = _Api(total: 1);
        if (phase == 'page') api.pageGate = gate;
        final container = await _open(tester, api);
        if (phase == 'selection') {
          api.selectionGate = gate;
          await tester.tap(find.byKey(const Key('sales-batch-select-all')));
          await tester.pump();
        }
        if (phase == 'submit') {
          await tester.tap(
            find.byKey(const ValueKey('sales-batch-select-line-1')),
          );
          await tester.pumpAndSettle();
          api.submitGate = gate;
          await tester.tap(find.byKey(const Key('sales-batch-confirm')));
          await tester.pump();
        }
        if (boundary == 'permission') {
          container.read(_permissions.notifier).state = {};
        } else if (boundary == 'server') {
          container.read(_server.notifier).state = 'https://other.invalid/api';
        } else {
          container.read(_identity.notifier).state = AuthenticatedScope(
            userId: 'other-reader',
            actorId: boundary == 'impersonation' ? 'sales-reader' : null,
          );
        }
        await tester.pump();
        if (boundary == 'permission') {
          container.read(_permissions.notifier).state = {
            Perm.salesShipmentCreate,
          };
        } else if (boundary == 'server') {
          container.read(_server.notifier).state =
              'https://fixture.invalid/api';
        } else {
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'sales-reader',
          );
        }
        await tester.pump();
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.textContaining('账号、权限或服务器已变化'), findsOneWidget);
        expect(find.byKey(const Key('sales-batch-lines')), findsNothing);
        expect(find.byKey(const Key('sales-batch-confirm')), findsNothing);
        expect(api.commands, hasLength(phase == 'submit' ? 1 : 0));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('late page response cannot replace a newer empty search', (
    tester,
  ) async {
    final api = _Api(total: 701);
    await _open(tester, api);
    final old = Completer<void>();
    api.pageGate = old;
    unawaited(Future.sync(() => _picker(tester).onPageChange(2)));
    await tester.pump();
    api.pageGate = null;
    final search = find.descendant(
      of: find.byKey(const Key('sales-batch-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'none');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(_picker(tester).items, isEmpty);
    old.complete();
    await tester.pumpAndSettle();
    expect(_picker(tester).items, isEmpty);
    expect(_picker(tester).currentPage, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a pending read never publishes its late response', (
    tester,
  ) async {
    final pending = Completer<void>();
    final api = _Api(total: 1)..pageGate = pending;
    await _open(tester, api);
    await tester.tap(find.byType(UtenCloseButton));
    await tester.pumpAndSettle();
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sales-batch-lines')), findsNothing);
    expect(api.commands, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow panel supports selection and preserves nonfinite weight rejection',
    (tester) async {
      final api = _Api(total: 1);
      await _open(tester, api, size: const Size(375, 812));
      await tester.tap(find.byKey(const ValueKey('sales-batch-select-line-1')));
      await tester.pumpAndSettle();
      await tester.enterText(_input('weight', 1), 'NaN');
      await tester.tap(find.byKey(const Key('sales-batch-confirm')));
      await tester.pumpAndSettle();
      expect(api.commands, isEmpty);
      expect(find.text('订单 SO-1 的实际重量要大于 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('readonly lines are excluded by complete selection snapshot', (
    tester,
  ) async {
    final api = _Api(total: 3)..readOnly = {1};
    await _open(tester, api);
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('sales-batch-select-line-1')),
          )
          .onChanged,
      isNull,
    );
    await tester.tap(find.byKey(const Key('sales-batch-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('生成出货单(2 行)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sales-batch-confirm')));
    await tester.pumpAndSettle();
    expect(
      (api.commands.single['lines'] as List).map(
        (row) => (row as Map)['orderItemId'],
      ),
      ['line-2', 'line-3'],
    );
  });

  testWidgets('search reuses same bounded scope and displays empty results', (
    tester,
  ) async {
    final api = _Api(total: 701);
    await _open(tester, api);
    final search = find.descendant(
      of: find.byKey(const Key('sales-batch-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'none');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(api.queries.last, containsPair('keyword', 'none'));
    expect(api.queries.last, containsPair('size', 100));
    expect(_picker(tester).items, isEmpty);
    expect(api.commands, isEmpty);
  });
}
