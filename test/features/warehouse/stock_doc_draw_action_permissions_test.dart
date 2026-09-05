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
  _DrawDetailApi({required this.status, required this.issuedQty})
    : super(Dio());

  final int status;
  final double issuedQty;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const <Map<String, dynamic>>[];

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
      'issueStatus': issuedQty > 0 ? 1 : 0,
      'productionLinked': true,
      'canEdit': false,
      'canDelete': false,
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'draw-item-1',
          'lineNo': 1,
          'qty': 5,
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
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final api = _DrawDetailApi(status: status, issuedQty: issuedQty);
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
