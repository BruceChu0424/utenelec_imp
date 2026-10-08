import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/business_columns/business_column_picker.dart';
import 'package:uten_imp/shared/business_columns/business_columns_repository.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';

class _Repository extends BusinessColumnsRepository {
  _Repository() : super(ApiClient(Dio()));
  bool fail = false;
  int creates = 0;
  @override
  Future<bool> supportsArithmetic(String scope) async => true;
  @override
  Future<List<BusinessColumn>> search(String scope, String query) async {
    if (fail) throw StateError('unavailable');
    return const [
      BusinessColumn(id: 'fee', name: '包装费', type: 'AMOUNT', operation: 'ADD'),
      BusinessColumn(id: 'ref', name: '客户货号'),
    ];
  }

  @override
  Future<BusinessColumn> create({
    required String scope,
    required String name,
    required String type,
    required String operation,
  }) async {
    creates++;
    return BusinessColumn(
      id: 'new',
      name: name,
      scope: scope,
      type: type,
      operation: operation,
    );
  }
}

void main() {
  testWidgets('saved populated column ignores stale hidden preference', (
    tester,
  ) async {
    final controller = UtenEditableGridController<SalesGridRow>(
      initial: [SalesGridRow()],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenEditableGrid<SalesGridRow>(
            controller: controller,
            showAddRow: false,
            showRowDelete: false,
            initialColumnOrder: const ['goods', 'extra:fee'],
            initialHiddenColumnKeys: const {'extra:fee'},
            forceVisibleColumnKeys: const {'extra:fee'},
            columns: [
              EditableGridColumn(
                key: 'goods',
                label: 'Goods',
                width: 160,
                cellBuilder: (_, _) => const Text('Product'),
              ),
              EditableGridColumn(
                key: 'extra:fee',
                label: 'Packing (+)',
                width: 160,
                cellBuilder: (_, _) => const Text('5'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Packing (+)'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
  });

  Future<void> open(
    WidgetTester tester,
    _Repository repo,
    ValueChanged<BusinessColumnChoice?> result, {
    bool masked = false,
    Size size = const Size(900, 800),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [businessColumnsRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result(
                await showBusinessColumnPicker(
                  context,
                  scope: 'sales_order',
                  systemColumns: const [
                    BusinessSystemColumn('clientModel', '文件型号'),
                  ],
                  existingIds: const {},
                  priceMasked: masked,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'catalog suggestion reuses stored definition and compact layout fits',
    (tester) async {
      final repo = _Repository();
      BusinessColumnChoice? result;
      await open(tester, repo, (v) => result = v, size: const Size(390, 780));
      await tester.enterText(
        find.byKey(const Key('business-column-name')),
        '包装',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('包装费 (+)'));
      await tester.pumpAndSettle();
      expect(result!.column!.id, 'fee');
      expect(repo.creates, 0);
    },
  );
  testWidgets('masked account cannot select financial definitions', (
    tester,
  ) async {
    final repo = _Repository();
    BusinessColumnChoice? result;
    await open(tester, repo, (v) => result = v, masked: true);
    expect(find.text('包装费 (+)'), findsNothing);
    await tester.tap(find.text('客户货号'));
    await tester.pumpAndSettle();
    expect(result!.column!.id, 'ref');
  });
  testWidgets('failed catalog remains retryable without creating a duplicate', (
    tester,
  ) async {
    final repo = _Repository()..fail = true;
    await open(tester, repo, (_) {});
    expect(find.text('读取表头失败，请重试'), findsOneWidget);
    repo.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('客户货号'), findsOneWidget);
  });
  testWidgets(
    'default sales template is minimal; trailing add reveals an existing header',
    (tester) async {
      final row = SalesGridRow(amountUsesDiscount: true);
      final controller = UtenEditableGridController<SalesGridRow>(
        initial: [row],
      );
      addTearDown(controller.dispose);
      late List<EditableGridColumn<SalesGridRow>> columns;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                Builder(
                  builder: (context) {
                    columns = salesGridColumns(
                      context: context,
                      onPickGoods: (_) async {},
                      docType: SalesDocType.order,
                      colorEntries: const {},
                      unitEntries: const {},
                    );
                    return UtenEditableGrid<SalesGridRow>(
                      columnEditingEnabled: true,
                      controller: controller,
                      columns: columns,
                      showAddRow: false,
                      showRowDelete: false,
                      onAddColumn: (hidden) async {
                        expect(
                          hidden.map((c) => c.key),
                          contains('clientModel'),
                        );
                        return 'clientModel';
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(columns.where((c) => c.defaultVisible).map((c) => c.key), [
        'goods',
        'nameEn',
        'goodsCode',
        'color',
        'qty',
        'unit',
        'price',
        'discount',
        'amount',
        'remark',
      ]);
      expect(find.text('文件型号'), findsNothing);
      await tester.tap(
        find.byKey(const Key('editable-grid-add-column')).hitTestable().last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('加费用或写说明'));
      await tester.pumpAndSettle();
      expect(find.text('文件型号'), findsOneWidget);
    },
  );
}
