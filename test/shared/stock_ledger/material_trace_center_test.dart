import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/stock_ledger/material_trace_models.dart';
import 'package:uten_imp/shared/stock_ledger/material_trace_repository.dart';
import 'package:uten_imp/shared/stock_ledger/production_trace_models.dart';
import 'package:uten_imp/shared/stock_ledger/widgets/goods_production_trace_view.dart';
import 'package:uten_imp/shared/stock_ledger/widgets/material_trace_subject_picker.dart';

const _subject = MaterialTraceSubject(
  type: 'PURCHASE_ORDER',
  id: 'order-1',
  code: 'CG001',
  label: '采购订货',
);
final _permissions = StateProvider<Set<String>>(
  (ref) => {
    Perm.productionWhereUsedView,
    Perm.stockView,
    Perm.productionPlanView,
  },
);
final _scope = StateProvider<AuthenticatedScope>(
  (ref) => const AuthenticatedScope(userId: 'reader'),
);

Map<String, dynamic> _identity(MaterialTraceSubject subject) => {
  'type': subject.type,
  'id': subject.id,
  'code': subject.code,
  'label': subject.label,
};

Map<String, dynamic> _response({
  MaterialTraceSubject subject = _subject,
  bool sourceOnly = false,
}) => {
  'subject': _identity(subject),
  'page': 1,
  'size': 50,
  'total': sourceOnly ? 0 : 1,
  'totalPages': 1,
  'items': [
    if (!sourceOnly)
      {
        'id': 'demand-1',
        'kind': 'ORDER',
        'quantityBasis': '按原领料核销',
        'planNo': 'SC001',
        'product': {
          'goodsId': 'p1',
          'goodsName': '插座成品',
          'goodsCode': 'CP001',
          'unitName': '个',
        },
        'material': {
          'goodsId': 'm1',
          'goodsName': 'ABS塑料',
          'goodsCode': 'ABS001',
          'unitName': '千克',
        },
        'consumedQty': '99999999999999.9999',
        'issuedQty': '0.0001',
        'reports': [
          {
            'billNo': 'BG001',
            'billDate': '2026-10-15',
            'productQty': '1000.0001',
            'unitName': '个',
            'workers': [
              {'name': '报工参与人甲'},
            ],
            'batches': [
              {
                'id': 'lot-1',
                'code': 'LOT001',
                'reportItemId': 'ri-1',
                'productQty': '500.0001',
                'unitName': '个',
              },
            ],
          },
        ],
      },
  ],
  'sources': [
    {
      'type': 'PURCHASE_ORDER',
      'id': subject.id,
      'code': subject.code,
      'goods': {'goodsId': 'm1', 'goodsName': 'ABS塑料'},
      'qty': '99999999999999.9999',
      'unitName': '千克',
      'basis': '入库来源分配',
      'note': '不是逐批实耗记录',
    },
  ],
  'coverageNotes': ['同日报多产品时未逐批分摊用量'],
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  final calls = <({String path, Map<String, dynamic> query})>[];
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? trace;
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? subjects;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/subjects') || path.endsWith('/trace')) {
      final values = Map<String, dynamic>.of(query ?? {});
      calls.add((path: path, query: values));
      if (path.endsWith('/subjects')) {
        return subjects?.call(values) ?? {'items': <Object>[], 'total': 0};
      }
      return trace?.call(values) ?? _response();
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

Future<void> _pump(
  WidgetTester tester,
  _Api api,
  Widget child, {
  Size size = const Size(1600, 900),
  double scale = 1,
  bool dark = false,
  GoRouter? router,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: router == null
          ? MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(body: child),
            )
          : MaterialApp.router(
              routerConfig: router,
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
            ),
    ),
  );
  await tester.pump();
}

