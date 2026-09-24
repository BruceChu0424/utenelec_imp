import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/cards/uten_card.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_outbound_table_columns.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

late SharedPreferences _preferences;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  test('only the explicitly allowed current stage can enter a batch', () {
    expect(
      warehouseSalesOutboundPrimaryAction(_detail('1').header),
      WarehouseSalesOutboundAction.confirmShipment,
    );
    expect(
      warehouseSalesOutboundPrimaryAction(_detail('1', targets: []).header),
      isNull,
    );
    // 退役的中间态目标不再被当成可办动作。
    expect(
      warehouseSalesOutboundPrimaryAction(
        _detail('1', targets: ['PICKING', 'EXCEPTION']).header,
      ),
      isNull,
    );
    expect(
      warehouseSalesOutboundPrimaryAction(
        _detail('1', status: 'SHIPPED').header,
      ),
      isNull,
    );
  });

  testWidgets('batch outbound preserves each actual warehouse and location', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final a = _detail('1', warehouseSelectable: true);
    final b = _detail('2', warehouseSelectable: true);
    final gateway = _Gateway([a, b]);
    await _pump(
      tester,
      gateway,
      WarehouseSalesOutboundBatchPage(
        targets: [a.header, b.header],
        action: WarehouseSalesOutboundAction.confirmShipment,
      ),
    );
    // V631：发出仓按行在表格里选，预填服务端建议仓；不再有整单「实际发货仓库」。
    expect(find.text('实际发货仓库'), findsNothing);
    expect(
      find.byKey(const ValueKey('sales-picking-warehouse-line-line-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sales-picking-warehouse-line-line-2')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('sales-picking-place-line-1')),
          )
          .controller
          ?.text,
      'A01',
      reason: '实际库位先按主档建议库位预填',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sales-picking-place-line-1')),
      'A-11',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sales-picking-place-line-2')),
      'B-22',
    );
    await _confirm(tester);
    expect(gateway.warehouses, {
      '1': {'line-1': 'leaf-1'},
      '2': {'line-2': 'leaf-2'},
    });
    expect(gateway.places, {
      '1': {'line-1': 'A-11'},
      '2': {'line-2': 'B-22'},
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'select all reviews eligible documents and confirms one stage only',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _Gateway([
        _detail('1'),
        _detail('2'),
        _detail('blocked', targets: []),
      ]);
      await _pump(tester, gateway, const WarehouseSalesOutboundPage());
      await tester.tap(find.text('待出库'));
      await tester.pumpAndSettle();
      final listFinder = find.byKey(
        const Key('warehouse-sales-outbound-table'),
      );
      final table = tester
          .widget<MasterDataTableView<WarehouseSalesOutboundSummary>>(
            listFinder,
          );
      expect(table.idOf!(gateway.values['blocked']!.header), isNull);
      await tester.tap(
        find.descendant(of: listFinder, matching: find.byType(Checkbox)).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-open-batch')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-sales-outbound-batch-table')),
        findsOneWidget,
      );
      expect(find.text('已选 2 张单据'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
            )
            .type,
        UtenButtonType.danger,
      );
      expect(gateway.commands, isEmpty);
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('warehouse-sales-outbound-batch-confirm')),
            )
            .type,
        UtenButtonType.danger,
      );
      expect(gateway.commands, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.commands, isEmpty);
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-batch-confirm')),
      );
      await tester.pumpAndSettle();
      expect(gateway.commands, ['1:SHIPPED', '2:SHIPPED']);
      expect(
        find.byKey(const Key('warehouse-sales-outbound-table')),
        findsOneWidget,
      );
      expect(gateway.listReads, greaterThan(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failure stops remaining commands and removes repeat submission',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _Gateway([_detail('1'), _detail('2'), _detail('3')])
        ..failId = '2';
      await _pump(
        tester,
        gateway,
        WarehouseSalesOutboundBatchPage(
          targets: gateway.values.values.map((d) => d.header).toList(),
          action: WarehouseSalesOutboundAction.confirmShipment,
        ),
      );
      await _confirm(tester);
      expect(gateway.commands, ['1:SHIPPED', '2:SHIPPED']);
      expect(
        find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
        findsNothing,
      );
      expect(find.textContaining('批量作业已停止'), findsOneWidget);
      final table = tester
          .widget<MasterDataTableView<WarehouseSalesOutboundTableRow>>(
            find.byKey(const Key('warehouse-sales-outbound-batch-table')),
          );
      final resultColumn = table.columns.singleWhere(
        (column) => column.key == 'result',
      );
      expect(table.items.map(resultColumn.value), ['已完成', '失败，请核对', '未处理']);
      expect(gateway.values['3']!.header.warehouseWorkStatus, 'PENDING_PICK');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changed physical quantities are rechecked before a command', (
    tester,
  ) async {
    final gateway = _Gateway([_detail('1')]);
    await _pump(
      tester,
      gateway,
      WarehouseSalesOutboundBatchPage(
        targets: [gateway.values['1']!.header],
        action: WarehouseSalesOutboundAction.confirmShipment,
      ),
    );
    gateway.values['1'] = _detail('1', quantity: '12.5000');
    await _confirm(tester);
    expect(gateway.commands, isEmpty);
    expect(
      find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
      findsNothing,
    );
    expect(find.textContaining('任务状态或允许动作已变化'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'batch cards retain document dates while every physical line shares one table',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final size in [
        const Size(390, 844),
        const Size(760, 900),
        const Size(1440, 900),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(const SizedBox.shrink());
        final gateway = _Gateway([_detail('1'), _detail('2')]);
        await _pump(
          tester,
          gateway,
          WarehouseSalesOutboundBatchPage(
            targets: gateway.values.values.map((d) => d.header).toList(),
            action: WarehouseSalesOutboundAction.confirmShipment,
          ),
        );
        final header = find.byKey(
          const Key('warehouse-sales-outbound-batch-header'),
        );
        expect(
          find.descendant(of: header, matching: find.byType(UtenCard)),
          findsNWidgets(2),
        );
        expect(
          find.descendant(
            of: header,
            matching: find.textContaining('2026-09-12', findRichText: true),
          ),
          findsWidgets,
        );
        expect(
          find.descendant(of: header, matching: find.text('一号分仓')),
          findsNothing,
        );
        expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
        final table = tester
            .widget<MasterDataTableView<WarehouseSalesOutboundTableRow>>(
              find.byKey(const Key('warehouse-sales-outbound-batch-table')),
            );
        expect(table.primary, isTrue);
        expect(table.items.map((r) => r.detail.header.id), ['1', '2']);
        expect(
          table.columns
              .singleWhere((c) => c.key == 'warehouse')
              .value(table.items.first),
          '一号分仓',
        );
        expect(gateway.commands, isEmpty);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'single detail uses the same physical table at compact and wide sizes',
    (tester) async {
      final gateway = _Gateway([_detail('1', quantity: '12.5000')]);
      for (final size in [const Size(420, 900), const Size(1440, 900)]) {
        await tester.binding.setSurfaceSize(size);
        await _pump(
          tester,
          gateway,
          const WarehouseSalesOutboundDetailPage(id: '1'),
        );
        final table = tester
            .widget<MasterDataTableView<WarehouseSalesOutboundTableRow>>(
              find.byKey(const Key('warehouse-sales-outbound-detail-table')),
            );
        final row = table.items.single;
        expect(
          table.columns.singleWhere((c) => c.key == 'quantity').value(row),
          '12.5000',
        );
        expect(
          table.columns.singleWhere((c) => c.key == 'unitName').value(row),
          '件',
        );
        expect(
          table.columns.singleWhere((c) => c.key == 'warehouse').value(row),
          '一号分仓',
        );
        expect(
          table.columns
              .singleWhere((c) => c.key == 'currentStockPlaceHint')
              .value(row),
          'A01',
        );
        expect(tester.takeException(), isNull);
      }
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'an uncertain single action requires refresh before another write',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _Gateway([_detail('1')])..failId = '1';
      await _pump(
        tester,
        gateway,
        const WarehouseSalesOutboundDetailPage(id: '1'),
      );
      final buttonFinder = find.byKey(
        const Key('warehouse-sales-outbound-action-SHIPPED'),
      );
      await tester.tap(buttonFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(gateway.commands, ['1:SHIPPED']);
      expect(tester.widget<UtenButton>(buttonFinder).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'work status header filter overrides segment and reloads page one',
    (tester) async {
      // 表头筛选生效冒烟：仓库作业固定枚举桶（含分段之外的 取消/红冲/迁移异常），
      // 选桶 → warehouseWorkStatus 收到该值并回第 1 页；切段时清表头筛选。
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _Gateway([_detail('1')]);
      await _pump(tester, gateway, const WarehouseSalesOutboundPage());
      await tester.tap(find.text('待出库'));
      await tester.pumpAndSettle();

      final table = tester
          .widget<MasterDataTableView<WarehouseSalesOutboundSummary>>(
            find.byKey(const Key('warehouse-sales-outbound-table')),
          );
      expect(table.facets.keys, contains('warehouseWorkStatus'));
      expect(
        table.facets['warehouseWorkStatus']?.map((bucket) => bucket.value),
        containsAll(<String>['PENDING_PICK', 'SHIPPED', 'CANCELLED']),
      );

      table.onFilterChanged('warehouseWorkStatus', 'CANCELLED');
      await tester.pumpAndSettle();
      expect(gateway.workStatuses.last, 'CANCELLED');
      expect(gateway.listPages.last, 1);

      // 切回「已出库」段：表头状态桶被清，回分段口径。
      await tester.tap(find.text('已出库'));
      await tester.pumpAndSettle();
      expect(gateway.workStatuses.last, 'SHIPPED');
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(WidgetTester tester, _Gateway gateway, Widget page) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_preferences),
        warehouseSalesOutboundRepositoryProvider.overrideWithValue(gateway),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(const Key('warehouse-sales-outbound-batch-confirm')),
  );
  await tester.pumpAndSettle();
}

WarehouseSalesOutboundDetail _detail(
  String id, {
  String status = 'PENDING_PICK',
  List<String>? targets,
  String quantity = '10.0000',
  bool warehouseSelectable = false,
}) => WarehouseSalesOutboundDetail.fromJson({
  'id': id,
  'billNo': 'SHIP-$id',
  'billDate': '2026-09-12',
  'warehouseWorkUpdatedAt': '2026-09-12T01:30:00Z',
  'clientName': '客户$id',
  'warehouseId': warehouseSelectable ? null : 'leaf-warehouse',
  'warehouseName': '一号分仓',
  'warehouseWorkStatus': status,
  'allowedWarehouseTargets':
      targets ??
      switch (status) {
        'PENDING_PICK' => ['SHIPPED'],
        _ => <String>[],
      },
  'lines': [
    {
      'id': 'line-$id',
      'lineNumber': 1,
      'goodsId': 'goods-$id',
      'goodsCode': 'G-$id',
      'goodsName': '货品$id',
      'currentStockPlaceHint': 'A01',
      'unitName': '件',
      'quantity': quantity,
      // V631：逐行候选发出仓与建议仓(推迟选仓的单据表头仓为空，建议仓来自库存所在叶仓)。
      if (status == 'PENDING_PICK') ...{
        'suggestedWarehouseId': warehouseSelectable
            ? 'leaf-$id'
            : 'leaf-warehouse',
        'warehouseChoices': [
          {
            'warehouseId': warehouseSelectable ? 'leaf-$id' : 'leaf-warehouse',
            'warehouseName': warehouseSelectable ? '成品$id仓' : '一号分仓',
            'availableQty': quantity,
            'requiredQty': quantity,
            'canFulfill': true,
          },
        ],
      } else ...{
        'warehouseId': 'leaf-warehouse',
        'warehouseName': '一号分仓',
      },
    },
  ],
});

class _Gateway implements WarehouseSalesOutboundGateway {
  _Gateway(List<WarehouseSalesOutboundDetail> details)
    : values = {for (final detail in details) detail.header.id: detail};
  final Map<String, WarehouseSalesOutboundDetail> values;
  final List<String> commands = [];
  final List<String?> reasons = [];
  final Map<String, Map<String, String?>?> warehouses = {};
  final Map<String, Map<String, String>?> places = {};
  String? failId;
  int listReads = 0;
  final List<String?> workStatuses = [];
  final List<int> listPages = [];

  @override
  Future<WarehouseSalesOutboundDetail> detail(String id) async => values[id]!;

  @override
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
    String? dateFrom,
    String? dateTo,
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
  }) async {
    listReads++;
    workStatuses.add(warehouseWorkStatus);
    listPages.add(page);
    final items = values.values
        .where(
          (d) =>
              warehouseWorkStatus == null ||
              d.header.warehouseWorkStatus == warehouseWorkStatus,
        )
        .map((d) => d.header)
        .toList();
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: 1,
    );
  }

  @override
  Future<WarehouseSalesOutboundDetail> transition(
    String id, {
    required String targetStatus,
    String? reason,
    Map<String, String>? stockPlaces,
    Map<String, String?>? lineWarehouses,
  }) async {
    commands.add('$id:$targetStatus');
    reasons.add(reason);
    warehouses[id] = lineWarehouses;
    places[id] = stockPlaces;
    if (id == failId) {
      throw ApiException('CONFLICT', '库存数量已变化');
    }
    final result = _detail(id, status: targetStatus);
    values[id] = result;
    return result;
  }
}
