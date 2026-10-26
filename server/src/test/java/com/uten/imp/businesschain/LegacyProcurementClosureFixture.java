package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.finance.procurement.ProcurementOrderClosureService.ClosurePreview;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** A pre-upgrade pending request, created without invoking the new direct-execution endpoint. */
final class LegacyProcurementClosureFixture {
    private LegacyProcurementClosureFixture() {}

    static FinanceApproval pending(JdbcTemplate db, ClosurePreview preview, FullChainEndToEndTest.World world,
                                   String mode) {
        try {
            var mapper = new ObjectMapper().findAndRegisterModules();
            String previous = db.queryForObject("SELECT submission_snapshot::text FROM procurement_order_approval_cases WHERE order_type=? AND order_id=? AND request_type='ORDER' ORDER BY attempt DESC LIMIT 1",
                    String.class, preview.orderType(), preview.orderId());
            Map<String,Object> snapshot = mapper.readValue(previous,
                    new com.fasterxml.jackson.core.type.TypeReference<LinkedHashMap<String,Object>>() {});
            snapshot.put("closureRequest", Map.of("mode", mode, "reason", "升级前等待财务审批的结束申请",
                    "fingerprint", preview.fingerprint(), "items", preview.items(), "unverifiedQuantity", false));
            String json = mapper.writeValueAsString(snapshot);
            UUID id = UUID.randomUUID();
            int attempt = db.queryForObject("SELECT COALESCE(MAX(attempt),0)+1 FROM procurement_order_approval_cases WHERE order_type=? AND order_id=?",
                    Integer.class, preview.orderType(), preview.orderId());
            db.update("""
                    INSERT INTO procurement_order_approval_cases(id,order_type,order_id,attempt,bill_no_snapshot,
                        amount_snapshot,submission_snapshot,snapshot_hash,submitted_by_user_id,submitted_by_employee_id,
                        status,version,request_type)
                    VALUES(?,?,?,?,?,0,CAST(? AS jsonb),?,?,?,'PENDING',1,?)
                    """, id,preview.orderType(),preview.orderId(),attempt,preview.billNo(),json,HashUtil.sha256(json),
                    world.superAdminUserId(),world.employeeId(),mode);
            return new FinanceApproval(id,"PENDING",attempt,1,null,null,null,null,OffsetDateTime.now(),List.of());
        } catch (com.fasterxml.jackson.core.JsonProcessingException error) {
            throw new IllegalStateException(error);
        }
    }
}
