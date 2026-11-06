package com.uten.imp.features.finance.procurement;

import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import org.hibernate.annotations.Immutable;
import org.hibernate.annotations.Subselect;
import org.hibernate.annotations.Synchronize;
import java.util.UUID;

/** Read-only relation over existing cases; never a workflow or authorization authority. */
@Entity
@Immutable
@Subselect("SELECT id,order_type,order_id,request_type,status,attempt FROM procurement_order_approval_cases")
@Synchronize("procurement_order_approval_cases")
public class ProcurementOrderApprovalRead {
    @Id private UUID id;
    @jakarta.persistence.Column(name="order_type") private String orderType;
    @jakarta.persistence.Column(name="order_id") private UUID orderId;
    @jakarta.persistence.Column(name="request_type") private String requestType;
    private String status;
    private int attempt;
    protected ProcurementOrderApprovalRead() { }
}
