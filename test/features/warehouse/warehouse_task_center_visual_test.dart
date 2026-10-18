import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_task_center_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_task_center_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/audit_screenshot_support.dart';
import 'warehouse_task_records_view_test.dart'
    show WarehouseTaskRecordsFakeGateway;

const _output = String.fromEnvironment(
  'WAREHOUSE_VISUAL_OUTPUT',
  defaultValue:
      'C:/Users/bruce/.codex/visualizations/2026/10/12/01a12e35-126f-7991-9146-6cdf303b2e51',
);

class _EmptyApi extends ApiClient {
  _EmptyApi() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == ApiEndpoints.authMe
      ? const {
          'session': {
            'delegableSurfaceKeys': <String>[],
            'documentScopes': <String, dynamic>{},
            'preferences': <String, Object?>{},
          },
        }
      : const {};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

class _NoDrafts extends FormDraftsNotifier {
  @override
  List<FormDraft> build() => const [];
}

WarehouseTaskCenterRecord _record(
  int index,
  String source,
  String record,
  String label,
  String tone, {
  required String status,
  String action = 'NONE',
  bool canHandle = false,
  Map<String, dynamic> data = const {},
}) => WarehouseTaskCenterRecord(
  rowKey: '$source:$record:visual-$index',
  id: 'visual-$index',
  sourceType: source,
  recordType: record,
  status: status,
  statusLabel: label,
  tone: tone,
  billNo: 'WH20261012000$index',
  sourceDocNo: 'SOURCE202610000$index',
  businessDate: '2026-10-12',
  warehouseName: '原料主仓',
  partyName: '示例往来方${index + 1}',
  responsibleName: '仓管甲',
  lineCount: index + 1,
  action: action,
  canHandle: canHandle,
  targetId: 'visual-$index',
  actionData: data,
  line: WarehouseTaskLine(
    key: 'item-$index',
    itemId: 'item-$index',
    lineNo: index,
    goodsCode: 'UT-$index',
    goodsName: index.isEven ? '不锈钢六角螺栓' : '接线端子',
    specification: index.isEven ? 'M8 × 30' : 'UT-2.5',
    colorName: '本色',
    unitName: '件',
    quantity: index * 120,
  ),
);

final _inbound = [
  _record(
    1,
    'PURCHASE',
    'EXPECTATION',
    '采购待登记到货',
    'success',
    status: 'PURCHASE_READY_REGISTER',
    action: 'ARRIVAL_REGISTER',
    canHandle: true,
  ),
  _record(
    2,
    'PURCHASE',
    'ARRIVAL_EXCEPTION',
    '采购超量待财务审批',
    'orange',
    status: 'PURCHASE_EXCEPTION_PENDING_FINANCE',
    action: 'ARRIVAL_EXCEPTION',
  ),
  _record(
    3,
    'SUBCONTRACT',
    'EXPECTATION',
    '委外待登记到货',
    'success',
    status: 'SUBCONTRACT_READY_REGISTER',
    action: 'ARRIVAL_REGISTER',
    canHandle: true,
  ),
  _record(
    4,
    'PURCHASE',
    'PURCHASE_RECEIPT',
    '采购部分合格待办理',
    'orange',
    status: 'PURCHASE_PARTIAL_PASSED',
    action: 'QUALITY_RESULT',
  ),
  _record(
    5,
    'FINISHED',
    'FINISHED_COUNT',
    '成品品质通过待最终点收',
    'success',
    status: 'FINISHED_READY_COUNT',
    action: 'FINISHED_COUNT',
    canHandle: true,
    data: {'pendingQty': 20, 'documentId': 'visual-5'},
  ),
  _record(
    6,
    'OTHER',
    'STOCK_DOCUMENT',
    '其它入库草稿',
    'neutral',
    status: 'OTHER_DRAFT',
    action: 'STOCK_DETAIL',
    data: {'docType': 'OTHER_IN'},
  ),
  _record(
    7,
    'RETURN',
    'STOCK_DOCUMENT',
    '生产退料已收料',
    'neutral',
    status: 'RETURN_STOCKED',
    action: 'HISTORY_DETAIL',
    data: {'docType': 'WDRAW'},
  ),
  _record(
    8,
    'FINISHED',
    'FINISHED_REGISTRATION',
    '成品已登记待检',
    'warning',
    status: 'FINISHED_WAITING_FQC',
    action: 'HISTORY_DETAIL',
  ),
];
final _outbound = [
  _record(
    1,
    'SALES',
    'SALES_SHIPMENT',
    '销售出库 · 待出库',
    'success',
    status: 'SALES_PENDING',
    action: 'SALES_OUTBOUND',
    canHandle: true,
  ),
  _record(
    2,
    'SUBCONTRACT',
    'SUBCONTRACT_MATERIAL_ISSUE',
    '委外出库 · 待发料',
    'success',
    status: 'SUBCONTRACT_PENDING',
    action: 'SUBCONTRACT_OUTBOUND',
    canHandle: true,
  ),
  _record(
    3,
    'DRAW',
    'STOCK_DOC',
    '生产领料 · 部分出库',
    'violet',
    status: 'DRAW_PARTIAL',
    action: 'PRODUCTION_DRAW',
    canHandle: true,
    data: {'docType': 'DRAW'},
  ),
  _record(
    4,
    'OTHER',
    'STOCK_DOC',
    '其它出库 · 草稿待审核',
    'neutral',
    status: 'OTHER_DRAFT',
    action: 'STOCK_EDIT',
    canHandle: true,
    data: {'docType': 'OTHER_OUT'},
  ),
  _record(
    5,
    'FINISHED',
    'STOCK_DOC',
    '产成品出库 · 已出库',
    'success',
    status: 'FINISHED_APPROVED',
    action: 'STOCK_DETAIL',
    data: {'docType': 'FINISHED_OUT'},
  ),
  _record(
    6,
    'SALES',
    'SALES_SHIPMENT',
    '销售出库 · 已撤回',
    'danger',
    status: 'SALES_REVERSED',
    action: 'HISTORY_DETAIL',
  ),
  _record(
    7,
    'SUBCONTRACT',
    'SUBCONTRACT_MATERIAL_ISSUE',
    '委外出库 · 已完成',
    'neutral',
    status: 'SUBCONTRACT_CLOSED',
    action: 'HISTORY_DETAIL',
  ),
];

void main() {
  for (final scenario in [
    ('warehouse-inbound-light-1440', 'inbound', false, const Size(1440, 900)),
    ('warehouse-all-dark-1440', 'outbound', true, const Size(1440, 900)),
    ('warehouse-inbound-light-375', 'inbound', false, const Size(375, 900)),
  ]) {
    testWidgets('真实任务中心渲染 ${scenario.$1}', (tester) async {
      await tester.binding.setSurfaceSize(scenario.$4);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.binding.setSurfaceSize(null);
        tester.view.resetDevicePixelRatio();
      });
      await loadAuditScreenshotFonts(tester);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final boundary = GlobalKey();
      final gateway = WarehouseTaskRecordsFakeGateway(
        scenario.$2 == 'inbound' ? _inbound : _outbound,
      );
      final router = GoRouter(
        initialLocation: '/warehouse/tasks',
        routes: [
          GoRoute(
            path: '/warehouse/tasks',
            builder: (_, _) => WarehouseTaskCenterPage(
              initialGroup: scenario.$2,
              initialSection: 'ALL',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            warehouseTaskCenterRepositoryProvider.overrideWithValue(gateway),
            apiClientProvider.overrideWithValue(_EmptyApi()),
            apiBaseUrlProvider.overrideWithValue('https://unit.test/api'),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'visual-warehouse'),
            ),
            warehouseTaskScopeProvider.overrideWithValue(
              const WarehouseTaskScope.all(),
            ),
            myWarehouseScopeProvider.overrideWith(
              (_) async => const MyWarehouseScope(
                role: WarehouseScopeRole.supervisor,
                canSelectAll: true,
              ),
            ),
            currentPermissionsProvider.overrideWithValue({
              Perm.stockDocView,
              Perm.stockDocCreate,
              Perm.stockDocApprove,
            }),
            isSuperAdminProvider.overrideWithValue(true),
            formDraftsProvider.overrideWith(_NoDrafts.new),
            sharedPreferencesProvider.overrideWithValue(preferences),
            fixedBadgeSummaryOverride(badgeSummaryFixture()),
          ],
          child: RepaintBoundary(
            key: boundary,
            child: MaterialApp.router(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: auditScreenshotTheme(buildLightTheme()),
              darkTheme: auditScreenshotTheme(buildDarkTheme()),
              themeMode: scenario.$3 ? ThemeMode.dark : ThemeMode.light,
              routerConfig: router,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.calls.last.source, 'ALL');
      expect(find.text('委外损耗'), findsNothing);
      expect(find.textContaining('金额'), findsNothing);
      expect(tester.takeException(), isNull);
      final repaint =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await repaint.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(_output).create(recursive: true);
        await File(
          '$_output/${scenario.$1}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
