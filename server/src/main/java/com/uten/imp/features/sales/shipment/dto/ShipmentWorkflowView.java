package com.uten.imp.features.sales.shipment.dto;

import com.uten.imp.features.sales.shipment.CustomerShipmentPolicy;
import com.uten.imp.features.sales.shipment.SalesShipment;
import lombok.Getter;
import lombok.Setter;
import java.time.OffsetDateTime;
import java.util.UUID;

/** Non-monetary workflow metadata shared by list/detail without changing historical constructors. */
@Getter
@Setter
public class ShipmentWorkflowView {
    private String shipmentKind;
    private String billingMode;
    private String directPurpose;
    private String freeReason;
    private long reviewRevision;
    private boolean salesConfirmed;
    private UUID salesConfirmedBy;
    private OffsetDateTime salesConfirmedAt;
    private boolean canConfirmSales;
    private boolean financeRejected;
    private boolean financeReviewPending;
    private String financeRejectionReason;

    public void populate(SalesShipment document,CustomerShipmentPolicy policy) {
        shipmentKind=document.getShipmentKind();billingMode=document.getBillingMode();
        directPurpose=document.getDirectPurpose();freeReason=document.getFreeReason();
        reviewRevision=document.getReviewRevision();salesConfirmed=CustomerShipmentPolicy.salesConfirmed(document);
        salesConfirmedBy=document.getSalesConfirmedBy();salesConfirmedAt=document.getSalesConfirmedAt();
        financeRejected=document.isFinanceRejected();financeRejectionReason=document.getFinanceRejectionReason();
        financeReviewPending=document.getStatus()!=null&&document.getStatus()==0&&!document.isDeleted()&&!document.isRejected()
                &&!financeRejected&&!"LEGACY".equals(shipmentKind)&&document.getFinanceAudit()!=null&&document.getFinanceAudit()==0
                &&SalesShipment.WORK_PENDING_PICK.equals(document.getWarehouseWorkStatus())
                &&(document.getFinanceGateVersion()!=null&&document.getFinanceGateVersion()<2||salesConfirmed);
        canConfirmSales=policy.can(shipmentKind,"approve")&&document.getStatus()!=null&&document.getStatus()==0
                &&document.getFinanceGateVersion()!=null&&document.getFinanceGateVersion()>=2
                &&!document.isRejected()&&!financeRejected&&!salesConfirmed&&SalesShipment.WORK_PENDING_PICK.equals(document.getWarehouseWorkStatus());
    }
}
