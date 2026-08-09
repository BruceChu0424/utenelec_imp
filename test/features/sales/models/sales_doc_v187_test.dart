import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';

void main() {
  group('V187 sales document parsing', () {
    test('detail parses shipment policy and warehouse workflow facts', () {
      final detail = SalesDocDetail.fromJson(const {
        'id': 'order-or-shipment-1',
        'shipmentPolicy': 'CUSTOMER_CONFIRM',
        'partialShipmentConfirmedAt': '2026-08-01T09:30:00+08:00',
        'partialShipmentConfirmedBy': 'employee-1',
        'partialShipmentConfirmationReason': '客户微信确认',
        'warehouseWorkStatus': 'PICKED',
        'warehouseWorkUpdatedAt': '2026-08-01T10:00:00+08:00',
        'pickingStartedAt': '2026-08-01T09:40:00+08:00',
        'pickedAt': '2026-08-01T10:00:00+08:00',
        'handedOverAt': '2026-08-01T10:30:00+08:00',
        'warehouseExceptionReason': '外箱破损',
        'canManageWarehouseWork': true,
      });

      expect(detail.shipmentPolicy, SalesShipmentPolicy.customerConfirm);
      expect(detail.partialShipmentConfirmed, isTrue);
      expect(detail.partialShipmentConfirmedBy, 'employee-1');
      expect(detail.partialShipmentConfirmationReason, '客户微信确认');
      expect(detail.warehouseWorkStatus, SalesWarehouseWorkStatus.picked);
      expect(detail.warehouseWorkUpdatedAt, isNotNull);
      expect(detail.pickingStartedAt, isNotNull);
      expect(detail.pickedAt, isNotNull);
      expect(detail.handedOverAt, isNotNull);
      expect(detail.warehouseExceptionReason, '外箱破损');
      expect(detail.canManageWarehouseWork, isTrue);
    });

    test(
      'list item parses warehouse capability without assuming it exists',
      () {
        final withWorkflow = SalesDocListItem.fromJson(const {
          'id': 'shipment-1',
          'totalOriginal': 100,
          'totalLocal': 720,
          'warehouseWorkStatus': 'PENDING_PICK',
          'canManageWarehouseWork': true,
        });
        final legacyShape = SalesDocListItem.fromJson(const {
          'id': 'shipment-2',
        });

        expect(
          withWorkflow.warehouseWorkStatus,
          SalesWarehouseWorkStatus.pendingPick,
        );
        expect(withWorkflow.canManageWarehouseWork, isTrue);
        expect(withWorkflow.totalOriginal, 100);
        expect(withWorkflow.totalLocal, 720);
        expect(legacyShape.warehouseWorkStatus, isNull);
        expect(legacyShape.canManageWarehouseWork, isFalse);
      },
    );
  });

  group('V187 workflow safety decisions', () {
    test('warehouse actions follow the server state machine', () {
      expect(
        salesWarehouseWorkActionsFor(SalesWarehouseWorkStatus.pendingPick),
        const [
          SalesWarehouseWorkAction.startPicking,
          SalesWarehouseWorkAction.reportException,
        ],
      );
      expect(
        salesWarehouseWorkActionsFor(SalesWarehouseWorkStatus.picking),
        const [
          SalesWarehouseWorkAction.finishPicking,
          SalesWarehouseWorkAction.reportException,
        ],
      );
      expect(
        salesWarehouseWorkActionsFor(SalesWarehouseWorkStatus.picked),
        const [
          SalesWarehouseWorkAction.handOver,
          SalesWarehouseWorkAction.reportException,
        ],
      );
      expect(
        salesWarehouseWorkActionsFor(SalesWarehouseWorkStatus.exception),
        const [SalesWarehouseWorkAction.restorePending],
      );
      expect(
        salesWarehouseWorkActionsFor(SalesWarehouseWorkStatus.legacyPending),
        isEmpty,
      );
    });

    test('legacy, finance, order-link and reverse gates fail closed', () {
      expect(
        salesShipmentUsesLegacyApproval(SalesWarehouseWorkStatus.legacyPending),
        isTrue,
      );
      expect(
        salesShipmentUsesLegacyApproval(SalesWarehouseWorkStatus.pendingPick),
        isFalse,
      );
      expect(
        salesShipmentAllowsFinanceAudit(SalesWarehouseWorkStatus.pendingPick),
        isTrue,
      );
      expect(
        salesShipmentAllowsFinanceAudit(SalesWarehouseWorkStatus.picking),
        isFalse,
      );
      expect(
        salesShipmentRequiresOrderLinks(isNew: true, warehouseWorkStatus: null),
        isTrue,
      );
      expect(
        salesShipmentRequiresOrderLinks(
          isNew: false,
          warehouseWorkStatus: SalesWarehouseWorkStatus.pendingPick,
        ),
        isTrue,
      );
      expect(
        salesShipmentRequiresOrderLinks(
          isNew: false,
          warehouseWorkStatus: SalesWarehouseWorkStatus.legacyPending,
        ),
        isFalse,
      );
      expect(salesShipmentFirstUnlinkedLine(const ['order-line-1', null]), 2);
      expect(
        salesShipmentFirstUnlinkedLine(const ['order-line-1', 'order-line-2']),
        0,
      );
      expect(
        salesShipmentAllowsDirectReverse(
          warehouseWorkStatus: SalesWarehouseWorkStatus.legacyPending,
          handedOverAt: null,
        ),
        isTrue,
      );
      expect(
        salesShipmentAllowsDirectReverse(
          warehouseWorkStatus: SalesWarehouseWorkStatus.shipped,
          handedOverAt: null,
        ),
        isFalse,
      );
      expect(
        salesShipmentAllowsDirectReverse(
          warehouseWorkStatus: SalesWarehouseWorkStatus.pendingPick,
          handedOverAt: '2026-08-01T10:30:00+08:00',
        ),
        isFalse,
      );
      expect(
        salesShipmentLocksDraftEdit(
          documentStatus: kSalesStatusDraft,
          financeAudit: 1,
          warehouseWorkStatus: SalesWarehouseWorkStatus.pendingPick,
        ),
        isTrue,
      );
      expect(
        salesShipmentLocksDraftEdit(
          documentStatus: kSalesStatusDraft,
          financeAudit: 0,
          warehouseWorkStatus: SalesWarehouseWorkStatus.pendingPick,
        ),
        isFalse,
      );
      expect(
        salesShipmentLocksDraftEdit(
          documentStatus: kSalesStatusDraft,
          financeAudit: 1,
          warehouseWorkStatus: SalesWarehouseWorkStatus.picking,
        ),
        isFalse,
      );
      expect(
        salesShipmentLocksDraftEdit(
          documentStatus: kSalesStatusApproved,
          financeAudit: 1,
          warehouseWorkStatus: SalesWarehouseWorkStatus.pendingPick,
        ),
        isFalse,
      );
    });

    test(
      'planned, produced or linked chain states block order cancellation',
      () {
        expect(
          salesOrderHasProductionAssociation(const [
            SalesDocItem(id: 'line-1', plannedQty: 1),
          ]),
          isTrue,
        );
        expect(
          salesOrderHasProductionAssociation(const [
            SalesDocItem(id: 'line-1', chainStatus: 5),
          ]),
          isTrue,
        );
        expect(
          salesOrderHasProductionAssociation(const [
            SalesDocItem(id: 'line-1', reservedQty: 1),
          ]),
          isFalse,
        );
        expect(
          salesOrderHasShippedQuantity(const [
            SalesDocItem(id: 'line-1', shippedQty: 1),
          ]),
          isTrue,
        );
      },
    );
  });
}
