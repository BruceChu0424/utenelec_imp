import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_delivery_processing_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_component_processing_actions.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_picking_fields.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

Map<String, dynamic> component({
  bool issued = false,
  bool received = false,
}) => {
  'id': 'component',
  'shipmentItemId': 'parent',
  'goodsId': 'part',
  'quantityExact': '1',
  'originalQuantityExact': '1',
  'processedQty': received ? '1' : '0',
  'revision': issued ? 2 : 1,
  'path': ['edge'],
  'operations': ['LASER'],
  'processingIssuedAt': issued ? '2026-11-04T10:00:00Z' : null,
  'processingReceivedAt': received ? '2026-11-04T11:00:00Z' : null,
  'processingWorkshopId': 'workshop',
  'warehouseId': 'warehouse',
  'stockPlace': 'A-1',
  'warehouseChoices': [
    {'warehouseId': 'warehouse', 'warehouseName': '五金仓', 'availableQty': '1'},
  ],
};
WarehouseSalesOutboundDetail handoverDetail({
  bool issued = false,
  bool received = false,
}) => WarehouseSalesOutboundDetail.fromJson({
  'id': 'shipment',
  'warehouseWorkStatus': 'PENDING_PICK',
  'allowedWarehouseTargets': ['SHIPPED'],
  'lines': [
    {'id': 'parent', 'goodsId': 'product', 'quantity': '1'},
  ],
  'deliveryComponents': [component(issued: issued, received: received)],
});

class _Repository extends WarehouseDeliveryProcessingRepository {
  _Repository() : super(ApiClient(Dio()));
  final requests = <Map<String, dynamic>>[];
  int lookups = 0;
  bool found = false;
  Completer<WarehouseDeliveryComponent>? response;
  @override
  Future<WarehouseDeliveryComponent> submit(
    String shipmentId,
    String componentId,
    String action,
    Map<String, dynamic> body,
  ) {
    requests.add({
      'shipmentId': shipmentId,
      'componentId': componentId,
      'action': action,
      'body': Map<String, dynamic>.from(body),
    });
    return response?.future ??
        Future.error(TimeoutException('unknown outcome'));
  }

  @override
  Future<Map<String, dynamic>> result(
    String shipmentId,
    String requestId,
  ) async {
    lookups++;
    return found
        ? {
            'found': true,
            'componentId': 'component',
            'action': 'ISSUE',
            'requestHash': 'server-hash',
          }
        : {'found': false};
  }
}

