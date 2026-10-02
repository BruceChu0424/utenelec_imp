import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/pages/sales_task_center_page.dart';
import 'package:uten_imp/features/sales/models/sales_order_progress.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/widgets/saved_document_fields.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../shared/drafts/memory_form_draft_storage.dart';

final _canViewPricesProvider = StateProvider<bool>((ref) => true);

// The task center AppBar also has a "草稿" button. These tests select the
// order-progress stage, not the separate all-drafts destination.
Finder _orderDraftStageSegment() => find.descendant(
  of: find.byKey(const Key('sales-order-progress-stages')),
  matching: find.byWidgetPredicate(
    (widget) => widget is UtenSegmentBadgeLabel && widget.label == '草稿',
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('价格撤权立即遮住已恢复的价格、固定列和合计，保留完整草稿', (tester) async {
    final storage = MemoryFormDraftStorage();
    final env = await _pump(tester, storage);
    await _seedPartialOrder(tester, qty: '2');
    UtenEditableGrid<SalesGridRow> grid() =>
        tester.widget(find.byType(UtenEditableGrid<SalesGridRow>));
    final row = grid().controller.rows.single;
    final before = row.exportDraft();
    env.container.read(_canViewPricesProvider.notifier).state = false;
    await tester.pumpAndSettle();
    for (final key in ['price', 'discount', 'amount']) {
      expect(
        grid().columns.singleWhere((c) => c.key == key).frozenTextOf!(row),
        '***',
      );
    }
    expect(
      tester
          .widget<UtenTotalsSummaryBar>(
            find.byKey(const Key('sales-edit-totals')),
          )
          .entries
          .last
          .value,
      '***',
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            (w.controller == row.price || w.controller == row.discount),
      ),
      findsNothing,
    );
    expect(row.exportDraft(), before);
    env.container.read(_canViewPricesProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(
      grid().columns.singleWhere((c) => c.key == 'price').frozenTextOf!(row),
      '10',
    );
    expect(
      tester
          .widget<UtenTotalsSummaryBar>(
            find.byKey(const Key('sales-edit-totals')),
          )
          .entries
          .last
          .value,
      '20.00',
    );
    expect(env.api.writes, 0);
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });

  testWidgets('销售草稿重开显现已填可选列并向既有API保留精确业务字段', (tester) async {
    final storage = MemoryFormDraftStorage();
    var env = await _pump(tester, storage);
    await _seedPartialOrder(tester, qty: '2.5000');
    final grid = tester.widget<UtenEditableGrid<SalesGridRow>>(
      find.byType(UtenEditableGrid<SalesGridRow>),
    );
    final row = grid.controller.rows.single;
    row.machiningPrice.text = '1.2300';
    row.circumference.text = '3.50';
    row.inboundQty.text = '2.0000';
    row.weight.text = '4.5000';
    row.unitRateExact = '1.00000001';
    row.clientNo = '客户行号-1';
    row.clientModel.text = '客户型号-1';
    row.clientGoodsName.text = '客户原品名';
    row.clientPrice = '7.50';
    row.remark.text = '按客户包装';
    row.restoreExtraColumns([
      {
        'columnId': 'package-spec',
        'name': '包装规格',
        'scope': 'sales_order',
        'type': 'TEXT',
        'operation': 'NONE',
        'value': '每箱20',
      },
    ]);
    await (tester.state(find.byType(SalesDocEditPage))
            as FormDraftMixin<SalesDocEditPage>)
        .saveFormDraftNow();
    final draft = env.container.read(formDraftsProvider).single;
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
    final api = _Api(allowCreate: true);
    env = await _pump(
      tester,
      storage,
      location: draft.resumeLocation,
      apiOverride: api,
      canViewPrices: false,
    );
    final restored = tester.widget<UtenEditableGrid<SalesGridRow>>(
      find.byType(UtenEditableGrid<SalesGridRow>),
    );
    expect(
      restored.forceVisibleColumnKeys,
      containsAll([
        'machiningPrice',
        'circumference',
        'inboundQty',
        'clientModel',
        'clientGoodsName',
        'clientPrice',
        'extra:package-spec',
      ]),
    );
    expect(
      restored.columns
          .singleWhere((c) => c.key == 'machiningPrice')
          .frozenTextOf!(restored.controller.rows.single),
      '***',
    );
    expect(restored.controller.rows.single.inboundQty.text, '2.0000');
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.controller == restored.controller.rows.single.inboundQty,
      ),
      findsNothing,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.writes, 1);
    final line = (api.lastBody!['items'] as List).single as Map;
    expect(line, containsPair('qty', '2.5000'));
    expect(line, containsPair('unitRate', '1.00000001'));
    expect(line, containsPair('weight', '4.5000'));
    expect(line, containsPair('machiningPrice', '1.2300'));
    expect(line, containsPair('circumference', '3.50'));
    expect(line, isNot(contains('inboundQty')));
    expect(line, containsPair('clientNo', '客户行号-1'));
    expect(line, containsPair('clientModel', '客户型号-1'));
    expect(line, containsPair('clientGoodsName', '客户原品名'));
    expect(line, containsPair('clientPrice', '7.50'));
    expect(line, containsPair('discount', null));
    expect(line, containsPair('remark', '按客户包装'));
    expect(line['extraColumns'], [
      {'columnId': 'package-spec', 'value': '每箱20'},
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    env.router.dispose();
    env.container.dispose();
  });
  testWidgets(
    'sales progress draft category remains usable when formal list is offline',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      var env = await _pump(tester, storage);
      await _seedPartialOrder(tester, qty: '2');
      final draft = env.container.read(formDraftsProvider).single;
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      final api = _Api(allowCreate: true, formalDrafts: 2, failProgress: true);
      env = await _pump(
        tester,
        storage,
        location: '/sales/tasks',
        apiOverride: api,
      );
      await tester.tap(find.text('订货进度'));
      await tester.pumpAndSettle();
      final draftSegment = _orderDraftStageSegment();
      expect(draftSegment, findsOneWidget);
      await tester.tap(draftSegment);
      await tester.pumpAndSettle();
      final table = tester
          .widget<
            MasterDataTableView<FormDraftCategoryRow<SalesOrderProgressRow>>
          >(
            find.byType(
              MasterDataTableView<FormDraftCategoryRow<SalesOrderProgressRow>>,
            ),
          );
      // Server pagination and local recovery use separate public slots. Local
      // rows stay visible above every server page, including an offline page.
      expect(table.items, isEmpty);
      expect(table.unpagedItems, hasLength(1));
      final local = table.unpagedItems.single;
      expect(local.isLocal, true);
      expect(local.draft!.id, draft.id);
      expect(
        find.byKey(ValueKey('form-draft-row-${draft.id}')),
        findsOneWidget,
      );
      // The paginated source retains its failure for retry while unpaged
      // local rows remain rendered and recoverable above it.
      expect(table.error, contains('simulated offline formal list'));
      expect(table.isLoading, false);
      table.onRowTap!(local);
      await tester.pumpAndSettle();
      expect(find.byType(SalesDocEditPage), findsOneWidget);
      expect(api.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
  for (final deleteLocal in [false, true]) {
    testWidgets(
      'task center order draft category merges local row; delete=$deleteLocal',
      (tester) async {
        final storage = MemoryFormDraftStorage();
        var env = await _pump(tester, storage);
        await _seedPartialOrder(tester, qty: '2');
        final draft = env.container.read(formDraftsProvider).single;
        await tester.pumpWidget(const SizedBox());
        env.router.dispose();
        env.container.dispose();
        final api = _Api(allowCreate: true, formalDrafts: 2);
        env = await _pump(
          tester,
          storage,
          location: '/sales/tasks',
          apiOverride: api,
        );
        expect(find.text('未完成草稿'), findsNothing);
        expect(find.text('未提交草稿'), findsNothing);
        await tester.tap(find.text('订货进度'));
        await tester.pumpAndSettle();
        final draftSegment = _orderDraftStageSegment();
        expect(draftSegment, findsOneWidget);
        final draftBadge = tester.widget<UtenSegmentBadgeLabel>(draftSegment);
        expect(draftBadge.count, 3);
        expect(find.text('未提交草稿'), findsNothing);
        await tester.tap(draftSegment);
        await tester.pumpAndSettle();
        final table = tester
            .widget<
              MasterDataTableView<FormDraftCategoryRow<SalesOrderProgressRow>>
            >(
              find.byType(
                MasterDataTableView<
                  FormDraftCategoryRow<SalesOrderProgressRow>
                >,
              ),
            );
        expect(table.items, hasLength(2));
        expect(table.items.every((row) => !row.isLocal), isTrue);
        expect(table.unpagedItems, hasLength(1));
        expect([...table.unpagedItems, ...table.items], hasLength(3));
        final local = table.unpagedItems.single;
        expect(local.isLocal, isTrue);
        expect(local.draft!.id, draft.id);
        expect(
          find.byKey(ValueKey('form-draft-row-${draft.id}')),
          findsOneWidget,
        );
        if (deleteLocal) {
          table.rowMenuBuilder!(local)
              .whereType<UtenMenuItem>()
              .singleWhere((item) => item.label == '删除草稿')
              .onTap();
          await tester.pumpAndSettle();
          await tester.tap(find.text('删除'));
          await tester.pumpAndSettle();
          expect(env.container.read(formDraftsProvider), isEmpty);
          expect(api.writes, 0);
          expect(api.deletes, 0);
          expect(find.text('SO-1'), findsOneWidget);
          expect(find.text('SO-2'), findsOneWidget);
        } else {
          table.onRowTap!(local);
          await tester.pumpAndSettle();
          expect(find.byType(SalesDocEditPage), findsOneWidget);
          final grid = tester
              .widget<UtenEditableGrid<SalesGridRow>>(
                find.byType(UtenEditableGrid<SalesGridRow>),
              )
              .controller;
          grid[0].qty.text = '3.5';
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          expect(api.writes, 1);
          expect(find.text('created-document'), findsOneWidget);
          expect(env.container.read(formDraftsProvider), isEmpty);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }
  for (final rejectCreatedCheckpoint in [false, true]) {
    testWidgets(
      'restored partial order saves after editing; local checkpoint failure=$rejectCreatedCheckpoint',
      (tester) async {
        final storage = _CreatedCheckpointStorage();
        var env = await _pump(tester, storage);
        await _seedPartialOrder(tester);
        final draft = env.container.read(formDraftsProvider).single;
        await tester.pumpWidget(const SizedBox());
        env.router.dispose();
        env.container.dispose();
        final api = _Api(allowCreate: true);
        env = await _pump(
          tester,
          storage,
          location: draft.resumeLocation,
          apiOverride: api,
        );
        storage.rejectCreatedCheckpoint = rejectCreatedCheckpoint;
        final grid = tester
            .widget<UtenEditableGrid<SalesGridRow>>(
              find.byType(UtenEditableGrid<SalesGridRow>),
            )
            .controller;
        grid[0].qty.text = '3.5';
        grid[0].remark.text = '恢复后继续填写';
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(api.writes, 1);
        final line =
            (api.lastBody!['items'] as List).single as Map<String, dynamic>;
        expect(line['qty'], '3.5');
        expect(line['remark'], '恢复后继续填写');
        expect(find.text('created-document'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('pending-attachment-retry-notice')),
          findsNothing,
        );
        expect(env.container.read(formDraftsProvider), isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }

  testWidgets(
    'known-created recovered order with no files continues without upload warning or duplicate create',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      var env = await _pump(tester, storage);
      await _seedPartialOrder(tester, createdId: 'created-order');
      final draft = env.container.read(formDraftsProvider).single;
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      final api = _Api(allowCreate: true);
      env = await _pump(
        tester,
        storage,
        location: draft.resumeLocation,
        apiOverride: api,
      );
      expect(
        find.byKey(const ValueKey('pending-attachment-retry-notice')),
        findsNothing,
      );
      expect(
        tester
            .widgetList<SavedDocumentFields>(find.byType(SavedDocumentFields))
            .every((fields) => fields.locked),
        isTrue,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('created-document'), findsOneWidget);
      expect(api.writes, 0);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'real attachment failure restores and retries upload without creating a second order',
    (tester) async {
      final storage = MemoryFormDraftStorage();
      final api = _Api(allowCreate: true);
      final files = _RetryFiles();
      var env = await _pump(tester, storage, apiOverride: api, files: files);
      await _seedPartialOrder(tester, qty: '2');
      final pending = tester
          .widget<BusinessAttachmentSection>(
            find.byKey(const ValueKey('sales-order-draft-attachments')),
          )
          .draftController!;
      final bytes = Uint8List.fromList('%PDF-1'.codeUnits);
      pending.add(
        PlatformFile(name: '合同.pdf', size: bytes.length, bytes: bytes),
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.writes, 1);
      expect(files.uploads, 1);
      expect(
        find.byKey(const ValueKey('pending-attachment-retry-notice')),
        findsOneWidget,
      );
      expect(
        tester
            .widgetList<SavedDocumentFields>(find.byType(SavedDocumentFields))
            .every((fields) => fields.locked),
        isTrue,
      );
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.data['createdDocId'], 'created-order');
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await _pump(
        tester,
        storage,
        location: draft.resumeLocation,
        apiOverride: api,
        files: files,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.writes, 1);
      expect(files.uploads, 2);
      expect(find.text('created-document'), findsOneWidget);
      expect(env.container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );

  testWidgets(
    'new sales order restores incomplete rows, selection and file bytes after hard close',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final storage = MemoryFormDraftStorage();
      var env = await _pump(tester, storage);
      expect(env.container.read(formDraftsProvider), isEmpty);

      final grid = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller;
      grid[0].goods = const GoodsOption(id: 'goods-1', name: '第一行货品');
      grid[0].qty.text = '1.';
      grid[0].price.text = '123.4500';
      grid[0].remark.text = '未填客户也应保护';
      final second = SalesGridRow(amountUsesDiscount: true)
        ..goods = const GoodsOption(id: 'goods-2', name: '第二行货品')
        ..orderItemId = 'source-2';
      second.qty.text = '';
      second.remark.text = '没有数量';
      grid.addRow(second);
      grid.setSelected([second], true);
      final attachment = tester
          .widget<BusinessAttachmentSection>(
            find.byKey(const ValueKey('sales-order-draft-attachments')),
          )
          .draftController!;
      final bytes = Uint8List.fromList('%PDF-1 retained contract'.codeUnits);
      expect(
        attachment.add(
          PlatformFile(name: '合同.pdf', size: bytes.length, bytes: bytes),
          category: '客户确认',
        ),
        isNull,
      );
      await tester.pumpAndSettle();
      final state =
          tester.state(find.byType(SalesDocEditPage))
              as FormDraftMixin<SalesDocEditPage>;
      await state.saveFormDraftNow();
      final draft = env.container.read(formDraftsProvider).single;
      expect(draft.data['clientId'], isNull);
      expect((draft.data['rows'] as List), hasLength(2));
      expect(env.api.writes, 0);

      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
      env = await _pump(tester, storage, location: draft.resumeLocation);
      final recovered = tester
          .widget<UtenEditableGrid<SalesGridRow>>(
            find.byType(UtenEditableGrid<SalesGridRow>),
          )
          .controller;
      expect(recovered.length, 2);
      expect(recovered[0].qty.text, '1.');
      expect(recovered[0].price.text, '123.4500');
      expect(recovered[1].qty.text, isEmpty);
      expect(recovered[1].orderItemId, 'source-2');
      expect(recovered.isSelected(recovered[0]), isFalse);
      expect(recovered.isSelected(recovered[1]), isTrue);
      final recoveredFile = tester
          .widget<BusinessAttachmentSection>(
            find.byKey(const ValueKey('sales-order-draft-attachments')),
          )
          .draftController!
          .items
          .single;
      expect(recoveredFile.name, '合同.pdf');
      expect(recoveredFile.category, '客户确认');
      expect(recoveredFile.bytes, bytes);
      expect(
        env.api.writes,
        0,
        reason: 'Recovery must never create or submit a business record',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
}

Future<({ProviderContainer container, GoRouter router, _Api api})> _pump(
  WidgetTester tester,
  MemoryFormDraftStorage storage, {
  String location = '/sales/orders/new',
  _Api? apiOverride,
  AttachmentService? files,
  bool canViewPrices = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final prefs = await SharedPreferences.getInstance();
  final api = apiOverride ?? _Api();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      if (files != null) attachmentServiceProvider.overrideWithValue(files),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'sales-person'),
      ),
      formDraftStorageProvider.overrideWithValue(storage),
      _canViewPricesProvider.overrideWith((ref) => canViewPrices),
      currentPermissionsProvider.overrideWith(
        (ref) => {
          Perm.salesOrderCreate,
          Perm.salesOrderEdit,
          Perm.salesOrderView,
          if (ref.watch(_canViewPricesProvider)) Perm.salesOrderPriceView,
          Perm.attachmentView,
          Perm.attachmentUpload,
        },
      ),
      sharedPreferencesProvider.overrideWithValue(prefs),
      salesMasterNameServiceProvider.overrideWithValue(
        SalesMasterNameService(api),
      ),
      sessionProvider.overrideWith(_Session.new),
    ],
  );
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/sales/tasks',
        builder: (_, _) => const SalesTaskCenterPage(),
      ),
      GoRoute(
        path: '/sales/orders/created-order',
        builder: (_, _) => const Scaffold(body: Text('created-document')),
      ),
      DraftAwareGoRoute(
        path: '/sales/orders/new',
        builder: (_, state) =>
            SalesDocEditPage(key: state.pageKey, docType: SalesDocType.order),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, router: router, api: api);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api({
    this.allowCreate = false,
    this.formalDrafts = 0,
    this.failProgress = false,
  }) : super(Dio());
  final bool allowCreate;
  final int formalDrafts;
  final bool failProgress;
  Map<String, dynamic>? lastBody;
  int writes = 0;
  int deletes = 0;
  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    deletes++;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders/progress/stage-counts') {
      return {'DRAFT': formalDrafts};
    }
    if (path == '/sales/orders/progress') {
      if (failProgress) throw StateError('simulated offline formal list');
      return {
        'items': [
          for (var index = 1; index <= formalDrafts; index++)
            {
              'orderId': 'formal-$index',
              'billNo': 'SO-$index',
              'stage': 'DRAFT',
            },
        ],
        'page': 1,
        'size': 40,
        'total': formalDrafts,
        'totalPages': 1,
      };
    }
    if (path == '/workbench/badges') {
      return {
        'facts': {'drafts.salesOrder': formalDrafts},
      };
    }
    return const {
      'items': <Map<String, dynamic>>[],
      'total': 0,
      'totalPages': 0,
      'page': 1,
      'size': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/notices/read-by-source') return const {'updated': 0};
    writes++;
    if (!allowCreate) {
      throw StateError('Draft protection must not call a business write');
    }
    lastBody = Map<String, dynamic>.from(body! as Map);
    return {
      'id': 'created-order',
      'status': 0,
      'items': const <Map<String, dynamic>>[],
    };
  }
}

Future<void> _seedPartialOrder(
  WidgetTester tester, {
  String qty = '',
  String? createdId,
}) async {
  final state =
      tester.state(find.byType(SalesDocEditPage))
          as FormDraftMixin<SalesDocEditPage>;
  final row = SalesGridRow(amountUsesDiscount: true)
    ..goods = const GoodsOption(id: 'goods-1', name: '恢复货品');
  row.qty.text = qty;
  row.price.text = '10';
  row.discount.text = '1';
  final data = {
    ...state.captureFormDraft(),
    'clientId': 'client-1',
    'sellerId': 'seller-1',
    'currencyId': 'cny',
    'settlementMethodId': 'settlement-1',
    'deliverDate': '2026-10-10T00:00:00.000',
    'shipmentPolicy': 'ALLOW_PARTIAL',
    'rows': [if (createdId == null) row.exportDraft()],
    'createdDocId': createdId,
  };
  row.dispose();
  await state.restoreFormDraft(data);
  await state.saveFormDraftNow();
  await tester.pumpAndSettle();
}

class _CreatedCheckpointStorage extends MemoryFormDraftStorage {
  bool rejectCreatedCheckpoint = false;
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) {
    if (rejectCreatedCheckpoint && value != null) {
      final document = jsonDecode(value) as Map<String, dynamic>;
      final data = document['data'];
      if (data is Map && data['createdDocId'] != null) {
        throw StateError('simulated local checkpoint failure');
      }
    }
    return super.compareAndSet(key, expectedValue: expectedValue, value: value);
  }
}

class _RetryFiles extends AttachmentService {
  _RetryFiles() : super(ApiClient(Dio()));
  int uploads = 0;
  @override
  Future<Attachment> upload({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    String? category,
  }) async {
    uploads++;
    if (uploads == 1) throw StateError('simulated upload outage');
    return Attachment(
      id: 'file-1',
      ownerType: ownerType,
      ownerId: ownerId,
      storageKey: 'file-1',
      originalName: fileName,
      sizeBytes: bytes.length,
    );
  }
}
