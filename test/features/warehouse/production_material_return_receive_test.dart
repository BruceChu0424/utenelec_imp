import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/production_material_return_receive_dialog.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

const _warehouses = [
  WarehouseDictEntry(id: 'main', name: '主仓', isAccountable: false),
  WarehouseDictEntry(id: 'normal', name: '五金仓', parentId: 'main'),
  WarehouseDictEntry(
    id: 'technical',
    name: '车间位置',
    parentId: 'main',
    isLineSide: true,
  ),
  WarehouseDictEntry(
    id: 'disabled',
    name: '停用仓',
    parentId: 'main',
    status: '禁用',
  ),
  WarehouseDictEntry(id: 'other', name: '其他主仓'),
];

class _Api extends ApiClient {
  _Api() : super(Dio());
  int status = 0;
  bool loseResponse = true;
  bool reverseBlocked = false;
  int reverseCalls = 0;
  String? warehouse;
  final posts = <Map<String, dynamic>>[];
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/master/warehouses/dict'
      ? [
          for (final w in _warehouses)
            {
              'id': w.id,
              'name': w.name,
              'parentId': w.parentId,
              'accountable': w.isAccountable,
              'lineSide': w.isLineSide,
              'status': w.status,
            },
        ]
      : [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'id': 'return-1',
    'docType': 'WDRAW',
    'billNo': 'TL001',
    'status': status,
    'productionLinked': true,
    'productionMaterialReturn': true,
    'warehouseId': warehouse,
    'materialReturnSourceWarehouseId': 'technical',
    'materialReturnMainWarehouseId': 'main',
    'items': <Map<String, dynamic>>[],
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/stock/docs/return-1/reverse') {
      reverseCalls++;
      if (reverseBlocked) {
        throw ApiException(
          'CONFLICT',
          '这批余料已被后续工单领用，请先处理对应后续领料，再撤回收仓',
          httpStatus: 409,
        );
      }
      status = -1;
      return get('/stock/docs/return-1');
    }
    expect(path, '/stock/docs/return-1/material-return/confirm');
    posts.add(Map<String, dynamic>.from(body as Map));
    warehouse = posts.last['warehouseId'] as String;
    status = 1;
    if (loseResponse) {
      loseResponse = false;
      throw NetworkTimeoutException();
    }
    return get('/stock/docs/return-1');
  }
}

class _Scope implements DocumentScopeCapabilityRepository {
  @override
  Future<DocumentScopeCapability> current(DocumentDataScope scope) async =>
      DocumentScopeCapability(
        scope: scope.apiValue,
        writeAll: false,
        writableOwnerIds: const {},
      );
}

