import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_inline_notice.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_action.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/pages/production_material_discovery_request_page.dart';
import 'package:uten_imp/features/production/repositories/production_material_discovery_request_repository.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

ProductionExecutionWorkbenchSegment _task(String id) =>
    ProductionExecutionWorkbenchSegment.fromJson({
      'segmentId': id,
      'segmentCode': 'ZX-$id',
      'planId': 'plan-$id',
      'planNo': 'SJ-$id',
      'productCode': 'SHELL',
      'productName': '外壳',
      'productColorName': '白色',
      'productUnitName': '个',
      'plannedQty': 1000,
      'workshopName': '注塑车间',
      'lockVersion': 3,
      'canRequestMaterialDiscovery': true,
    });

const _plastic = {
  'goodsId': 'plastic',
  'goodsName': '塑料颗粒',
  'goodsCode': 'P01',
  'colorId': 'white',
  'colorName': '白色',
  'unitId': 'kg',
  'unitName': '千克',
};

class _Repository extends ProductionMaterialDiscoveryRequestRepository {
  _Repository() : super(ApiClient(Dio()));
  final submissions =
      <
        ({
          String segment,
          int version,
          String key,
          List<Map<String, dynamic>> items,
        })
      >[];
  Object? failure;
  String? failSegment;
  Completer<void>? gate;
  @override
  Future<void> request(
    String segmentId,
    int expectedVersion,
    String idempotencyKey, {
    List<Map<String, dynamic>> items = const [],
  }) async {
    submissions.add((
      segment: segmentId,
      version: expectedVersion,
      key: idempotencyKey,
      items: items.map(Map<String, dynamic>.from).toList(),
    ));
    if (gate != null) await gate!.future;
    if (failure != null && (failSegment == null || failSegment == segmentId)) {
      throw failure!;
    }
  }
}

class _SourceRepository extends ProductionExecutionWorkbenchRepository {
  _SourceRepository() : super(ApiClient(Dio()));
  Completer<void>? gate;
  Object? failure;
  @override
  Future<PagedResult<ProductionExecutionWorkbenchSegment>> workshopTasks({
    int page = 1,
    int size = 50,
    String keyword = '',
    String? status,
    String? preparationFilter,
    String? routeFilter,
    String? workshopDepartmentId,
    String? dateFrom,
    String? dateTo,
    String? analysisNo,
    String? segmentCode,
    String? sort,
    String? order,
  }) async {
    if (gate != null) await gate!.future;
    if (failure != null) throw failure!;
    return PagedResult(
      items: [_task('a')],
      page: 1,
      size: 50,
      total: 1,
      totalPages: 1,
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repo, {
  List<String> ids = const ['a'],
  bool permitted = true,
  Size size = const Size(1800, 1000),
  double scale = 1,
  _SourceRepository? sources,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionExecutionView,
          if (permitted) Perm.productionExecutionStart,
        }),
        productionMaterialDiscoveryRequestRepositoryProvider.overrideWithValue(
          repo,
        ),
        if (sources != null)
          productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
            sources,
          ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: Stack(
            children: [
              child!,
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(useSafeArea: false),
              ),
            ],
          ),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProductionMaterialDiscoveryRequestPage(
                    tasks: sources == null ? ids.map(_task).toList() : const [],
                    segmentIds: sources == null ? const [] : ids,
                    segmentCodes: sources == null
                        ? const []
                        : ids.map((id) => 'ZX-$id').toList(),
                  ),
                ),
              ),
              child: const Text('打开确认'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开确认'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

List<DiscoveryRequestMaterialRow> _rows(WidgetTester tester) => tester
    .widget<MasterDataTableView<DiscoveryRequestMaterialRow>>(
      find.byKey(const Key('discovery-request-table')),
    )
    .items;

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('discovery-request-submit')));
  await tester.pumpAndSettle();
}

