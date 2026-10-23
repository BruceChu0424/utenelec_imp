import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/cards/uten_card.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_batch_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_task_center_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_outbound_table_columns.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

import '../../helpers/badge_summary_fixture.dart';
import 'outbound_weight_fakes.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

late SharedPreferences _preferences;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  for (final boundary in ['confirmation', 'source-read']) {
    testWidgets('sales binds the original intent before $boundary awaits', (
      tester,
    ) async {
      final gateway = _Gateway([_detail('1'), _detail('2')]);
      final container = await _pumpSalesRecovery(
        tester,
        gateway,
        MemoryFormDraftStorage(),
      );
      final session =
          container.read(sessionProvider.notifier) as _RecoverySession;
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
      );
      await tester.pumpAndSettle();
      if (boundary == 'confirmation') {
        session.intent++;
      } else {
        gateway.onDetail = () => session.intent++;
      }
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-batch-confirm')),
      );
      await tester.pumpAndSettle();
      expect(gateway.commands, isEmpty);
      expect(
        container.read(authenticatedScopeProvider)?.userId,
        'warehouse-user',
      );
      expect(tester.takeException(), isNull);
    });
  }
  for (final state in [
    'cancelled-B',
    'deleted-B',
    'unreadable-B',
    'unreadable-A',
    'unreadable-A-late',
  ]) {
    testWidgets(
      'sales draft recovery checks original A independently of $state',
      (tester) async {
        final gateway = _Gateway([_detail('1'), _detail('2')])..failId = '1';
        final storage = MemoryFormDraftStorage();
        var container = await _pumpSalesRecovery(tester, gateway, storage);
        await _confirm(tester);
        expect(gateway.commands, ['1:SHIPPED']);
        final original = container.read(formDraftsProvider).single;
        expect(original.hasUnknownSubmission, isTrue);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        if (state != 'unreadable-A-late') {
          gateway.values['1'] = _detail('1', status: 'SHIPPED');
        }
        if (state == 'cancelled-B' || state == 'unreadable-A-late') {
          gateway.values['2'] = _detail('2', status: 'CANCELLED');
        } else if (state == 'deleted-B') {
          gateway.missing.add('2');
        } else {
          gateway.unreadable.add(state == 'unreadable-A' ? '1' : '2');
        }
        container = await _pumpSalesRecovery(
          tester,
          gateway,
          storage,
          draftId: original.id,
        );
        expect(gateway.commands, ['1:SHIPPED']);
        expect(
          find.textContaining('来源 ${state == 'unreadable-A' ? '1' : '2'}'),
          findsWidgets,
        );
        if (state == 'unreadable-A' || state == 'unreadable-A-late') {
          if (state == 'unreadable-A-late') gateway.unreadable.add('1');
          final recovery = find
              .ancestor(
                of: find.text('核对出库结果'),
                matching: find.byType(UtenButton),
              )
              .last;
          expect(tester.widget<UtenButton>(recovery).onPressed, isNotNull);
          await tester.tap(recovery.hitTestable());
          await tester.pumpAndSettle();
          expect(gateway.commands, ['1:SHIPPED']);
          expect(
            container.read(formDraftsProvider).single.hasUnknownSubmission,
            isTrue,
          );
          expect(find.text('货品1'), findsNothing);
        } else {
          final saved = container.read(formDraftsProvider).single;
          expect(saved.data['completed'], ['1']);
          expect(saved.data['shipmentIds'], ['1', '2']);
          expect(saved.hasUnknownSubmission, isFalse);
          expect(find.text('货品2'), findsNothing);
          expect(find.text('客户2'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('fresh sales batch remains strict when a source is unreadable', (
    tester,
  ) async {
    final gateway = _Gateway([_detail('1'), _detail('2')])..unreadable.add('2');
    await _pumpSalesRecovery(tester, gateway, MemoryFormDraftStorage());
    expect(gateway.commands, isEmpty);
    expect(find.text('货品1'), findsNothing);
    expect(find.text('来源不可读取'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'partial sales selection cannot confirm an unselected sibling line',
    (tester) async {
      final original = _detail('one');
      final sibling = _detail('sibling');
      final detail = WarehouseSalesOutboundDetail(
        header: original.header,
        lines: [...original.lines, ...sibling.lines],
      );
      final gateway = _Gateway([detail]);
      await _pump(
        tester,
        gateway,
        const WarehouseSalesOutboundBatchPage(
          shipmentIds: ['one'],
          selectedItemIds: ['line-one'],
          action: WarehouseSalesOutboundAction.confirmShipment,
        ),
      );
      final table = tester
          .widget<MasterDataTableView<WarehouseSalesOutboundTableRow>>(
            find.byKey(const Key('warehouse-sales-outbound-batch-table')),
          );
      expect(table.items.map((row) => row.line.id), ['line-one']);
      expect(find.textContaining('该出货单需整单确认'), findsWidgets);
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
      );
      await tester.pumpAndSettle();
      expect(gateway.commands, isEmpty);
      expect(
        find.byKey(const Key('warehouse-sales-outbound-batch-confirm')),
        findsNothing,
      );
    },
  );
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
    'batch outbound sends each document its own line weights and soft-confirms weight alerts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final a = _detail('1', unitRate: 1);
      final b = _detail('2', unitRate: 1);
      final gateway = _Gateway([a, b]);
      await _pump(
        tester,
        gateway,
        WarehouseSalesOutboundBatchPage(
          targets: [a.header, b.header],
          action: WarehouseSalesOutboundAction.confirmShipment,
        ),
        weights: FakeWeightRepository(
          byGoods: {'goods-1': learnedWeightParams('goods-1')},
        ),
      );
      // 第一单 10 件约 20 g, 实称 1.5 kg: 偏差告警; 第二单不称。
      await tester.enterText(
        find.byKey(const ValueKey('weight-cell-input')).first,
        '1.5',
      );
      await tester.pump();
      expect(find.byKey(const Key('outbound-weight-summary')), findsOneWidget);
      expect(find.textContaining('未称 1 行'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-batch-submit')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-sales-outbound-weight-alerts')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('warehouse-sales-outbound-batch-confirm')),
      );
      await tester.pumpAndSettle();
      expect(gateway.weights, {
        '1': {'line-1': 1.5},
        '2': <String, double>{},
      });
      expect(gateway.commands, ['1:SHIPPED', '2:SHIPPED']);
      expect(tester.takeException(), isNull);
    },
  );

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
      final tasks = _TaskCenterGateway(gateway);
      // 2026-10-17 起销售出库深链直落「出库任务中心 · 销售出库」统一表;
      // 批量核对出库按行 canHandle(服务端动作资格)进批量页。
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const WarehouseSalesOutboundPage(),
          ),
          GoRoute(
            path: '/warehouse/sales-outbound/batch',
            builder: (_, state) => WarehouseSalesOutboundBatchPage(
              targets: [
                for (final id
                    in (state.uri.queryParameters['shipmentIds'] ?? '').split(
                      ',',
                    ))
                  if (id.isNotEmpty) gateway.values[id]!.header,
              ],
              action: WarehouseSalesOutboundAction.confirmShipment,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(
        tester,
        gateway,
        const WarehouseSalesOutboundPage(),
        tasks: tasks,
        router: router,
      );
      await tester.pumpAndSettle();
      final table = tester
          .widget<MasterDataTableView<WarehouseTaskCenterRecord>>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is MasterDataTableView<WarehouseTaskCenterRecord>,
            ),
          );
      // 无办理资格的行(服务端 allowedWarehouseTargets 为空)不可勾选。
      final blockedRow = table.items.singleWhere((row) => row.id == 'blocked');
      expect(table.idOf!(blockedRow), isNull);
      table.onSelectedIdsChanged!({
        'SALES:SALES_SHIPMENT:1',
        'SALES:SALES_SHIPMENT:2',
      });
      await tester.pump();
      await tester.tap(find.byKey(const Key('warehouse-task-record-batch')));
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
      // 回任务中心统一表, 办理返回后列表重拉。
      expect(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<WarehouseTaskCenterRecord>,
        ),
        findsOneWidget,
      );
      expect(tasks.pages, hasLength(2));
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
      await tester.ensureVisible(
        find.textContaining('批量作业已停止', skipOffstage: false),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('批量作业已停止'), findsOneWidget);
      final table = tester
          .widget<MasterDataTableView<WarehouseSalesOutboundTableRow>>(
            find.byKey(const Key('warehouse-sales-outbound-batch-table')),
          );
      final resultColumn = table.columns.singleWhere(
        (column) => column.key == 'warehouseWorkStatus',
      );
      expect(table.items.map(resultColumn.value), [
        gateway.values['1']!.header.statusLabel,
        '结果待核对',
        gateway.values['3']!.header.statusLabel,
      ]);
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
        await tester.pumpWidget(const SizedBox.shrink());
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
      // 选桶 → status 收到该值并回第 1 页；切段时清表头筛选。
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _Gateway([_detail('1')]);
      final tasks = _TaskCenterGateway(gateway);
      await _pump(
        tester,
        gateway,
        const WarehouseSalesOutboundPage(),
        tasks: tasks,
      );
      await tester.pumpAndSettle();

      final table = tester
          .widget<MasterDataTableView<WarehouseTaskCenterRecord>>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is MasterDataTableView<WarehouseTaskCenterRecord>,
            ),
          );
      expect(table.facets.keys, contains('status'));
      expect(
        table.facets['status']?.map((bucket) => bucket.value),
        containsAll(<String>['PENDING_PICK', 'SHIPPED', 'CANCELLED']),
      );

      table.onFilterChanged('status', 'CANCELLED');
      await tester.pumpAndSettle();
      expect(tasks.statuses.last, 'CANCELLED');
      expect(tasks.pages.last, 1);
      // 切回「全部任务」段：表头状态桶被清，回分段口径。
      await tester.ensureVisible(find.text('全部任务', skipOffstage: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部任务'));
      await tester.pumpAndSettle();
      expect(tasks.statuses.last, isNull);
      expect(tasks.pages.last, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Gateway gateway,
  Widget page, {
  _TaskCenterGateway? tasks,
  GoRouter? router,
  FakeWeightRepository? weights,
}) async {
  final needsTaskCenter = tasks != null;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_preferences),
        warehouseSalesOutboundRepositoryProvider.overrideWithValue(gateway),
        fakeWeightRepositoryOverride(weights),
        sessionProvider.overrideWith(_RecoverySession.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'warehouse-user'),
        ),
        apiBaseUrlProvider.overrideWithValue(
          'https://warehouse-recovery.test/api',
        ),
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        if (!needsTaskCenter) ...[
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseSalesOutboundView,
            Perm.warehouseSalesOutboundExecute,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          fixedBadgeSummaryOverride(),
        ],
        if (needsTaskCenter) ...[
          // 2026-10-17 起深链页正文是任务中心统一表；分段红数固定为徽章事实。
          warehouseTaskCenterRepositoryProvider.overrideWithValue(tasks),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseSalesOutboundView,
            Perm.warehouseSalesOutboundExecute,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: const {BadgeFact.warehouseSalesOutboundPendingPick: 2},
            ),
          ),
        ],
      ],
      child: router == null
          ? MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: page,
            )
          : MaterialApp.router(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
            ),
    ),
  );
  await tester.pumpAndSettle();
}

