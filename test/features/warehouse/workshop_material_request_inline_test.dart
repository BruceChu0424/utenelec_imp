import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_bin_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_request_dialog.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_request_inline_editor.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';

import 'workshop_material_test_support.dart';
import '../../support/audit_screenshot_support.dart';

const _captureUi = bool.fromEnvironment('UI_CAPTURE');
final _captureBoundary = GlobalKey();

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_captureUi) return;
  await tester.pumpAndSettle();
  await saveAuditScreenshot(tester, _captureBoundary, name);
}

const _white = WmMaterialOption(
  goodsId: 'raw',
  goodsName: '申请原料',
  goodsCode: 'RAW-1',
  categoryId: 'materials',
  colorId: 'white',
  colorName: '白',
  unitName: 'kg',
  bulkPackageQty: 25,
);
const _black = WmMaterialOption(
  goodsId: 'raw',
  goodsName: '申请原料',
  goodsCode: 'RAW-1',
  categoryId: 'materials',
  colorId: 'black',
  colorName: '黑',
  unitName: 'kg',
  bulkPackageQty: 25,
);
const _position = WmPosition(
  rows: [
    WmPositionRow(
      goodsId: 'raw',
      goodsName: '申请原料',
      colorId: 'white',
      colorName: '白',
      unitName: 'kg',
      bookQty: 120,
    ),
  ],
  allowedActions: ['REQUEST'],
);

class _Repo extends FakeWorkshopMaterialRepository {
  _Repo() {
    settingsResult = const [wmTestWorkshop];
    positionByBin = const {'bin1': _position};
    materialsByWorkshop = const {
      'w1': [_white, _black],
    };
  }
  final submissions =
      <({String workshop, List<Map<String, dynamic>> lines, String key})>[];
  int failures = 0;
  Completer<WmRequisition>? pending;

  @override
  Future<WmRequisition> createRequisition({
    required String kind,
    required String workshopDepartmentId,
    required List<Map<String, dynamic>> lines,
    String? remark,
    required String idempotencyKey,
  }) async {
    expect(kind, 'ISSUE');
    submissions.add((
      workshop: workshopDepartmentId,
      lines: lines,
      key: idempotencyKey,
    ));
    if (failures-- > 0) throw ApiException('NETWORK_ERROR', '回执未收到');
    if (pending != null) return pending!.future;
    return const WmRequisition(
      id: 'request',
      requestNo: 'ZL-1',
      kind: 'ISSUE',
      status: 'PENDING',
    );
  }
}

