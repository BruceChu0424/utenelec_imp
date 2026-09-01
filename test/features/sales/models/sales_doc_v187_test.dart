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
          'financeAudit': 1,
          'financeAuditedAt': '2026-08-31T09:00:00+08:00',
        });
        final legacyShape = SalesDocListItem.fromJson(const {
          'id': 'shipment-2',
        });

        expect(
          withWorkflow.warehouseWorkStatus,
          SalesWarehouseWorkStatus.pendingPick,
        );
        expect(withWorkflow.canManageWarehouseWork, isTrue);
        expect(withWorkflow.financeAudit, 1);
        expect(withWorkflow.financeAuditedAt, isNotNull);
        expect(withWorkflow.totalOriginal, 100);
        expect(withWorkflow.totalLocal, 720);
        expect(legacyShape.warehouseWorkStatus, isNull);
        expect(legacyShape.canManageWarehouseWork, isFalse);
      },
    );

    test('finance audit preview preserves server decimal facts', () {
      final info = ShipmentFinanceAuditInfo.fromJson(const {
        'shipmentId': 'shipment-1',
        'financeAudit': 0,
        'clientName': '月结客户',
        'salesPaymentType': 'MONTHLY',
        'settlementMethodName': '月结30天',
        'outstanding': '1865812.8900',
        'creditFloor': 50000,
        'overFloor': '-0.2900',
        'availablePrepaymentOriginal': '125.5000',
        'availablePrepaymentLocal': '904.2500',
      });

      expect(info.shipmentId, 'shipment-1');
      expect(info.salesPaymentType, 'MONTHLY');
      expect(info.outstanding, '1865812.8900');
      expect(info.creditFloor, '50000');
      expect(info.overFloor, '-0.2900');
      expect(info.availablePrepaymentOriginal, '125.5000');
      expect(info.availablePrepaymentLocal, '904.2500');
      expect(salesShipmentFinanceAuditLabel(info.financeAudit), '待财务审核');
    });

    test(
      'goods identity prefers the document snapshot over current master',
      () {
        final item = SalesDocItem.fromJson(const {
          'id': 'line-1',
          'goodsId': 'goods-uuid',
          'goodsCodeSnapshot': 'V6000123',
          'goodsNameSnapshot': '历史货品名',
          'goodsSnapshotSource': 'MASTER_AT_APPROVAL',
          'goodsSnapshotLockedAt': '2026-08-14T09:30:00+08:00',
        });

        expect(item.goodsSnapshotSource, 'MASTER_AT_APPROVAL');
        expect(item.goodsSnapshotLockedAt, isNotNull);
        expect(salesGoodsIdentityLabel(item, '当前货品名'), 'V6000123 · 历史货品名');
        expect(
          salesGoodsIdentityLabel(
            const SalesDocItem(id: 'legacy-line'),
            '当前货品名',
          ),
          '当前货品名',
        );
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
        salesWarehouseWorkStatusLabel(SalesWarehouseWorkStatus.legacyPending),
        '历史迁移异常',
      );
      expect(
        salesWarehouseWorkStatusHint(SalesWarehouseWorkStatus.legacyPending),
        contains('历史直接审核流程已停用'),
      );
      expect(
        salesShipmentAllowsFinanceAudit(SalesWarehouseWorkStatus.legacyPending),
        isFalse,
      );
      expect(
        salesShipmentAllowsFinanceAudit(SalesWarehouseWorkStatus.pendingPick),
        isTrue,
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