class _RecoverySession extends SessionNotifier {
  int intent = 0;
  @override
  int get requestIntentEpoch => intent;
  @override
  SessionState build() => const SessionState();
}

Future<ProviderContainer> _pumpSalesRecovery(
  WidgetTester tester,
  _Gateway gateway,
  MemoryFormDraftStorage storage, {
  String? draftId,
}) async {
  const path = '/warehouse/sales-outbound/batch';
  final router = GoRouter(
    initialLocation: Uri(
      path: path,
      queryParameters: {
        'shipmentIds': '1,2',
        'action': 'confirmShipment',
        'itemIds': 'line-1,line-2',
        'draftId': ?draftId,
      },
    ).toString(),
    routes: [
      GoRoute(
        path: path,
        builder: (_, state) => const WarehouseSalesOutboundBatchPage(
          shipmentIds: ['1', '2'],
          selectedItemIds: ['line-1', 'line-2'],
          action: WarehouseSalesOutboundAction.confirmShipment,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_preferences),
        warehouseSalesOutboundRepositoryProvider.overrideWithValue(gateway),
        fakeWeightRepositoryOverride(),
        fixedBadgeSummaryOverride(),
        sessionProvider.overrideWith(_RecoverySession.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'warehouse-user'),
        ),
        apiBaseUrlProvider.overrideWithValue(
          'https://warehouse-recovery.test/api',
        ),
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.warehouseSalesOutboundView,
          Perm.warehouseSalesOutboundExecute,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        formDraftStorageProvider.overrideWithValue(storage),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(WarehouseSalesOutboundBatchPage)),
  );
}

