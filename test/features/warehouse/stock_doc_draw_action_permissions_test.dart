import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

final _drawPermissionsProvider =
    NotifierProvider<_DrawPermissions, Set<String>>(_DrawPermissions.new);

class _DrawPermissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void replace(Set<String> value) => state = value;
}

class _AllowAllStockDocumentScope implements DocumentScopeCapabilityRepository {
  const _AllowAllStockDocumentScope();

  @override
  Future<DocumentScopeCapability> current(DocumentDataScope scope) async =>
      DocumentScopeCapability(
        scope: scope.apiValue,
        writeAll: true,
        writableOwnerIds: const <String>{},
      );
}

class _DrawDetailApi extends ApiClient {
  _DrawDetailApi({required this.status, required this.issuedQty, this.qty = 5})
    : super(Dio());

  int status;
  double issuedQty;
  final double qty;
  Map<String, dynamic>? posted;
  String? postedPath;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/master/warehouses/dict'
      ? [
          {'id': 'main', 'name': '主仓库', 'accountable': false, 'status': '使用'},
          {
            'id': 'hardware',
            'name': '五金仓库',
            'parentId': 'main',
            'accountable': true,
            'status': '禁用',
          },
        ]
      : const <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    postedPath = path;
    posted = Map<String, dynamic>.from(body as Map);
    status = 1;
    issuedQty = qty;
    return get('/stock/docs/draw-1');
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/stock/docs/draw-1') {
      throw StateError('Unexpected GET $path');
    }
    return <String, dynamic>{
      'id': 'draw-1',
      'docType': 'DRAW',
      'billNo': 'LL-TEST-001',
      'billDate': '2026-09-04',
      'status': status,
      'warehouseId': 'hardware',
      'issueStatus': issuedQty > 0 ? 1 : 0,
      'productionLinked': true,
      'canEdit': false,
      'canDelete': false,
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'draw-item-1',
          'lineNo': 1,
          'qty': qty,
          'issuedQty': issuedQty,
          'unitRate': 1,
          'executionSegmentId': 'segment-1',
        },
      ],
    };
  }
}

Future<ProviderContainer> _pumpDrawDetail(
  WidgetTester tester, {
  required int status,
  required double issuedQty,
  required Set<String> permissions,
  _DrawDetailApi? apiOverride,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final api =
      apiOverride ?? _DrawDetailApi(status: status, issuedQty: issuedQty);
  final container = ProviderContainer(
    overrides: [
      currentPermissionsProvider.overrideWith(
        (ref) => ref.watch(_drawPermissionsProvider),
      ),
      isSuperAdminProvider.overrideWithValue(false),
      masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      stockDocRepositoryProvider(
        StockDocType.draw,
      ).overrideWithValue(StockDocRepository(api, StockDocType.draw)),
      documentScopeCapabilityRepositoryProvider.overrideWithValue(
        const _AllowAllStockDocumentScope(),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(_drawPermissionsProvider.notifier).replace(permissions);

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
          docType: StockDocType.draw,
          id: 'draw-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return container;
}

Finder _action(String label) => find.widgetWithText(UtenButton, label);

void main() {
  testWidgets(
    'existing disabled source stays visible and exact four-decimal draw reaches the API',
    (tester) async {
      final api = _DrawDetailApi(status: 0, issuedQty: 0, qty: 0.0001);
      await _pumpDrawDetail(
        tester,
        status: 0,
        issuedQty: 0,
        apiOverride: api,
        permissions: const {
          Perm.stockDocView,
          Perm.stockDocApprove,
          Perm.stockDocIssue,
        },
      );
      await tester.tap(_action('出库'));
      await tester.pumpAndSettle();
      expect(find.text('领料仓库：主仓库 - 五金仓库'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(TextField),
              ),
            )
            .controller
            ?.text,
        '0.0001',
      );
      await tester.tap(find.text('确认出库'));
      await tester.pumpAndSettle();
      expect(api.postedPath, '/stock/docs/draw-1/approve-and-issue');
      expect(api.posted?['lines'], [
        {'itemId': 'draw-item-1', 'qty': 0.0001},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'draft production DRAW exposes only atomic issue and reacts to permission revoke',
    (tester) async {
      final container = await _pumpDrawDetail(
        tester,
        status: 0,
        issuedQty: 0,
        permissions: const <String>{
          Perm.stockDocView,
          Perm.stockDocApprove,
          Perm.stockDocIssue,
        },
      );

      expect(_action('出库'), findsOneWidget);
      expect(tester.widget<UtenButton>(_action('出库')).onPressed, isNotNull);
      expect(_action('审核'), findsNothing);

      container.read(_drawPermissionsProvider.notifier).replace(const <String>{
        Perm.stockDocView,
        Perm.stockDocApprove,
      });
      await tester.pumpAndSettle();

      expect(_action('出库'), findsOneWidget);
      expect(tester.widget<UtenButton>(_action('出库')).onPressed, isNull);
      await tester.tap(_action('出库'));
      await tester.pumpAndSettle();
      expect(find.textContaining('需要同时具备审核和出库权限'), findsOneWidget);

      container.read(_drawPermissionsProvider.notifier).replace(const <String>{
        Perm.stockDocView,
        Perm.stockDocApprove,
        Perm.stockDocIssue,
      });
      await tester.pumpAndSettle();
      expect(tester.widget<UtenButton>(_action('出库')).onPressed, isNotNull);
      expect(_action('审核'), findsNothing);
    },
  );

  testWidgets(
    'approved issued production DRAW exposes audited cancel-issue action',
    (tester) async {
      await _pumpDrawDetail(
        tester,
        status: 1,
        issuedQty: 3,
        permissions: const <String>{
          Perm.stockDocView,
          Perm.stockDocReverseIssue,
        },
      );

      expect(_action('取消出库'), findsOneWidget);
      expect(tester.widget<UtenButton>(_action('取消出库')).onPressed, isNotNull);
      expect(_action('审核'), findsNothing);

      await tester.tap(_action('取消出库'));
      await tester.pumpAndSettle();
      expect(find.text('取消出库'), findsNWidgets(2));
      expect(find.text('取消原因(必填)'), findsOneWidget);
      expect(find.text('确认取消出库'), findsOneWidget);
    },
  );
}