class _Gateway implements WarehouseSalesOutboundGateway {
  @override
  Future<WarehouseSalesOutboundDetail> detail(String id) async => detailIssued;
  final detailIssued = handoverDetail(issued: true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository,
  WarehouseSalesPickingDraft draft,
  VoidCallback changed, {
  Future<void> Function()? checkpoint,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(const {
          Perm.warehouseSalesOutboundView,
          Perm.warehouseSalesOutboundExecute,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sensitiveReadBoundaryProvider.overrideWithValue(
          SensitiveReadBoundary(
            identity: null,
            api: repository.api,
            permissions: const {Perm.warehouseSalesOutboundExecute},
            superAdmin: false,
          ),
        ),
        warehouseDeliveryProcessingRepositoryProvider.overrideWithValue(
          repository,
        ),
        warehouseSalesOutboundRepositoryProvider.overrideWithValue(_Gateway()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: WarehouseComponentProcessingActions(
            detail: draft.detail,
            component: draft.detail.deliveryComponents.single,
            draft: draft,
            onFactsChanged: changed,
            onInputChanged: () {},
            checkpoint: checkpoint ?? () async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a failed durable checkpoint cannot dispatch the warehouse command',
    (tester) async {
      final draft = WarehouseSalesPickingDraft(handoverDetail());
      final repository = _Repository();
      draft.setComponentRequest('component', {
        'shipmentId': 'shipment',
        'componentId': 'component',
        'action': 'ISSUE',
        'status': 'NOT_FOUND',
        'body': {
          'expectedVersion': 1,
          'warehouseId': 'warehouse',
          'stockPlace': 'A-1',
          'requestId': 'original-request',
          'evidence': 'handover',
        },
      });
      await _pump(
        tester,
        repository,
        draft,
        () {},
        checkpoint: () async => throw StateError('local checkpoint failed'),
      );
      await tester.tap(find.text('按原请求重试'));
      await tester.pumpAndSettle();
      expect(repository.requests, isEmpty);
      expect(draft.componentRequests['component']!['status'], 'UNKNOWN');
      expect(find.text('核对原交接结果'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      draft.dispose();
    },
  );

  testWidgets(
    'issuing retains one original version/warehouse/evidence intent during rapid actions',
    (tester) async {
      final draft = WarehouseSalesPickingDraft(handoverDetail());
      final repository = _Repository()
        ..response = Completer<WarehouseDeliveryComponent>();
      var refreshed = 0;
      await _pump(tester, repository, draft, () => refreshed++);
      await tester.tap(find.text('发至加工'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '实际交接单A');
      await tester.tap(find.text('发至加工').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(repository.requests, hasLength(1));
      final body = repository.requests.single['body'] as Map;
      expect(body['expectedVersion'], 1);
      expect(body['warehouseId'], 'warehouse');
      expect(body['stockPlace'], 'A-1');
      expect(body['evidence'], '实际交接单A');
      expect(body['requestId'], matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(draft.componentRequests['component']!['body'], body);
      await tester.tap(find.text('发至加工').first, warnIfMissed: false);
      await tester.pump();
      expect(repository.requests, hasLength(1));
      repository.response!.complete(
        WarehouseDeliveryComponent.fromJson(component(issued: true)),
      );
      await tester.pumpAndSettle();
      expect(draft.componentRequests, isEmpty);
      expect(refreshed, 1);
      await tester.pumpWidget(const SizedBox());
      draft.dispose();
    },
  );

  testWidgets(
    'unknown handover survives draft and queries before retrying the identical request',
    (tester) async {
      final draft = WarehouseSalesPickingDraft(handoverDetail());
      final repository = _Repository();
      var refreshed = 0;
      final original = <String, dynamic>{
        'shipmentId': 'shipment',
        'componentId': 'component',
        'action': 'ISSUE',
        'status': 'UNKNOWN',
        'body': {
          'expectedVersion': 1,
          'warehouseId': 'warehouse',
          'stockPlace': 'A-1',
          'requestId': 'original-request',
          'evidence': 'handover',
        },
      };
      draft.setComponentRequest('component', original);
      await _pump(tester, repository, draft, () => refreshed++);
      expect(draft.validate(), isFalse);
      expect(find.text('按原请求重试'), findsNothing);
      await tester.tap(find.text('核对原交接结果'));
      await tester.pumpAndSettle();
      expect(repository.lookups, 1);
      expect(repository.requests, isEmpty);
      await tester.tap(find.text('按原请求重试'));
      await tester.pumpAndSettle();
      expect(repository.requests.single['body'], original['body']);
      expect(draft.componentRequests['component']!['status'], 'UNKNOWN');
      expect(find.text('按原请求重试'), findsNothing);
      final restored = WarehouseSalesPickingDraft(handoverDetail());
      restored.restoreInput(draft.captureInput());
      expect(
        restored.componentRequests['component']!['body'],
        original['body'],
      );
      repository.found = true;
      await tester.tap(find.text('核对原交接结果'));
      await tester.pumpAndSettle();
      expect(draft.componentRequests, isEmpty);
      expect(refreshed, 1);
      expect(repository.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      draft.dispose();
      restored.dispose();
    },
  );

  test(
    'reporting alone does not permit shipment until the warehouse receives the material',
    () {
      final issued = WarehouseSalesPickingDraft(handoverDetail(issued: true));
      final received = WarehouseSalesPickingDraft(
        handoverDetail(issued: true, received: true),
      );
      expect(issued.validate(), isFalse);
      expect(received.validate(), isTrue);
      issued.dispose();
      received.dispose();
    },
  );
}