Future<void> _add(WidgetTester tester, DiscoveryRequestMaterialRow row) async {
  tester
      .widget<IconButton>(
        find.byKey(ValueKey('discovery-request-add-${row.id}')),
      )
      .onPressed!();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'source lookup uses shared modal loading and releases it when the form is ready',
    (tester) async {
      final sources = _SourceRepository()..gate = Completer<void>();
      await _pump(tester, _Repository(), sources: sources, settle: false);
      expect(
        find.byKey(const Key('discovery-request-loading')),
        findsOneWidget,
      );
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      sources.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        find.byKey(const Key('discovery-request-submit')).hitTestable(),
        findsOneWidget,
      );
      expect(_rows(tester).single.task.segmentId, 'a');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source lookup failure releases the modal without popping the request route',
    (tester) async {
      final sources = _SourceRepository()
        ..gate = Completer<void>()
        ..failure = ApiException('CONFLICT', '工单已变化', httpStatus: 409);
      await _pump(tester, _Repository(), sources: sources, settle: false);
      sources.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        find.byType(ProductionMaterialDiscoveryRequestPage),
        findsOneWidget,
      );
      expect(find.textContaining('工单已变化'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('discovery-request-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'review has one red optional-material notice and separate compact identity columns',
    (tester) async {
      await _pump(tester, _Repository());
      final notice = tester.widget<UtenInlineNotice>(
        find.byKey(const Key('discovery-request-missing-material-notice')),
      );
      expect(notice.level, UtenInlineNoticeLevel.error);
      expect(notice.message, contains('可选填'));
      expect(
        // 本例断言的就是带正文的提示；UtenInlineNotice.message 已可空（在途
        // 口径），这里用 ! 只解类型，不改变断言语义。
        tester.widget<Text>(find.text(notice.message!)).style!.color,
        UtenInlineNoticeLevel.error.accent,
      );
      expect(find.textContaining('累计学习 BOM'), findsNothing);
      expect(find.textContaining('个车间任务 · 已提交'), findsNothing);
      final table = tester
          .widget<MasterDataTableView<DiscoveryRequestMaterialRow>>(
            find.byKey(const Key('discovery-request-table')),
          );
      // 2026-10-06 全站口径：状态列（submissionStatus）排最前。
      expect(table.columns.take(4).map((column) => column.key), [
        'submissionStatus',
        'task',
        'planNo',
        'workshop',
      ]);
      for (final column in table.columns.take(4)) {
        expect(column.cellBuilder, isNull);
      }
      expect(
        table.columns.take(4).map((column) => column.value(table.items.single)),
        ['待提交', 'ZX-a', 'SJ-a', '注塑车间'],
      );
      expect(
        tester.getTopLeft(find.text('ZX-a')).dy,
        tester.getTopLeft(find.text('SJ-a')).dy,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'submission modal ends on an uncertain response and retains the frozen retry form',
    (tester) async {
      final repo = _Repository()
        ..gate = Completer<void>()
        ..failure = NetworkTimeoutException();
      await _pump(tester, repo);
      await tester.tap(find.byKey(const Key('discovery-request-submit')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const Key('discovery-request-saving')), findsOneWidget);
      repo.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('重试提交申请').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'restored uncertain material draft retains completed tasks and exact submitted intent',
    (tester) async {
      final repo = _Repository()
        ..failure = NetworkTimeoutException()
        ..failSegment = 'b';
      await _pump(tester, repo, ids: ['a', 'b']);
      _rows(tester)[0].values.addAll(_plastic);
      _rows(tester)[1].values.addAll(_plastic);
      _rows(tester)[1].qty.text = '12.7500';
      await _submit(tester);
      final before =
          tester.state(find.byType(ProductionMaterialDiscoveryRequestPage))
              as FormDraftMixin<ProductionMaterialDiscoveryRequestPage>;
      final saved = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(before.captureFormDraft())) as Map,
      );
      expect(saved['completed'], ['a']);
      expect(saved['uncertain'], isTrue);
      final original = repo.submissions.last;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final resumedRepo = _Repository();
      await _pump(tester, resumedRepo, ids: ['a', 'b']);
      final resumed =
          tester.state(find.byType(ProductionMaterialDiscoveryRequestPage))
              as FormDraftMixin<ProductionMaterialDiscoveryRequestPage>;
      await resumed.restoreFormDraft(saved);
      await tester.pumpAndSettle();
      expect(find.text('重试提交申请'), findsOneWidget);
      for (final row in _rows(tester)) {
        expect(
          tester
              .widget<TextField>(
                find.byKey(ValueKey('discovery-request-qty-${row.id}')),
              )
              .readOnly,
          isTrue,
        );
      }
      _rows(tester).last.qty.text = '99';
      await _submit(tester);
      expect(resumedRepo.submissions.single.segment, 'b');
      expect(resumedRepo.submissions.single.version, original.version);
      expect(resumedRepo.submissions.single.key, original.key);
      expect(resumedRepo.submissions.single.items, original.items);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restoring an editable draft with an obsolete task version blocks submission',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo);
      final state =
          tester.state(find.byType(ProductionMaterialDiscoveryRequestPage))
              as FormDraftMixin<ProductionMaterialDiscoveryRequestPage>;
      final saved = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(state.captureFormDraft())) as Map,
      );
      ((saved['tasks'] as List).single as Map<String, dynamic>)['lockVersion'] =
          2;
      await state.restoreFormDraft(saved);
      await tester.pumpAndSettle();
      expect(find.textContaining('原车间任务已变化'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('discovery-request-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(repo.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'choosing material displays its reference fields automatically as read-only cells',
    (tester) async {
      await _pump(tester, _Repository());
      final row = _rows(tester).single;
      row.selectGoods(
        const GoodsListItem(
          id: 'plastic',
          name: '塑料颗粒',
          code: 'P01',
          spec: 'PC-ABS',
          colorId: 'white',
          colorName: '白色',
          unitId: 'kg',
          unitName: '千克',
          stockPlace: 'A-01',
          owningWarehouseId: 'owner-only',
        ),
      );
      await _add(tester, row);
      final table = tester
          .widget<MasterDataTableView<DiscoveryRequestMaterialRow>>(
            find.byKey(const Key('discovery-request-table')),
          );
      for (final field in {
        'goodsCode': 'P01',
        'spec': 'PC-ABS',
        'colorName': '白色',
        'stockPlace': 'A-01',
      }.entries) {
        final column = table.columns.firstWhere(
          (column) => column.key == field.key,
        );
        expect(column.value(row), field.value);
        expect(column.cellBuilder, isNull);
        expect(column.value(table.items.last), '—');
      }
      // 2026-10-10 数量内联口径：独立「单位」列撤销，单位进领料数量输入框后缀。
      expect(table.columns.any((column) => column.key == 'unitName'), isFalse);
      expect(find.text('千克'), findsOneWidget);
      expect(row.values.containsKey('warehouseId'), isFalse);
      expect(row.qty.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'reselecting material keeps chosen color and requires a new quantity after a unit change',
    () {
      final row = DiscoveryRequestMaterialRow(id: 'row', task: _task('a'));
      addTearDown(row.dispose);
      row.values.addAll({..._plastic, 'colorId': 'blue', 'colorName': '蓝色'});
      row.qty.text = '12.5';
      row.selectGoods(
        const GoodsListItem(
          id: 'plastic',
          colorId: 'white',
          colorName: '白色',
          unitId: 'kg',
        ),
      );
      expect(row.values['colorId'], 'blue');
      expect(row.qty.text, '12.5');
      row.selectGoods(
        const GoodsListItem(id: 'plastic', colorId: 'white', unitId: 'g'),
      );
      expect(row.values['colorId'], 'blue');
      expect(row.values['unitId'], 'g');
      expect(row.qty.text, isEmpty);
      row.qty.text = '25';
      row.selectGoods(
        const GoodsListItem(id: 'pigment', colorId: 'red', unitId: 'g'),
      );
      expect(row.values['colorId'], 'red');
      expect(row.qty.text, isEmpty);
    },
  );
  test(
    'optional quantity preserves exact material identity without inventing usage',
    () {
      final row = DiscoveryRequestMaterialRow(id: 'row', task: _task('a'));
      addTearDown(row.dispose);
      expect(row.isEmpty, isTrue);
      row.values.addAll(_plastic);
      expect(row.toRequest(), {
        'goodsId': 'plastic',
        'colorId': 'white',
        'unitId': 'kg',
      });
      row.qty.text = '12.7500';
      expect(row.toRequest()['qty'], '12.7500');
      for (final qty in ['0', '-1', 'NaN', '1.00001', 'Infinity', '1e3']) {
        row.qty.text = qty;
        expect(row.toRequest, throwsFormatException, reason: qty);
      }
    },
  );

  testWidgets(
    'empty material rows remain optional and submit every exact task',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo, ids: ['a', 'b']);
      expect(
        find.byType(MasterDataTableView<DiscoveryRequestMaterialRow>),
        findsOneWidget,
      );
      await _submit(tester);
      expect(repo.submissions.map((e) => e.segment), ['a', 'b']);
      expect(
        repo.submissions.every((e) => e.items.isEmpty && e.version == 3),
        isTrue,
      );
      expect(find.text('打开确认'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected materials and optional quantities remain attached to their work orders',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo, ids: ['a', 'b']);
      final first = _rows(tester).first;
      first.values.addAll(_plastic);
      first.qty.text = '12.7500';
      await _add(tester, first);
      _rows(tester)[1].values.addAll({
        ..._plastic,
        'goodsId': 'pigment',
        'goodsName': '色粉',
      });
      _rows(tester)[2].values.addAll(_plastic);
      await _submit(tester);
      expect(repo.submissions[0].items, [
        {
          'goodsId': 'plastic',
          'colorId': 'white',
          'unitId': 'kg',
          'qty': '12.7500',
        },
        {'goodsId': 'pigment', 'colorId': 'white', 'unitId': 'kg'},
      ]);
      expect(repo.submissions[1].items, [
        {'goodsId': 'plastic', 'colorId': 'white', 'unitId': 'kg'},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'duplicate material and color prevents the entire batch from submitting',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo, ids: ['a', 'b']);
      final row = _rows(tester)[1]..values.addAll(_plastic);
      await _add(tester, row);
      _rows(tester)[2].values.addAll(_plastic);
      await _submit(tester);
      expect(repo.submissions, isEmpty);
      expect(find.textContaining('同材料、同颜色重复'), findsWidgets);
      expect(_rows(tester), hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'material selection can be cleared back to an optional blank row',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo);
      final row = _rows(tester).first..values.addAll(_plastic);
      row.qty.text = '12';
      tester
          .widget<IconButton>(
            find.byKey(ValueKey('discovery-request-remove-${row.id}')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(_rows(tester).single.isEmpty, isTrue);
      await _submit(tester);
      expect(repo.submissions.single.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'uncertain partial submission freezes inputs and retries identical payload only for remaining tasks',
    (tester) async {
      final repo = _Repository()
        ..failure = NetworkTimeoutException()
        ..failSegment = 'b';
      await _pump(tester, repo, ids: ['a', 'b']);
      _rows(tester)[0].values.addAll(_plastic);
      _rows(tester)[1].values.addAll(_plastic);
      _rows(tester)[1].qty.text = '12.5';
      await _submit(tester);
      expect(find.text('重试提交申请'), findsOneWidget);
      final table = tester
          .widget<MasterDataTableView<DiscoveryRequestMaterialRow>>(
            find.byKey(const Key('discovery-request-table')),
          );
      final status = table.columns.firstWhere(
        (column) => column.key == 'submissionStatus',
      );
      expect(table.items.map(status.value), ['已提交', '待核对']);
      for (final row in _rows(tester)) {
        expect(
          tester
              .widget<TextField>(
                find.byKey(ValueKey('discovery-request-qty-${row.id}')),
              )
              .readOnly,
          isTrue,
        );
        expect(
          tester
              .widget<IconButton>(
                find.byKey(ValueKey('discovery-request-add-${row.id}')),
              )
              .onPressed,
          isNull,
        );
      }
      // Even an out-of-band controller update must not change an ambiguous request.
      _rows(tester)[1].qty.text = '99';
      repo.failure = null;
      await _submit(tester);
      expect(repo.submissions.map((e) => e.segment), ['a', 'b', 'b']);
      expect(repo.submissions[1].key, repo.submissions[2].key);
      expect(repo.submissions[1].items, repo.submissions[2].items);
      expect(repo.submissions.last.items.single['qty'], '12.5');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit rejection preserves input and changed material intent receives a new key',
    (tester) async {
      final repo = _Repository()
        ..failure = ApiException('INVALID', '请核对数量', httpStatus: 400);
      await _pump(tester, repo);
      final row = _rows(tester).single..values.addAll(_plastic);
      row.qty.text = '12.5';
      await _submit(tester);
      expect(row.qty.text, '12.5');
      expect(
        tester
            .widget<TextField>(
              find.byKey(ValueKey('discovery-request-qty-${row.id}')),
            )
            .readOnly,
        isFalse,
      );
      row.qty.text = '13.25';
      repo.failure = null;
      await _submit(tester);
      expect(repo.submissions[0].key, isNot(repo.submissions[1].key));
      expect(repo.submissions.last.items.single['qty'], '13.25');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('viewer cannot choose or submit workshop materials', (
    tester,
  ) async {
    final repo = _Repository();
    await _pump(tester, repo, permitted: false);
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('discovery-request-submit')))
          .onPressed,
      isNull,
    );
    expect(
      // 2026-10-06 行高统一口径：该格由 TextButton 换成 UtenTableCellAction，
      // 断言语义不变（查看者不可选材料）。
      tester
          .widget<UtenTableCellAction>(
            find.byKey(
              ValueKey('discovery-request-goods-${_rows(tester).single.id}'),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(repo.submissions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(760, 900)]) {
    testWidgets('optional material table handles $size and large text', (
      tester,
    ) async {
      await _pump(tester, _Repository(), size: size, scale: 1.4);
      expect(find.byKey(const Key('discovery-request-table')), findsOneWidget);
      expect(find.byKey(const Key('discovery-request-submit')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'repository sends optional material snapshot on the exact segment request',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final repo = ProductionMaterialDiscoveryRequestRepository(ApiClient(dio));
      await repo.request(
        'a',
        3,
        'known',
        items: const [
          {'goodsId': 'plastic', 'colorId': 'white', 'unitId': 'kg'},
        ],
      );
      await repo.request('b', 4, 'unknown');
      expect(
        requests.first.path,
        '/production/material-discovery/segments/a/request',
      );
      expect(requests.first.data, {
        'expectedVersion': 3,
        'idempotencyKey': 'known',
        'items': [
          {'goodsId': 'plastic', 'colorId': 'white', 'unitId': 'kg'},
        ],
      });
      expect(requests.last.data, {
        'expectedVersion': 4,
        'idempotencyKey': 'unknown',
      });
    },
  );
}
