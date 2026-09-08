package com.uten.imp.features.finance.procurement;

import com.uten.imp.application.port.ProcurementReviewCancellationPort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.util.UUID;

/** Cancel only pending attempts. Approved case history and quantity-change evidence remain immutable. */
@Service
@RequiredArgsConstructor
public class ProcurementReviewCancellationService implements ProcurementReviewCancellationPort {
    private final JdbcTemplate jdbc;
    private final TaskClaimMutationGuardPort claims;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.features.notice.ChainNoticeService notices;

    @Override
    @Transactional(propagation=Propagation.MANDATORY)
    public void cancelUnclaimedPending(String rawType,UUID orderId,String sourceAction) {
        String type=ProcurementApprovalProjectionQuery.requireOrderType(rawType);
        if (!java.util.Set.of("ORDER_CANCELED","ORDER_REVERSED").contains(sourceAction)) {
            throw new IllegalArgumentException("Unsupported order cancellation source");
        }
        String table="PURCHASE".equals(type) ? "purchase_orders" : "subcontract_orders";
        jdbc.queryForList("SELECT id FROM "+table+" WHERE id=? FOR UPDATE",UUID.class,orderId);
        var cases=jdbc.query("""
                SELECT id,version FROM procurement_order_approval_cases
                WHERE order_type=? AND order_id=? AND status='PENDING' ORDER BY id FOR UPDATE
                """,(rs,n) -> new Pending(rs.getObject("id",UUID.class),rs.getLong("version")),type,orderId);
        for (Pending pending:cases) claims.requireNoActiveClaim("PROCUREMENT_FINANCE_APPROVE",pending.id().toString());
        for (Pending pending:cases) {
            jdbc.update("""
                    UPDATE procurement_order_approval_cases SET status='CANCELED',version=version+1,updated_at=now()
                    WHERE id=? AND status='PENDING'
                    """,pending.id());
            jdbc.update("""
                    INSERT INTO procurement_order_approval_events(case_id,event_type,actor_user_id,actor_employee_id,reason,event_snapshot)
                    VALUES (?,'CANCELED',?,?,?,jsonb_build_object('orderType',?::text,'orderId',?::text,'sourceAction',?::text,'previousVersion',?::bigint))
                    """,pending.id(),currentUser.requireId(),currentUser.requireEmployeeId(),sourceAction,
                    type,orderId.toString(),sourceAction,pending.version());
            notices.resolveReviewNotices("PROCUREMENT_APPROVAL_CASE",pending.id(),sourceAction);
        }
    }
    private record Pending(UUID id,long version) {}
}