Future<void> _openReceived(
  WidgetTester tester,
  _Api api, {
  required bool canReverse,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      currentPermissionsProvider.overrideWithValue({
        Perm.stockDocView,
        if (canReverse) Perm.stockDocReverse,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      stockDocRepositoryProvider(
        StockDocType.wdraw,
      ).overrideWithValue(StockDocRepository(api, StockDocType.wdraw)),
      documentScopeCapabilityRepositoryProvider.overrideWithValue(_Scope()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => Stack(
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
        home: const StockDocDetailPage(
          docType: StockDocType.wdraw,
          id: 'return-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _dialogApp({required Widget home}) =>
    ProviderScope(child: MaterialApp(home: home));

void main() {
  for (final blocked in [false, true]) {
    testWidgets(
      'received production return can reverse through the page, downstream blocked=$blocked',
      (tester) async {
        final api = _Api()
          ..status = 1
          ..warehouse = 'normal'
          ..reverseBlocked = blocked;
        await _openReceived(tester, api, canReverse: true);
        await tester.tap(find.widgetWithText(UtenButton, '撤回收仓'));
        await tester.pumpAndSettle();
        expect(find.text('核对并撤回收仓'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '撤回收仓'));
        await tester.pumpAndSettle();
        expect(api.reverseCalls, 1);
        expect(api.status, blocked ? 1 : -1);
        if (blocked) {
          expect(find.text('这批余料已被后续工单领用，请先处理对应后续领料，再撤回收仓'), findsOneWidget);
          expect(find.widgetWithText(UtenButton, '撤回收仓'), findsOneWidget);
        } else {
          expect(find.widgetWithText(UtenButton, '撤回收仓'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('view-only receiving staff have no reversal action', (
    tester,
  ) async {
    final api = _Api()
      ..status = 1
      ..warehouse = 'normal';
    await _openReceived(tester, api, canReverse: false);
    expect(find.widgetWithText(UtenButton, '撤回收仓'), findsNothing);
    expect(api.reverseCalls, 0);
  });

  for (final width in [390.0, 1100.0]) {
    testWidgets(
      'receiving at $width selects only a normal active same-main leaf',
      (tester) async {
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? result;
        await tester.pumpWidget(
          _dialogApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showProductionMaterialReturnReceiveDialog(
                      context,
                      hierarchy: _warehouses,
                      mainWarehouseId: 'main',
                      initialWarehouseId: 'technical',
                    );
                  },
                  child: const Text('收仓'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('收仓'));
        await tester.pumpAndSettle();
        final field = tester.widget<UtenDropdownField>(
          find.byType(UtenDropdownField),
        );
        expect(field.value, isNull);
        expect(
          field.items.where((item) => item.enabled).map((item) => item.value),
          ['normal'],
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '确认收料'))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byType(UtenDropdownField));
        await tester.pumpAndSettle();
        await tester.tap(find.text('五金仓').last);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '确认收料'));
        await tester.pumpAndSettle();
        expect(result, 'normal');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'missing main scope cannot confirm and cancellation has no warehouse result',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        _dialogApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showProductionMaterialReturnReceiveDialog(
                    context,
                    hierarchy: _warehouses,
                    mainWarehouseId: null,
                    initialWarehouseId: 'normal',
                  );
                },
                child: const Text('收仓'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('收仓'));
      await tester.pumpAndSettle();
      expect(find.byTooltip(RegExp('来源主仓尚未读取，请刷新单据')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认收料'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );

  for (final approve in [true, false]) {
    testWidgets(
      'material return approval permission=$approve and uncertain retry retains exact warehouse/key',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = _Api();
        final container = ProviderContainer(
          overrides: [
            currentPermissionsProvider.overrideWithValue({
              Perm.stockDocView,
              if (approve) Perm.stockDocApprove,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            stockDocRepositoryProvider(
              StockDocType.wdraw,
            ).overrideWithValue(StockDocRepository(api, StockDocType.wdraw)),
            documentScopeCapabilityRepositoryProvider.overrideWithValue(
              _Scope(),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: (context, child) => Stack(
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
              home: const StockDocDetailPage(
                docType: StockDocType.wdraw,
                id: 'return-1',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('待仓库确认'), findsOneWidget);
        final action = find.widgetWithText(UtenButton, '确认实收并入库');
        expect(action, approve ? findsOneWidget : findsNothing);
        if (approve) {
          await tester.tap(action);
          await tester.pumpAndSettle();
          await tester.tap(find.byType(UtenDropdownField));
          await tester.pumpAndSettle();
          await tester.tap(find.text('五金仓').last);
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, '确认收料'));
          await tester.pumpAndSettle();
          expect(api.posts.single['warehouseId'], 'normal');
          expect(find.text('重试本次收料'), findsOneWidget);
          await tester.tap(find.text('重试本次收料'));
          await tester.pumpAndSettle();
          expect(api.posts, hasLength(2));
          expect(api.posts.first, api.posts.last);
          expect(api.posts.first.keys.toSet(), {
            'warehouseId',
            'idempotencyKey',
          });
          expect(find.text('待仓库确认'), findsNothing);
        } else {
          expect(api.posts, isEmpty);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