WorkshopMaterialRequestInlineController _begin(
  _Repo repo, {
  bool Function()? isCurrent,
}) => WorkshopMaterialRequestInlineController(() => repo)
  ..begin(
    workshopId: 'w1',
    workshopName: '注塑车间',
    isCurrent: isCurrent ?? () => true,
  );

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('wm-request-inline-add')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('goods-picker-paged-list')), findsOneWidget);
  final tree = find.byType(UtenCategoryTreeView<ProductCategoryNode>);
  if (!tester.any(tree)) {
    await tester.tap(find.byIcon(Icons.account_tree_rounded));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.descendant(of: tree, matching: find.text('物料')));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'request picker APIs preserve the authorized workshop/category/search contract',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: request.path.endsWith('/categories')
                    ? [
                        {
                          'id': 'materials',
                          'name': '物料',
                          'code': 'M',
                          'level': 0,
                          'children': <Map<String, dynamic>>[],
                        },
                      ]
                    : request.path.endsWith('/category-ids')
                    ? ['materials']
                    : {
                        'items': [
                          {
                            'goodsId': 'raw',
                            'goodsName': '申请原料',
                            'colorId': 'white',
                            'categoryId': 'materials',
                            'searchRank': 7,
                            'searchMatchKind': 'DIRECT',
                          },
                        ],
                        'page': 2,
                        'size': 50,
                        'total': 51,
                        'totalPages': 2,
                      },
              ),
            );
          },
        ),
      );
      final repository = WorkshopMaterialRepository(ApiClient(dio));
      final page = await repository.requestMaterials(
        'w1',
        keyword: '  原料  ',
        categoryId: 'materials',
        includeRelated: true,
        page: 2,
      );
      expect(page.items.single.key, _white.key);
      expect(page.items.single.categoryId, 'materials');
      expect(page.items.single.searchRank, 7);
      expect(page.items.single.searchMatchKind, 'DIRECT');
      expect(
        requests.first.path,
        ApiEndpoints.workshopMaterialRequestMaterials,
      );
      expect(requests.first.queryParameters, {
        'workshopId': 'w1',
        'page': 2,
        'size': 50,
        'keyword': '原料',
        'categoryId': 'materials',
        'includeRelated': true,
      });
      expect(
        (await repository.requestMaterialCategories('w1')).single.id,
        'materials',
      );
      expect(
        await repository.requestMaterialCategoryIds(
          'w1',
          '原料',
          categoryId: 'materials',
          includeRelated: true,
        ),
        {'materials'},
      );
      expect(
        requests[1].path,
        ApiEndpoints.workshopMaterialRequestMaterialCategories,
      );
      expect(
        requests[2].path,
        ApiEndpoints.workshopMaterialRequestMaterialCategoryIds,
      );
      expect(requests[2].queryParameters, {
        'workshopId': 'w1',
        'keyword': '原料',
        'categoryId': 'materials',
        'includeRelated': true,
      });
    },
  );

  test(
    'selection identity includes color; repeat selection preserves input and basis',
    () {
      final controller = _begin(_Repo());
      addTearDown(controller.dispose);
      controller.addAll([_white, _black], session: controller.session);
      controller.rows[_white.key]!.bags.text = '2';
      controller.rows[_white.key]!.bagsEdited();
      controller.addAll([_white], session: controller.session);
      expect(controller.rows.length, 2);
      expect(controller.rows[_white.key]!.qty.text, '50');
      controller.rows[_white.key]!.qty.text = '75';
      controller.rows[_white.key]!.qtyEdited();
      expect(controller.rows[_white.key]!.bags.text, '3');
      controller.remove(_black.key);
      expect(controller.rows.keys, [_white.key]);
    },
  );

  test(
    'failed requests preserve input and retry key; warehouse stock does not cap a request',
    () async {
      final repo = _Repo()..failures = 1;
      final controller = _begin(repo);
      addTearDown(controller.dispose);
      controller.addAll([_white], session: controller.session);
      controller.rows[_white.key]!.qty.text = '50';
      expect(controller.validation, isNull);
      await expectLater(controller.submit(), throwsA(isA<ApiException>()));
      expect(controller.rows[_white.key]!.qty.text, '50');
      expect(controller.reviewing, isFalse);
      await controller.submit();
      expect(repo.submissions.length, 2);
      expect(repo.submissions[0].key, repo.submissions[1].key);
      expect(repo.submissions.last.lines, [
        {'goodsId': 'raw', 'colorId': 'white', 'qty': 50.0, 'bags': null},
      ]);
      expect(controller.reviewing, isTrue);
      expect(controller.editable, isFalse);
    },
  );

  test(
    'invalid quantities and stale selection cannot dispatch a request',
    () async {
      var current = true;
      final repo = _Repo();
      final controller = _begin(repo, isCurrent: () => current);
      addTearDown(controller.dispose);
      final oldSession = controller.session;
      controller.addAll([_white], session: oldSession);
      controller.rows[_white.key]!.qty.text = '-1';
      await expectLater(controller.submit(), throwsA(isA<FormatException>()));
      controller.clear();
      controller.begin(
        workshopId: 'w1',
        workshopName: '注塑车间',
        isCurrent: () => current,
      );
      controller.addAll([_black], session: oldSession);
      expect(controller.rows, isEmpty);
      current = false;
      controller.addAll([_white], session: controller.session);
      expect(controller.rows, isEmpty);
      await expectLater(controller.submit(), throwsStateError);
      expect(repo.submissions, isEmpty);
    },
  );

  test(
    'in-flight submission is singular and late receipts cannot repopulate another session',
    () async {
      final repo = _Repo()..pending = Completer<WmRequisition>();
      final controller = _begin(repo);
      addTearDown(controller.dispose);
      controller.addAll([_white], session: controller.session);
      controller.rows[_white.key]!.qty.text = '25';
      final submitting = controller.submit();
      expect(controller.busy, isTrue);
      await expectLater(controller.submit(), throwsStateError);
      controller.clear();
      repo.pending!.complete(
        const WmRequisition(
          id: 'late',
          requestNo: 'late',
          kind: 'ISSUE',
          status: 'PENDING',
        ),
      );
      expect(await submitting, isNull);
      expect(repo.submissions.length, 1);
      expect(controller.rows, isEmpty);
      expect(controller.lastSubmitted, isNull);
      expect(controller.active, isFalse);
    },
  );

  testWidgets(
    'request mirrors counting: inline stock, confirmed multi-selection, quantities, pending receipt',
    (tester) async {
      if (_captureUi) await loadAuditScreenshotFonts(tester);
      final repo = _Repo();
      await pumpWorkshopMaterialPage(
        tester,
        const WorkshopMaterialBinPage(workshopId: 'w1'),
        repo: repo,
        captureBoundary: _captureUi ? _captureBoundary : null,
        theme: _captureUi ? auditScreenshotTheme(buildLightTheme()) : null,
      );
      await tester.tap(find.byKey(const Key('wm-bin-request')));
      await tester.pumpAndSettle();
      expect(find.byType(WorkshopMaterialRequestPanel), findsNothing);
      expect(find.byKey(const Key('wm-bin-stock-table')), findsOneWidget);
      await _openPicker(tester);
      await tester.tap(find.byKey(ValueKey('goods-picker-item-${_white.key}')));
      await tester.pump();
      await _capture(tester, 'workshop-request-picker-desktop');
      await tester.enterText(find.byType(EditableText).first, '黑');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('goods-picker-item-${_black.key}')));
      await tester.pump();
      expect(find.text('已选 2 项'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
      await tester.pumpAndSettle();
      MasterDataTableView<WmPositionRow> table() =>
          tester.widget(find.byKey(const Key('wm-bin-stock-table')));
      expect(table().items.map((row) => row.key).toSet(), {
        _white.key,
        _black.key,
      });
      expect(
        table().items.firstWhere((row) => row.key == _white.key).bookQty,
        120,
      );
      await tester.enterText(
        find.byKey(ValueKey('wm-request-bags-${_white.key}')),
        '2',
      );
      await tester.enterText(
        find.byKey(ValueKey('wm-request-bags-${_black.key}')),
        '1',
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(ValueKey('wm-request-qty-${_white.key}')),
            )
            .controller!
            .text,
        '50',
      );
      await _capture(tester, 'workshop-request-table-desktop');
      await tester.tap(find.byKey(const Key('wm-request-inline-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.submissions, isEmpty);
      await tester.tap(find.byKey(const Key('wm-request-inline-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认提交'));
      await tester.pumpAndSettle();
      expect(repo.submissions.single.lines.map((line) => line['colorId']), [
        'white',
        'black',
      ]);
      expect(repo.submissions.single.workshop, 'w1');
      expect(find.text('待审批'), findsNWidgets(2));
      await _capture(tester, 'workshop-request-pending-desktop');
      expect(find.byKey(const Key('wm-request-inline-add')), findsNothing);
      expect(
        find.byKey(ValueKey('wm-request-qty-${_white.key}')),
        findsNothing,
      );
      expect(
        table().items.firstWhere((row) => row.key == _white.key).bookQty,
        120,
      );
      await tester.tap(find.byKey(const Key('wm-request-inline-exit')));
      await tester.pumpAndSettle();
      expect(table().items.single.key, _white.key);
      expect(table().items.single.bookQty, 120);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancel by drawer shadow is a no-op and reopening has no stale selection',
    (tester) async {
      final repo = _Repo();
      await pumpWorkshopMaterialPage(
        tester,
        const WorkshopMaterialBinPage(workshopId: 'w1'),
        repo: repo,
      );
      await tester.tap(find.byKey(const Key('wm-bin-request')));
      await tester.pumpAndSettle();
      await _openPicker(tester);
      await tester.tap(find.byKey(ValueKey('goods-picker-item-${_white.key}')));
      await tester.pump();
      await tester.tapAt(const Offset(8, 200));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('wm-request-qty-${_white.key}')),
        findsNothing,
      );
      expect(repo.submissions, isEmpty);
      await _openPicker(tester);
      expect(
        tester
            .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
            .selectedCount,
        0,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'permission boundary invalidates an open request and a selected candidate',
    (tester) async {
      final permissionState = StateProvider<Set<String>>(
        (_) => {Perm.workshopMaterialView},
      );
      final repo = _Repo();
      await pumpWorkshopMaterialPage(
        tester,
        const WorkshopMaterialBinPage(workshopId: 'w1'),
        repo: repo,
        permissionState: permissionState,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkshopMaterialBinPage)),
      );
      await tester.tap(find.byKey(const Key('wm-bin-request')));
      await tester.pumpAndSettle();
      await _openPicker(tester);
      await tester.tap(find.byKey(ValueKey('goods-picker-item-${_white.key}')));
      await tester.pump();
      container.read(permissionState.notifier).state = {};
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-picker-paged-list')), findsNothing);
      expect(find.byKey(const Key('wm-request-inline-submit')), findsNothing);
      expect(repo.submissions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending request blocks system and app-bar back until its receipt completes',
    (tester) async {
      final repo = _Repo()..pending = Completer<WmRequisition>();
      final router = GoRouter(
        initialLocation: '${RouteName.workshopMaterialBin}?workshopId=w1',
        routes: [
          DraftAwareGoRoute(
            path: RouteName.workshopMaterialBin,
            builder: (_, _) => const WorkshopMaterialBinPage(workshopId: 'w1'),
          ),
          DraftAwareGoRoute(
            path: '/away',
            builder: (_, _) => const Scaffold(body: Text('another route')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await pumpWorkshopMaterialPage(
        tester,
        MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
        repo: repo,
      );
      await tester.tap(find.byKey(const Key('wm-bin-request')));
      await tester.pumpAndSettle();
      await _openPicker(tester);
      await tester.tap(find.byKey(ValueKey('goods-picker-item-${_white.key}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(ValueKey('wm-request-qty-${_white.key}')),
        '25',
      );
      await tester.tap(find.byKey(const Key('wm-request-inline-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认提交'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final guard = find.byKey(const Key('wm-bin-request-pop-guard'));
      expect(tester.widget<PopScope<Object?>>(guard).canPop, isFalse);
      await Navigator.of(tester.element(guard)).maybePop();
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.byTooltip('返回')));
      await tester.pump();
      router.go('/away');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        RouteName.workshopMaterialBin,
      );
      expect(find.text('another route'), findsNothing);
      expect(find.byType(WorkshopMaterialBinPage), findsOneWidget);
      expect(repo.submissions, hasLength(1));
      repo.pending!.complete(
        const WmRequisition(
          id: 'request',
          requestNo: 'ZL-1',
          kind: 'ISSUE',
          status: 'PENDING',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<PopScope<Object?>>(guard).canPop, isTrue);
      expect(find.text('待审批'), findsOneWidget);
      router.go('/away');
      await tester.pumpAndSettle();
      expect(find.text('another route'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'compact request actions and picker remain usable with large text, dark=$dark',
      (tester) async {
        if (_captureUi) await loadAuditScreenshotFonts(tester);
        final repo = _Repo();
        await pumpWorkshopMaterialPage(
          tester,
          const WorkshopMaterialBinPage(workshopId: 'w1'),
          repo: repo,
          captureBoundary: _captureUi ? _captureBoundary : null,
          theme: _captureUi
              ? auditScreenshotTheme(
                  dark ? buildDarkTheme() : buildLightTheme(),
                )
              : dark
              ? ThemeData.dark()
              : ThemeData.light(),
          size: const Size(375, 760),
          textScale: 1.3,
        );
        await tester.tap(find.byKey(const Key('wm-bin-request')));
        await tester.pumpAndSettle();
        expect(
          tester
              .getBottomRight(find.byKey(const Key('wm-request-inline-add')))
              .dy,
          lessThanOrEqualTo(760),
        );
        await _openPicker(tester);
        await tester.tap(
          find.byKey(ValueKey('goods-picker-item-${_white.key}')),
        );
        await tester.pump();
        await _capture(
          tester,
          'workshop-request-picker-phone-${dark ? 'dark' : 'light'}',
        );
        await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
        await tester.pumpAndSettle();
        await _capture(
          tester,
          'workshop-request-table-phone-${dark ? 'dark' : 'light'}',
        );
        expect(
          find.byKey(const Key('wm-request-inline-submit')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        expect(repo.submissions, isEmpty);
      },
    );
  }
}