Widget _pickerButton({ValueChanged<MaterialTraceSubject?>? onSelected}) =>
    Consumer(
      builder: (context, ref, _) => TextButton(
        onPressed: () async {
          final item = await showMaterialTraceSubjectPicker(
            context,
            ref,
            kind: 'document',
          );
          onSelected?.call(item);
        },
        child: const Text('选择单据'),
      ),
    );

Finder _search() => find.descendant(
  of: find.byKey(const Key('material-trace-subject-search')),
  matching: find.byType(TextField),
);

GoRouter _traceRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => const Scaffold(
        body: GoodsProductionTraceView.query(subject: _subject),
      ),
    ),
    GoRoute(
      path: '${RouteName.stockItemBase}/:id',
      redirect: (context, state) {
        final container = ProviderScope.containerOf(context, listen: false);
        final permissions = container.read(currentPermissionsProvider);
        final required = requiredAnyPermFor(state.uri.path);
        return required != null && required.any(permissions.contains)
            ? null
            : '/denied';
      },
      builder: (_, state) => Scaffold(
        body: Text(
          'ledger ${state.pathParameters['id']} ${state.uri.queryParameters['tab']}',
        ),
      ),
    ),
    GoRoute(
      path: '/denied',
      builder: (_, _) => const Scaffold(body: Text('route denied')),
    ),
  ],
);

Future<void> _openTraceDetails(WidgetTester tester) async {
  final table = tester.widget<MasterDataTableView<GoodsProductionTraceRow>>(
    find.byType(MasterDataTableView<GoodsProductionTraceRow>),
  );
  table.onRowTap!(table.items.single);
  await tester.pumpAndSettle();
  await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
  await tester.pumpAndSettle();
}

Finder _ledgerButton() => find.widgetWithText(TextButton, '查看物料出入库流水');

String _location(GoRouter router) =>
    router.routerDelegate.currentConfiguration.matches.last.matchedLocation;

