package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rbac.UserRoleRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class SubcontractReturnDueNoticeTest {

    @Test
    void schedulerSkipsUnissuedAndFullyReturnedEvenIfIqcIsPending() {
        LocalDate today = BusinessTime.today();
        LocalDate deadline = today.plusDays(SubcontractReturnDueScheduler.DUE_DAYS);
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        Map<String, Object> neverOutbound = row(
                UUID.randomUUID(), today, 0, "5", 0);
        Map<String, Object> fullyReturnedPendingIqc = row(
                UUID.randomUUID(), today, 1, "0", 0);
        fullyReturnedPendingIqc.put("pending_iqc_lines", 1L);
        when(jdbc.queryForList(anyString(), eq(deadline)))
                .thenReturn(List.of(neverOutbound, fullyReturnedPendingIqc));

        new SubcontractReturnDueScheduler(jdbc, outbox).scan();

        verifyNoInteractions(outbox);
    }

    @Test
    void schedulerUsesStableOrderAndBusinessDatePublishOnceKeyForBothFlows() {
        LocalDate today = BusinessTime.today();
        LocalDate deadline = today.plusDays(SubcontractReturnDueScheduler.DUE_DAYS);
        UUID newOrder = UUID.randomUUID();
        UUID legacyOrder = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        when(jdbc.queryForList(
                argThat(sql -> sql.contains("issue_item.supplier_ending")
                        && !sql.contains("procurement_inspection_items")),
                eq(deadline))).thenReturn(List.of(
                        row(newOrder, today.plusDays(2), 1, "2", 0),
                        row(legacyOrder, today.minusDays(1), 1, "0", 1)));

        new SubcontractReturnDueScheduler(jdbc, outbox).scan();

        verify(outbox).publishOnce(
                SubcontractReturnDueScheduler.EVENT_SUBCONTRACT_RETURN_DUE,
                "SUBCONTRACT_ORDER",
                newOrder,
                Map.of("businessDate", today.toString()),
                SubcontractReturnDueScheduler.EVENT_SUBCONTRACT_RETURN_DUE
                        + ':' + newOrder + ':' + today);
        verify(outbox).publishOnce(
                SubcontractReturnDueScheduler.EVENT_SUBCONTRACT_RETURN_DUE,
                "SUBCONTRACT_ORDER",
                legacyOrder,
                Map.of("businessDate", today.toString()),
                SubcontractReturnDueScheduler.EVENT_SUBCONTRACT_RETURN_DUE
                        + ':' + legacyOrder + ':' + today);
    }

    @Test
    void staleClosedHeaderDoesNotHideAuthoritativeNetUnreturnedQuantity() {
        LocalDate today = BusinessTime.today();
        LocalDate deadline = today.plusDays(SubcontractReturnDueScheduler.DUE_DAYS);
        UUID orderId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        Map<String, Object> staleHeader = row(orderId, today, 1, "1", 0);
        staleHeader.put("is_closed", true);
        staleHeader.put("fulfill", true);
        when(jdbc.queryForList(
                argThat(sql -> sql.contains("approved_outbound_lines")
                        && !sql.contains("order_header.is_closed")
                        && !sql.contains("order_header.fulfill")),
                eq(deadline))).thenReturn(List.of(staleHeader));

        new SubcontractReturnDueScheduler(jdbc, outbox).scan();

        verify(outbox).publishOnce(
                eq(SubcontractReturnDueScheduler.EVENT_SUBCONTRACT_RETURN_DUE),
                eq("SUBCONTRACT_ORDER"),
                eq(orderId),
                eq(Map.of("businessDate", today.toString())),
                eq(SubcontractReturnDueScheduler.EVENT_SUBCONTRACT_RETURN_DUE
                        + ':' + orderId + ':' + today));
    }

    @Test
    void materialReturnOrApprovedLossWithZeroSupplierEndingDoesNotWarn() {
        LocalDate today = BusinessTime.today();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        BusinessEventPublisher outbox = mock(BusinessEventPublisher.class);
        Map<String, Object> settledAtSupplier = row(
                UUID.randomUUID(), today.minusDays(2), 1, "0", 0);
        settledAtSupplier.put("material_returned_or_wasted", true);
        when(jdbc.queryForList(anyString(), eq(today.plusDays(3))))
                .thenReturn(List.of(settledAtSupplier));

        new SubcontractReturnDueScheduler(jdbc, outbox).scan();

        verifyNoInteractions(outbox);
    }

    @Test
    void deliveryRecheckSkipsAfterFullPhysicalReturnEvenWithPendingIqc() {
        LocalDate today = BusinessTime.today();
        UUID orderId = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        Map<String, Object> returned = row(orderId, today, 1, "0", 0);
        returned.put("pending_iqc_lines", 1L);
        when(jdbc.queryForList(
                contains("approved_outbound_lines"),
                eq(today.plusDays(3)),
                eq(orderId))).thenReturn(List.of(returned));
        ChainNoticeService service = service(
                notice,
                mock(UserAccountRepository.class),
                jdbc,
                mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_RETURN_DUE,
                orderId,
                new ObjectMapper().createObjectNode());

        verifyNoInteractions(notice);
        verify(jdbc, never()).queryForList(
                contains("preplan_supply_action_allocations allocation"),
                eq(orderId));
    }

    @Test
    void deliveryTargetsOnlyActiveOrderAndLinkedAnalysisMakersWithoutMoney() {
        LocalDate today = BusinessTime.today();
        UUID orderId = UUID.randomUUID();
        UUID orderMakerEmployee = UUID.randomUUID();
        UUID orderMakerUser = UUID.randomUUID();
        UUID analysisMakerEmployee = UUID.randomUUID();
        UUID analysisMakerUser = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        Map<String, Object> due = row(
                orderId, today.minusDays(2), 1, "3", 0);
        due.put("maker_id", orderMakerEmployee);
        when(jdbc.queryForList(
                contains("approved_outbound_lines"),
                eq(today.plusDays(3)),
                eq(orderId))).thenReturn(List.of(due));
        when(jdbc.queryForList(
                contains("preplan_supply_action_allocations allocation"),
                eq(orderId))).thenReturn(List.of(Map.of(
                        "maker_id", analysisMakerEmployee)));
        UserAccount orderMaker = user(orderMakerUser, "active");
        UserAccount analysisMaker = user(analysisMakerUser, "active");
        when(users.findByEmployeeId(orderMakerEmployee))
                .thenReturn(Optional.of(orderMaker));
        when(users.findByEmployeeId(analysisMakerEmployee))
                .thenReturn(Optional.of(analysisMaker));
        when(users.findById(orderMakerUser)).thenReturn(Optional.of(orderMaker));
        when(users.findById(analysisMakerUser)).thenReturn(Optional.of(analysisMaker));
        ChainNoticeService service = service(
                notice, users, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_RETURN_DUE,
                orderId,
                new ObjectMapper().createObjectNode());

        for (UUID recipient : List.of(orderMakerUser, analysisMakerUser)) {
            verify(notice).publishForUser(
                    eq(recipient),
                    eq("委外回厂已逾期：WO-DUE"),
                    argThat(content -> content.contains("尚未物理回厂")
                            && content.contains("不代表已回厂、IQC 已结案或订单完成")
                            && !content.contains("金额")),
                    eq(ChainNoticeService.TYPE_URGENT),
                    anyString(),
                    eq("/subcontract/orders/" + orderId),
                    eq(ChainNoticeService.EVENT_SUBCONTRACT_RETURN_DUE),
                    eq("important"));
        }
    }

    @Test
    void disabledOrderMakerIsNotNotified() {
        LocalDate today = BusinessTime.today();
        UUID orderId = UUID.randomUUID();
        UUID makerEmployee = UUID.randomUUID();
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        NoticeService notice = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        Map<String, Object> due = row(orderId, today, 1, "1", 0);
        due.put("maker_id", makerEmployee);
        when(jdbc.queryForList(
                contains("approved_outbound_lines"),
                eq(today.plusDays(3)),
                eq(orderId))).thenReturn(List.of(due));
        when(jdbc.queryForList(
                contains("preplan_supply_action_allocations allocation"),
                eq(orderId))).thenReturn(List.of());
        when(users.findByEmployeeId(makerEmployee))
                .thenReturn(Optional.of(user(UUID.randomUUID(), "disabled")));
        ChainNoticeService service = service(
                notice, users, jdbc, mock(BusinessEventPublisher.class));

        service.deliverOutboxEvent(
                ChainNoticeService.EVENT_SUBCONTRACT_RETURN_DUE,
                orderId,
                new ObjectMapper().createObjectNode());

        verifyNoInteractions(notice);
    }

    private static Map<String, Object> row(
            UUID orderId,
            LocalDate deliverDate,
            long approvedOutboundLines,
            String newUnreturnedBase,
            long legacyUnreturnedLines) {
        Map<String, Object> row = new LinkedHashMap<>();
        row.put("order_id", orderId);
        row.put("bill_no", "WO-DUE");
        row.put("deliver_date", deliverDate);
        row.put("maker_id", UUID.randomUUID());
        row.put("approved_outbound_lines", approvedOutboundLines);
        row.put("new_unreturned_base", new BigDecimal(newUnreturnedBase));
        row.put("legacy_unreturned_lines", legacyUnreturnedLines);
        return row;
    }

    private static ChainNoticeService service(
            NoticeService notice,
            UserAccountRepository users,
            JdbcTemplate jdbc,
            BusinessEventPublisher outbox) {
        return new ChainNoticeService(
                notice,
                users,
                mock(PermissionResolver.class),
                mock(UserRoleRepository.class),
                jdbc,
                outbox,
                mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class));
    }

    private static UserAccount user(UUID userId, String status) {
        UserAccount user = new UserAccount();
        user.setId(userId);
        user.setStatus(status);
        user.setDeleted(false);
        return user;
    }
}