/// 任务中心统一表网关：把销售出库夹具折成 SALES 行与状态枚举桶(ADR-184：
/// canHandle 折叠 allowedWarehouseTargets 动作资格)。
class _TaskCenterGateway implements WarehouseTaskCenterGateway {
  _TaskCenterGateway(this.sales);

  final _Gateway sales;
  final List<int> pages = [];
  final List<String?> statuses = [];

  @override
  Future<WarehouseTaskCenterPageResult> list({
    required WarehouseTaskDirection direction,
    String source = 'ALL',
    WarehouseTaskView view = WarehouseTaskView.active,
    String? status,
    String? keyword,
    String? billNo,
    String? dateFrom,
    String? dateTo,
    WarehouseTaskScope warehouseScope = const WarehouseTaskScope.all(),
    int page = 1,
    int size = 20,
    String? sort,
    String? order,
  }) async {
    pages.add(page);
    statuses.add(status);
    final rows = [
      for (final detail in sales.values.values)
        if ((source == 'ALL' || source == 'SALES') &&
            (status == null || detail.header.warehouseWorkStatus == status))
          WarehouseTaskCenterRecord(
            rowKey: 'SALES:SALES_SHIPMENT:${detail.header.id}',
            id: detail.header.id,
            sourceType: 'SALES',
            recordType: 'SALES_SHIPMENT',
            status: detail.header.warehouseWorkStatus ?? 'PENDING_PICK',
            statusLabel: detail.header.statusLabel,
            billNo: detail.header.billNo,
            action: 'SALES_OUTBOUND',
            targetId: detail.header.id,
            canHandle: detail.header.allowedWarehouseTargets.isNotEmpty,
          ),
    ];
    return WarehouseTaskCenterPageResult(
      items: rows,
      page: page,
      size: size,
      total: rows.length,
      totalPages: rows.isEmpty ? 0 : 1,
      facets: const {
        'status': [
          MasterFacetBucket(value: 'PENDING_PICK', label: '待出库', count: 1),
          MasterFacetBucket(value: 'SHIPPED', label: '已出库', count: 0),
          MasterFacetBucket(value: 'CANCELLED', label: '已取消', count: 0),
        ],
      },
    );
  }
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
  double? unitRate,
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
      'unitRate': ?unitRate,
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
  final Map<String, Map<String, double>?> weights = {};
  String? failId;
  final unreadable = <String>{};
  final missing = <String>{};
  VoidCallback? onDetail;
  int listReads = 0;
  final List<String?> workStatuses = [];
  final List<int> listPages = [];

