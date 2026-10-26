import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/pricing/price_analysis_models.dart';
import 'package:uten_imp/shared/pricing/price_analysis_repository.dart';
import 'package:uten_imp/shared/pricing/procurement_price_check.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

final _reader = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'reader-a'),
);

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

PurchaseGridRow _row(String id) => PurchaseGridRow()
  ..goods = GoodsOption(id: id, name: id)
  ..qty.text = '10'
  ..price.text = '12';

void main() {
  testWidgets(
    'selection rebuilds retain price evidence without payload capture or reads',
    (tester) async {
      final grid = UtenEditableGridController<PurchaseGridRow>()
        ..addRow(_row('a'));
      final revisions = ValueNotifier(0);
      final repository = _PriceRepository();
      var captures = 0;
      addTearDown(grid.dispose);
      addTearDown(revisions.dispose);
      await _mount(tester, grid, revisions, repository, () => captures++);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(repository.calls, hasLength(1));

      final tax = grid.rows.single.taxRate;
      tax.value = tax.value.copyWith(
        selection: const TextSelection.collapsed(offset: 0),
      );
      tax.value = tax.value.copyWith(
        composing: const TextRange(start: 0, end: 0),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(repository.calls, hasLength(1));
      expect(
        find.byKey(const ValueKey('price-evidence-price-row-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('price-evidence-price-row-1')),
        findsOneWidget,
      );
      final acceptedCaptures = captures;
      for (var i = 0; i < 5; i++) {
        grid.setSelected(grid.rows, i.isEven);
        revisions.value++;
        await tester.pump();
        expect(
          find.byKey(const ValueKey('price-evidence-price-row-1')),
          findsOneWidget,
        );
      }
      await tester.pump(const Duration(milliseconds: 350));
      expect(captures, acceptedCaptures);
      expect(repository.calls, hasLength(1));

      grid.rows.single.price.text = '13';
      await tester.pump();
      expect(
        find.byKey(const ValueKey('price-evidence-price-row-1')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls, hasLength(2));
      expect(repository.calls.last.single['unitPrice'], '13');

      grid.rows.single.colorId = 'red';
      tax.value = tax.value.copyWith(
        selection: const TextSelection.collapsed(offset: -1),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('price-evidence-price-row-1')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls, hasLength(3));
      expect(repository.calls.last.single['colorId'], 'red');
      revisions.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(repository.calls, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'equal-sized row replacement retires old listeners and rechecks new rows',
    (tester) async {
      final original = _row('a');
      final grid = UtenEditableGridController<PurchaseGridRow>()
        ..addRow(original);
      final revisions = ValueNotifier(0);
      final repository = _PriceRepository();
      addTearDown(grid.dispose);
      addTearDown(revisions.dispose);
      await _mount(tester, grid, revisions, repository, () {});
      await tester.pump(const Duration(milliseconds: 300));
      final replacement = _row('b');
      grid.replaceAll([replacement]);
      revisions.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls, hasLength(2));
      expect(repository.calls.last.single['goodsId'], 'b');
      replacement.price.text = '14';
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls, hasLength(3));
      expect(repository.calls.last.single['unitPrice'], '14');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late price response cannot publish through a replaced reader scope',
    (tester) async {
      final grid = UtenEditableGridController<PurchaseGridRow>()
        ..addRow(_row('a'));
      final revisions = ValueNotifier(0);
      final oldRead = Completer<List<PriceCheckResult>>();
      final repository = _PriceRepository()..pending = oldRead;
      addTearDown(grid.dispose);
      addTearDown(revisions.dispose);
      final container = await _mount(
        tester,
        grid,
        revisions,
        repository,
        () {},
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls, hasLength(1));
      container.read(_reader.notifier).state = null;
      await tester.pump();
      oldRead.complete(_warnings(repository.calls.first));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('price-evidence-price-row-1')),
        findsNothing,
      );
      expect(repository.calls, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  UtenEditableGridController<PurchaseGridRow> grid,
  ValueNotifier<int> revisions,
  _PriceRepository repository,
  VoidCallback capture,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_reader)),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsPriceAnalysisView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        priceAnalysisRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: revisions,
            builder: (_, _, _) => ProcurementPriceCheckScope<PurchaseGridRow>(
              grid: grid,
              kind: 'PURCHASE',
              bindingOf: (row) {
                final source = purchasePriceCheckBinding(row);
                return PriceCheckBinding(
                  contextKey: source.contextKey,
                  listenables: source.listenables,
                  payload: () {
                    capture();
                    return source.payload();
                  },
                );
              },
              child: SizedBox(
                width: 400,
                height: 50,
                child: PriceCheckCell(
                  row: grid.rows.single,
                  child: TextField(controller: grid.rows.single.price),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(PriceCheckCell)));
}

List<PriceCheckResult> _warnings(List<Map<String, dynamic>> items) => [
  for (final item in items)
    PriceCheckResult({
      'rowKey': item['rowKey'],
      'goodsId': item['goodsId'],
      'status': 'READY',
      'severity': 'WARNING',
    }),
];

class _PriceRepository implements PriceAnalysisRepository {
  final calls = <List<Map<String, dynamic>>>[];
  Completer<List<PriceCheckResult>>? pending;

  @override
  Future<List<PriceCheckResult>> check(
    String kind,
    List<Map<String, dynamic>> items, {
    String? excludeOrderId,
    CancelToken? cancelToken,
  }) async {
    calls.add(items);
    if (pending case final gate?) return gate.future;
    return _warnings(items);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
