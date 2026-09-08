package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.ApprovalReview;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 审核详情投影的口径锁定：未知 case fail-closed；allowedActions 仅对
 * PENDING case 按当前审核员实时资格返回，历史 case 只读无动作。
 */
class ProcurementFinanceApprovalReviewTest {

    private static final UUID USER_ID = UUID.randomUUID();

    @Test
    void unknownCaseFailsClosedAsNotFound() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID caseId = UUID.randomUUID();
        when(jdbc.query(anyString(), any(RowMapper.class), eq(caseId)))
                .thenReturn(List.of());
        ProcurementFinanceApprovalService service = service(jdbc, false);

        ApiException missing = assertThrows(
                ApiException.class,
                () -> service.review(caseId));
        assertEquals(ErrorCode.NOT_FOUND, missing.getCode());
    }

    @Test
    void pendingCaseCarriesRealtimeReviewerActions() {
        UUID caseId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        JdbcTemplate jdbc = headerRow(caseId, orderId, "PENDING");
        ProcurementFinanceApprovalService service = service(jdbc, true);

        ApprovalReview review = service.review(caseId);

        assertEquals(List.of("APPROVE", "REJECT"), review.allowedActions());
        assertEquals("PURCHASE", review.orderType());
        assertEquals(2, review.attempt());
        assertEquals(3L, review.version());
        assertEquals("供应商甲", review.supplierName());
        assertEquals(0, new BigDecimal("12500.50").compareTo(
                review.supplierApBalance()));
    }

    @Test
    void decidedCaseIsReadOnlyWithoutActions() {
        UUID caseId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        JdbcTemplate jdbc = headerRow(caseId, orderId, "APPROVED");
        ProcurementFinanceApprovalService service = service(jdbc, true);

        ApprovalReview review = service.review(caseId);

        assertTrue(review.allowedActions().isEmpty(),
                "已办结 case 不得再向任何账号返回审批动作");
        assertEquals("APPROVED", review.status());
    }

    @Test
    void pendingCaseWithoutReviewerEligibilityExposesNoActions() {
        UUID caseId = UUID.randomUUID();
        UUID orderId = UUID.randomUUID();
        JdbcTemplate jdbc = headerRow(caseId, orderId, "PENDING");
        ProcurementFinanceApprovalService service = service(jdbc, false);

        ApprovalReview review = service.review(caseId);

        assertTrue(review.allowedActions().isEmpty(),
                "无实时审核资格的账号只能查看，不能拿到动作");
    }

    private static JdbcTemplate headerRow(
            UUID caseId, UUID orderId, String status) {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        Object[] row = new Object[24];
        row[0] = caseId;
        row[1] = "PURCHASE";
        row[2] = orderId;
        row[3] = "CG20260901001";
        row[4] = status;
        row[5] = Integer.valueOf(2);
        row[6] = Long.valueOf(3);
        row[7] = OffsetDateTime.now();
        row[8] = "采购员甲";
        row[9] = LocalDate.now();
        row[10] = LocalDate.now().plusDays(7);
        row[11] = "加急";
        row[12] = new BigDecimal("10000");
        row[13] = new BigDecimal("11300");
        row[14] = new BigDecimal("1.13");
        row[15] = new BigDecimal("13");
        row[16] = "供应商甲";
        row[17] = "S-001";
        row[18] = null;
        row[19] = "人民币";
        row[20] = "月结30天";
        row[21] = "采购员甲";
        row[22] = "制单员乙";
        row[23] = new BigDecimal("12500.50");
        when(jdbc.query(anyString(), any(RowMapper.class), eq(caseId)))
                .thenReturn(java.util.Collections.singletonList(row));
        // V486 修改清单查询独立返回空（普通 case 无改量事实账行）。
        when(jdbc.query(
                org.mockito.ArgumentMatchers.argThat(
                        (String sql) -> sql != null
                                && sql.contains("procurement_order_qty_change_logs")),
                any(RowMapper.class), eq(caseId)))
                .thenReturn(java.util.List.of());
        return jdbc;
    }

    private static ProcurementFinanceApprovalService service(
            JdbcTemplate jdbc, boolean eligible) {
        WorkflowReviewerEligibility reviewer =
                mock(WorkflowReviewerEligibility.class);
        when(reviewer.findEligible(USER_ID)).thenReturn(eligible
                ? Optional.of(new EligibleFinanceReviewer(
                        USER_ID, UUID.randomUUID(), "财务审核员"))
                : Optional.empty());
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        AuthUser actor = mock(AuthUser.class);
        when(actor.getId()).thenReturn(USER_ID);
        when(actor.getPermissions()).thenReturn(Set.of(
                WorkflowReviewerEligibility.APPROVE_PERMISSION,
                WorkflowReviewerEligibility.REJECT_PERMISSION));
        when(currentUser.get()).thenReturn(Optional.of(actor));
        return new ProcurementFinanceApprovalService(
                List.of(),
                jdbc,
                mock(ObjectMapper.class),
                mock(BusinessEventPublisher.class),
                reviewer,
                mock(ProcurementApprovalProjectionQuery.class),
                currentUser,
                mock(TxSessionVars.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                        org.mockito.Mockito.mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                        org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, org.mockito.Mockito.RETURNS_DEEP_STUBS));
    }
}