  @override
  Future<WarehouseSalesOutboundDetail> detail(String id) async {
    final onRead = onDetail;
    onDetail = null;
    onRead?.call();
    if (missing.contains(id)) {
      throw ApiException('NOT_FOUND', '来源已删除', httpStatus: 404);
    }
    if (unreadable.contains(id)) {
      throw ApiException('FORBIDDEN', '来源不可读取', httpStatus: 403);
    }
    return values[id]!;
  }

  @override
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
    String? dateFrom,
    String? dateTo,
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
    String? sort,
    String? order,
    String? billNo,
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
  Future<List<MasterFacetBucket>> billNoFacets({
    String? keyword,
    String? warehouseWorkStatus,
    String? dateFrom,
    String? dateTo,
    WarehouseTaskScope scope = const WarehouseTaskScope.all(),
  }) async => const []; // 2026-09-25 单号列统一：页面 facets 静默降级。

  @override
  Future<WarehouseSalesOutboundDetail> transition(
    String id, {
    required String targetStatus,
    String? reason,
    Map<String, String>? stockPlaces,
    Map<String, String?>? lineWarehouses,
    Map<String, double>? lineWeights,
    List<String>? itemIds,
  }) async {
    commands.add('$id:$targetStatus');
    reasons.add(reason);
    warehouses[id] = lineWarehouses;
    places[id] = stockPlaces;
    weights[id] = lineWeights;
    if (id == failId) {
      throw ApiException('CONFLICT', '库存数量已变化');
    }
    final result = _detail(id, status: targetStatus);
    values[id] = result;
    return result;
  }
}