void main() {
  testWidgets('stock ledger entry is absent with only where-used permission', (
    tester,
  ) async {
    final router = _traceRouter();
    addTearDown(router.dispose);
    await _pump(tester, _Api(), const SizedBox(), router: router);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(GoodsProductionTraceView)),
      listen: false,
    );
    container.read(_permissions.notifier).state = {
      Perm.productionWhereUsedView,
    };
    await tester.pumpAndSettle();
    await _openTraceDetails(tester);
    expect(_ledgerButton(), findsNothing);
    expect(_location(router), '/');
    expect(tester.takeException(), isNull);
  });

  testWidgets('stock ledger entry opens the permitted original material', (
    tester,
  ) async {
    final router = _traceRouter();
    addTearDown(router.dispose);
    await _pump(tester, _Api(), const SizedBox(), router: router);
    await tester.pumpAndSettle();
    await _openTraceDetails(tester);
    expect(_ledgerButton(), findsOneWidget);
    await tester.tap(_ledgerButton());
    await tester.pumpAndSettle();
    expect(find.text('ledger m1 ledger'), findsOneWidget);
    expect(_location(router), '/stock/item/m1');
    expect(tester.takeException(), isNull);
  });

  for (final changeScope in [false, true]) {
    testWidgets(
      'stock ledger cached callback cannot navigate after ${changeScope ? 'account scope change' : 'stock permission revocation'}',
      (tester) async {
        final router = _traceRouter();
        addTearDown(router.dispose);
        final gate = Completer<Map<String, dynamic>>();
        var changed = false;
        final api = _Api()
          ..trace = (_) async => changed ? gate.future : _response();
        await _pump(tester, api, const SizedBox(), router: router);
        await tester.pumpAndSettle();
        await _openTraceDetails(tester);
        final callback = tester.widget<TextButton>(_ledgerButton()).onPressed!;
        final container = ProviderScope.containerOf(
          tester.element(find.byType(GoodsProductionTraceView)),
          listen: false,
        );
        changed = true;
        if (changeScope) {
          container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'another-reader',
          );
        } else {
          container.read(_permissions.notifier).state = {
            Perm.productionWhereUsedView,
          };
        }
        callback();
        await tester.pump(const Duration(milliseconds: 350));
        expect(_location(router), '/');
        expect(find.textContaining('ledger m1'), findsNothing);
        expect(find.text('route denied'), findsNothing);
        gate.completeError(
          ApiException('FORBIDDEN', '读取范围已变化', httpStatus: 403),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'subject identity, source precision and output batches preserve distinct facts',
    () {
      final result = MaterialTraceResult.fromJson(_response());
      expect(result.subject!.identity, ('PURCHASE_ORDER', 'order-1'));
      expect(result.sources.single.qty, '99999999999999.9999');
      expect(result.page.items.single.consumedQty, '99999999999999.9999');
      expect(
        result.page.items.single.reports.single.batches.single.productQty,
        '500.0001',
      );
      expect(result.page.items.single.returnedQty, isNull);
    },
  );

  test(
    'repository binds typed UUID, direction and dates rather than display number',
    () async {
      final api = _Api();
      await MaterialTraceRepository(api).trace(
        subject: _subject,
        direction: 'materials',
        dateFrom: '2026-10-01',
        dateTo: '2026-10-15',
        page: 3,
      );
      expect(api.calls.single.query, {
        'subjectType': 'PURCHASE_ORDER',
        'subjectId': 'order-1',
        'direction': 'materials',
        'dateFrom': '2026-10-01',
        'dateTo': '2026-10-15',
        'page': 3,
        'size': 50,
      });
    },
  );

  testWidgets(
    'picker starts without a request and distinguishes equal numbers by type and UUID',
    (tester) async {
      final api = _Api()
        ..subjects = (_) async => {
          'items': [
            _identity(_subject),
            {
              'type': 'SUBCONTRACT_ORDER',
              'id': 'order-2',
              'code': 'CG001',
              'label': '委外订货',
            },
          ],
          'page': 1,
          'size': 30,
          'total': 2,
          'totalPages': 1,
        };
      MaterialTraceSubject? selected;
      await _pump(
        tester,
        api,
        _pickerButton(onSelected: (item) => selected = item),
      );
      await tester.tap(find.text('选择单据'));
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);
      await tester.enterText(_search(), 'CG001');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<MaterialTraceSubject>>(
        find.byType(MasterDataTableView<MaterialTraceSubject>),
      );
      expect(table.columns.map((column) => column.label), [
        '单据号',
        '类型',
        '日期',
        '货品 / 摘要',
        '状态',
      ]);
      expect(table.tableKey, isNull);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey(('material-trace-subjects', 'document')),
          ),
          matching: find.text('CG001'),
        ),
        findsNWidgets(2),
      );
      await tester.tap(
        find.byKey(
          const ValueKey((
            'material-trace-subject',
            'SUBCONTRACT_ORDER',
            'order-2',
          )),
        ),
      );
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.text('选择追溯单据'), findsOneWidget);
      await tester.tap(find.byKey(const Key('material-trace-subject-confirm')));
      await tester.pumpAndSettle();
      expect(selected!.identity, ('SUBCONTRACT_ORDER', 'order-2'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final dismissal in ['取消', '关闭', '遮罩']) {
    testWidgets('subject draft is discarded by $dismissal', (tester) async {
      final api = _Api()
        ..subjects = (_) async => {
          'items': [_identity(_subject)],
          'page': 1,
          'size': 30,
          'total': 1,
          'totalPages': 1,
        };
      final results = <MaterialTraceSubject?>[];
      await _pump(tester, api, _pickerButton(onSelected: results.add));
      await tester.tap(find.text('选择单据'));
      await tester.pumpAndSettle();
      await tester.enterText(_search(), 'CG001');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey((
            'material-trace-subject',
            'PURCHASE_ORDER',
            'order-1',
          )),
        ),
      );
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(
        tester
            .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
            .selectedCount,
        1,
      );
      if (dismissal == '遮罩') {
        await tester.tapAt(const Offset(20, 400));
      } else if (dismissal == '关闭') {
        await tester.tap(find.byTooltip('关闭'));
      } else {
        await tester.tap(find.text('取消'));
      }
      await tester.pumpAndSettle();
      expect(results, [null]);
    });
  }

  for (final changeExact in [false, true]) {
    testWidgets(
      'subject draft and cached confirmation expire on ${changeExact ? 'exact filter' : 'keyword'} change',
      (tester) async {
        final api = _Api()
          ..subjects = (_) async => {
            'items': [_identity(_subject)],
            'page': 1,
            'size': 30,
            'total': 1,
            'totalPages': 1,
          };
        final results = <MaterialTraceSubject?>[];
        await _pump(tester, api, _pickerButton(onSelected: results.add));
        await tester.tap(find.text('选择单据'));
        await tester.pumpAndSettle();
        await tester.enterText(_search(), 'CG001');
        await tester.pump(const Duration(milliseconds: 251));
        await tester.pumpAndSettle();
        final row = find.byKey(
          const ValueKey((
            'material-trace-subject',
            'PURCHASE_ORDER',
            'order-1',
          )),
        );
        final table = tester.widget<MasterDataTableView<MaterialTraceSubject>>(
          find.byType(MasterDataTableView<MaterialTraceSubject>),
        );
        final oldSubject = table.items.singleWhere(
          (item) => item.identity == _subject.identity,
        );
        void oldSelect() => table.onRowTap!(oldSubject);
        await tester.tap(row);
        await tester.pumpAndSettle();
        final oldConfirm = tester
            .widget<UtenButton>(
              find.byKey(const Key('material-trace-subject-confirm')),
            )
            .onPressed!;
        if (changeExact) {
          await tester.tap(find.text('精确匹配编号'));
        } else {
          await tester.enterText(_search(), 'CG002');
        }
        oldSelect();
        oldConfirm();
        await tester.pump();
        expect(results, isEmpty);
        expect(
          tester
              .widget<UtenButton>(
                find.byKey(const Key('material-trace-subject-confirm')),
              )
              .onPressed,
          isNull,
        );
        await tester.pump(const Duration(milliseconds: 251));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
              .selectedCount,
          0,
        );
      },
    );
  }

  for (final paging in ['append', 'jump', 'failure']) {
    testWidgets('subject draft follows the settled $paging page window', (
      tester,
    ) async {
      final nextPage = Completer<Map<String, dynamic>>();
      final api = _Api()
        ..subjects = (query) async => query['page'] == 2
            ? nextPage.future
            : {
                'items': [
                  _identity(_subject),
                  for (var index = 1; index < 30; index++)
                    {
                      'type': 'PURCHASE_ORDER',
                      'id': 'first-$index',
                      'code': 'CG-$index',
                      'label': '采购订货',
                    },
                ],
                'page': 1,
                'size': 30,
                'total': 31,
                'totalPages': 2,
              };
      final results = <MaterialTraceSubject?>[];
      await _pump(tester, api, _pickerButton(onSelected: results.add));
      await tester.tap(find.text('选择单据'));
      await tester.pumpAndSettle();
      await tester.enterText(_search(), 'CG');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey((
            'material-trace-subject',
            'PURCHASE_ORDER',
            'order-1',
          )),
        ),
      );
      await tester.pumpAndSettle();
      final rows = tester
          .widget<MasterDataTableView<MaterialTraceSubject>>(
            find.byType(MasterDataTableView<MaterialTraceSubject>),
          )
          .rowsController!;
      if (paging == 'jump') {
        rows.goToPage(2);
      } else {
        unawaited(rows.loadNextPage());
      }
      await tester.pump();
      expect(api.calls.last.query['page'], 2);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('material-trace-subject-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(results, isEmpty);
      if (paging == 'failure') {
        nextPage.completeError(ApiException('FORBIDDEN', '候选范围已变化'));
      } else {
        nextPage.complete({
          'items': [
            {
              'type': 'PURCHASE_ORDER',
              'id': 'next',
              'code': 'CG-NEXT',
              'label': '采购订货',
            },
          ],
          'page': 2,
          'size': 30,
          'total': 31,
          'totalPages': 2,
        });
      }
      await tester.pumpAndSettle();
      final bar = tester.widget<UtenPickerConfirmBar>(
        find.byType(UtenPickerConfirmBar),
      );
      if (paging == 'append') {
        expect(
          rows.items.map((row) => row.id),
          containsAll(['order-1', 'next']),
        );
        expect(bar.selectedCount, 1);
        await tester.tap(
          find.byKey(const Key('material-trace-subject-confirm')),
        );
        await tester.pumpAndSettle();
        expect(results.single?.identity, _subject.identity);
      } else {
        expect(bar.selectedCount, 0);
        expect(
          tester
              .widget<UtenButton>(
                find.byKey(const Key('material-trace-subject-confirm')),
              )
              .onPressed,
          isNull,
        );
        expect(results, isEmpty);
      }
    });
  }

  testWidgets(
    'typing a replacement invalidates old results before debounce and ignores late response',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      final api = _Api()
        ..subjects = (q) async => q['keyword'] == 'old'
            ? gate.future
            : {
                'items': [
                  {
                    'type': 'PURCHASE_ORDER',
                    'id': 'new',
                    'code': 'NEW',
                    'label': '采购订货',
                  },
                ],
                'page': 1,
                'size': 30,
                'total': 1,
                'totalPages': 1,
              };
      await _pump(tester, api, _pickerButton());
      await tester.tap(find.text('选择单据'));
      await tester.pumpAndSettle();
      await tester.enterText(_search(), 'old');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.enterText(_search(), 'new');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      gate.complete({
        'items': [_identity(_subject)],
        'total': 1,
      });
      await tester.pumpAndSettle();
      expect(find.text('NEW'), findsOneWidget);
      expect(find.text('CG001'), findsNothing);
      await tester.enterText(_search(), '');
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.calls, hasLength(2));
      expect(find.text('NEW'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source-only records remain visible instead of claiming the document does not exist',
    (tester) async {
      final api = _Api()..trace = (_) async => _response(sourceOnly: true);
      await _pump(
        tester,
        api,
        const GoodsProductionTraceView.query(subject: _subject),
        size: const Size(375, 700),
        scale: 2,
        dark: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('采购订货 · CG001'), findsOneWidget);
      expect(find.textContaining('99999999999999.9999 千克'), findsOneWidget);
      expect(find.text('已找到来源凭证，暂无当前范围内可显示的后续用料记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'picker keeps equal permissions but clears results on actual revocation',
    (tester) async {
      final api = _Api()
        ..subjects = (_) async => {
          'items': [_identity(_subject)],
          'page': 1,
          'size': 30,
          'total': 1,
          'totalPages': 1,
        };
      await _pump(tester, api, _pickerButton());
      await tester.tap(find.text('选择单据'));
      await tester.pumpAndSettle();
      await tester.enterText(_search(), 'CG001');
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      final row = find.byKey(
        const ValueKey(('material-trace-subject', 'PURCHASE_ORDER', 'order-1')),
      );
      expect(row, findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      final oldConfirm = tester
          .widget<UtenButton>(
            find.byKey(const Key('material-trace-subject-confirm')),
          )
          .onPressed!;
      final container = ProviderScope.containerOf(
        tester.element(_search()),
        listen: false,
      );
      container.read(_permissions.notifier).state = {
        Perm.productionPlanView,
        Perm.stockView,
        Perm.productionWhereUsedView,
      };
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      expect(api.calls, hasLength(1));
      container.read(_permissions.notifier).state = {Perm.productionPlanView};
      oldConfirm();
      await tester.pumpAndSettle();
      expect(row, findsNothing);
      expect(find.text('选择追溯单据'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('material-trace-subject-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('账号、服务器或权限已变化，请重新搜索'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new query subject rejects a delayed previous order response', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    const newer = MaterialTraceSubject(
      type: 'PURCHASE_ORDER',
      id: 'new-order',
      code: 'NEW',
      label: '采购订货',
    );
    final api = _Api()
      ..trace = (query) async => query['subjectId'] == _subject.id
          ? gate.future
          : _response(subject: newer, sourceOnly: true);
    late StateSetter update;
    var selected = _subject;
    await _pump(
      tester,
      api,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return GoodsProductionTraceView.query(subject: selected);
        },
      ),
    );
    update(() => selected = newer);
    await tester.pumpAndSettle();
    gate.complete(_response());
    await tester.pumpAndSettle();
    expect(find.text('采购订货 · NEW'), findsOneWidget);
    expect(find.text('CG001'), findsNothing);
    expect(find.text('插座成品'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'query results use the shared table and expose output batch facts',
    (tester) async {
      await _pump(
        tester,
        _Api(),
        const GoodsProductionTraceView.query(subject: _subject),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<GoodsProductionTraceRow>>(
        find.byType(MasterDataTableView<GoodsProductionTraceRow>),
      );
      final row = table.items.single;
      expect(
        table.columns
            .singleWhere((c) => c.key == 'productionBatches')
            .value(row),
        'LOT001',
      );
      expect(row.consumedQty, '99999999999999.9999');
      expect(row.reports.single.workers, ['报工参与人甲']);
      expect(
        find.byType(MasterDataTableView<GoodsProductionTraceRow>),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wrong subject response is rejected rather than presented under another order',
    (tester) async {
      final api = _Api()
        ..trace = (_) async => _response(
          subject: const MaterialTraceSubject(
            type: 'SUBCONTRACT_ORDER',
            id: 'other',
            code: 'WRONG',
            label: 'wrong',
          ),
        );
      await _pump(
        tester,
        api,
        const GoodsProductionTraceView.query(subject: _subject),
      );
      await tester.pumpAndSettle();
      expect(find.text('WRONG'), findsNothing);
      expect(find.text('追溯结果与当前对象不一致，请重新查询'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'object-scope revocation on paging clears cached rows and source evidence',
    (tester) async {
      final api = _Api()
        ..trace = (query) async {
          if (query['page'] == 2) {
            throw ApiException('FORBIDDEN', '负责范围已变化', httpStatus: 403);
          }
          return _response();
        };
      await _pump(
        tester,
        api,
        const GoodsProductionTraceView.query(subject: _subject),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<GoodsProductionTraceRow>>(
        find.byType(MasterDataTableView<GoodsProductionTraceRow>),
      );
      table.onPageChange!(2);
      await tester.pumpAndSettle();
      expect(find.text('负责范围已变化'), findsWidgets);
      expect(find.text('插座成品'), findsNothing);
      expect(find.text('来源凭证 · 1'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a cached row callback cannot expose old details between permission change and repaint',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      var revoked = false;
      final api = _Api()
        ..trace = (_) async => revoked ? gate.future : _response();
      await _pump(
        tester,
        api,
        const GoodsProductionTraceView.query(subject: _subject),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<GoodsProductionTraceRow>>(
        find.byType(MasterDataTableView<GoodsProductionTraceRow>),
      );
      final oldCallback = table.onRowTap!;
      final oldRow = table.items.single;
      final container = ProviderScope.containerOf(
        tester.element(find.byType(GoodsProductionTraceView)),
        listen: false,
      );
      revoked = true;
      container.read(_permissions.notifier).state = {Perm.stockView};
      oldCallback(oldRow);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('用料追溯'), findsNothing);
      expect(find.text('全单参与人：报工参与人甲'), findsNothing);
      gate.completeError(ApiException('FORBIDDEN', '权限已变化', httpStatus: 403));
      await tester.pumpAndSettle();
      expect(find.text('权限已变化'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
