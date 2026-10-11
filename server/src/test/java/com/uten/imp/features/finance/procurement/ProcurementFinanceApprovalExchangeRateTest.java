package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.lang.reflect.Field;
import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * V835 财务汇率口径锁定（2026-10-10 用户口径）：approve 的 exchangeRate 选填、
 * >0、≤6 位小数（非法 4xx 且不触库）；未填时放行进入批量解析（缺省汇率在
 * approveOne 内逐单解析：沿用该单最近已批财务汇率→提交快照汇率→1，复核轮
 * 未填不得用 1 覆盖首轮财务决定值）；
 * 待审列表折合本币用 COALESCE(finance_total_local, amount_snapshot)；
 * 请求契约由 bean 校验兜底（控制器层 400）。落库与 SQL 全链路由
 * {@code ProcurementFinanceApprovalExchangeRatePostgresTest}（UTEN_RUN_DB_TESTS）覆盖。
 */
class ProcurementFinanceApprovalExchangeRateTest {

    private static final BigDecimal SEVEN_DECIMALS = new BigDecimal("1.2345678");

    @Test
    void illegalRatesFailAs4xxBeforeAnyDatabaseMutation() {
        Fixture fixture = fixture();
        List<BatchDecisionItem> items = List.of(
                new BatchDecisionItem(UUID.randomUUID(), 1L));

        for (BigDecimal bad : List.of(
                BigDecimal.ZERO,
                new BigDecimal("-6.85"),
                SEVEN_DECIMALS,
                new BigDecimal("0.0000001"),
                new BigDecimal("1000000000000"))) {
            ApiException error = assertThrows(ApiException.class,
                    () -> fixture.service().approveBatch(items, null, bad),
                    "非法汇率必须被拒绝: " + bad);
            assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode(),
                    "汇率校验失败按 4xx 返回: " + bad);
        }
        verifyNoInteractions(fixture.jdbc());
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void omittedRatePassesValidationAndLegacySignatureStillRoutes() {
        Fixture fixture = fixture();
        // resolveBatchItems 查不到 PENDING case 时抛 CONFLICT——证明 null/缺省
        // 通过了汇率校验并进入批量解析（缺省视为 1 的入口）。
        doReturn(List.of()).when(fixture.jdbc()).query(
                anyString(), any(RowMapper.class), any(Object[].class));
        List<BatchDecisionItem> items = List.of(
                new BatchDecisionItem(UUID.randomUUID(), 1L));

        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class,
                () -> fixture.service().approveBatch(items, null, null)).getCode());
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class,
                () -> fixture.service().approveBatch(items, null)).getCode(),
                "旧两参签名（V835 前调用方，含 FullChainEndToEndTest）等价于缺省汇率");
    }

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void taskListConvertsLocalAmountWithFinanceFirstSnapshotFallback() {
        Fixture fixture = fixture();
        when(fixture.jdbc().queryForObject(
                anyString(), eq(Long.class), any(Object[].class)))
                .thenReturn(0L);
        doReturn(List.of()).when(fixture.jdbc()).query(
                anyString(), any(RowMapper.class), any(Object[].class));

        fixture.service().tasks(1, 20, "PURCHASE", null);

        verify(fixture.jdbc()).query(
                contains("COALESCE(c.finance_total_local, c.amount_snapshot)"),
                any(RowMapper.class),
                any(Object[].class));
    }

    @Test
    void requestContractKeepsBeanValidationOnExchangeRate() throws Exception {
        Field rate = ProcurementApprovalContracts.BatchApprovalRequest.class
                .getDeclaredField("exchangeRate");
        assertNotNull(rate.getAnnotation(DecimalMin.class),
                "控制器层 400 依赖 @DecimalMin(>0)");
        assertNotNull(rate.getAnnotation(Digits.class),
                "控制器层 400 依赖 @Digits(≤6 位小数)");
        // 旧两参构造保留：既有调用方（FullChainEndToEndTest）不改也能编译。
        assertDoesNotThrow(() -> new ProcurementApprovalContracts.BatchApprovalRequest(
                List.of(new BatchDecisionItem(UUID.randomUUID(), 1L)), null));
        assertTrue(new ProcurementApprovalContracts.BatchApprovalRequest(
                List.of(new BatchDecisionItem(UUID.randomUUID(), 1L)), null, null)
                .exchangeRate() == null);
    }

    private static Fixture fixture() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        WorkflowReviewerEligibility reviewer =
                mock(WorkflowReviewerEligibility.class);
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        UUID userId = UUID.randomUUID();
        when(currentUser.requireId()).thenReturn(userId);
        when(currentUser.get()).thenReturn(Optional.empty());
        when(reviewer.findEligible(userId)).thenReturn(Optional.of(
                new EligibleFinanceReviewer(
                        userId, UUID.randomUUID(), "审核员")));
        ProcurementFinanceApprovalService service =
                new ProcurementFinanceApprovalService(
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
                        org.mockito.Mockito.mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class,
                                org.mockito.Mockito.RETURNS_DEEP_STUBS),
                        org.mockito.Mockito.mock(com.uten.imp.application.port.PartyOpenBalancePort.class));
        return new Fixture(service, jdbc);
    }

    private record Fixture(
            ProcurementFinanceApprovalService service,
            JdbcTemplate jdbc) {
    }
}
