package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ProcurementOrderClosureReadPort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.UUID;

/** Separate closure progress from the effective commercial finance approval. */
@Service
@RequiredArgsConstructor
public class ProcurementOrderClosureReadService implements ProcurementOrderClosureReadPort {
    private final JdbcTemplate jdbc;

    @Override
    @Transactional(readOnly = true)
    public ClosureRequestView latest(String rawOrderType, UUID orderId) {
        String orderType = ProcurementApprovalProjectionQuery.requireOrderType(rawOrderType);
        var rows = jdbc.query("""
                SELECT approval.id,approval.status,approval.request_type,
                       approval.submission_snapshot #>> '{closureRequest,reason}',
                       approval.rejection_reason,approval.submitted_at,approval.replacement_order_id,
                       COALESCE(purchase.bill_no,subcontract.bill_no)
                FROM procurement_order_approval_cases approval
                LEFT JOIN purchase_orders purchase ON approval.order_type='PURCHASE'
                    AND purchase.id=approval.replacement_order_id
                LEFT JOIN subcontract_orders subcontract ON approval.order_type='SUBCONTRACT'
                    AND subcontract.id=approval.replacement_order_id
                WHERE approval.order_type=? AND approval.order_id=? AND approval.request_type<>'ORDER'
                ORDER BY approval.attempt DESC LIMIT 1
                """, (rs, index) -> new ClosureRequestView(rs.getObject(1, UUID.class),
                rs.getString(2),rs.getString(3),rs.getString(4),rs.getString(5),
                rs.getObject(6, OffsetDateTime.class),rs.getObject(7, UUID.class),rs.getString(8)), orderType, orderId);
        return rows.isEmpty() ? null : rows.getFirst();
    }
}
