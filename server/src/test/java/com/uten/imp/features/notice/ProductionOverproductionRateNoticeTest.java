package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.math.BigDecimal;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.assertj.core.api.Assertions.assertThat;

class ProductionOverproductionRateNoticeTest {
    private final NoticeService notices=mock(NoticeService.class);
    private final JdbcTemplate jdbc=mock(JdbcTemplate.class);
    private final UserAccountRepository accounts=mock(UserAccountRepository.class);
    private final PermissionResolver permissions=mock(PermissionResolver.class);
    private final ChainNoticeService service=new ChainNoticeService(notices,accounts,permissions,jdbc,
            mock(BusinessEventPublisher.class),mock(RdTaskService.class),mock(FinanceReviewerEligibilityPort.class),
            mock(SalesOrderFinanceConfirmerEligibility.class));
    private final UUID request=UUID.randomUUID(),submitter=UUID.randomUUID();

    @Test void planningPoolRequiresBothNoticeAndApprovalPermissionAndHasTheReviewRoute(){
        UUID planner=UUID.randomUUID(),viewer=UUID.randomUUID();
        row("PENDING");
        account(planner,Set.of("notice:read","production_plan:approve"));
        account(viewer,Set.of("notice:read"));
        when(jdbc.queryForList(contains("candidate_employee"),eq(UUID.class),eq("SUB_PLAN")))
                .thenReturn(List.of(planner,viewer));
        service.deliverOutboxEvent("PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED",request,new ObjectMapper().createObjectNode());
        verify(notices).publishForUser(eq(planner),contains("待审批"),argThat(content->content.contains("10%")&&content.contains("20%")),
                eq("approval"),eq("系统"),eq("/production/overproduction-rate-requests/"+request),
                eq("PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED"),eq("normal"),eq(request));
        verifyNoMoreInteractions(notices);
        assertThat(ReviewNoticeCatalog.of("PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED")).hasValueSatisfying(entry->
                assertThat(entry.aggregateKind()).isEqualTo("PRODUCTION_OVERPRODUCTION_RATE_REQUEST"));
    }

    @Test void completedRequestCannotGenerateALatePendingNotice(){
        row("APPROVED");
        service.deliverOutboxEvent("PRODUCTION_OVERPRODUCTION_RATE_SUBMITTED",request,new ObjectMapper().createObjectNode());
        verifyNoInteractions(notices);
    }

    @Test void decisionResolvesEveryPlanningReminderAndNotifiesTheRequester(){
        row("RETURNED");account(submitter,Set.of("notice:read","production_execution:view"));
        service.deliverOutboxEvent("PRODUCTION_OVERPRODUCTION_RATE_RETURNED",request,new ObjectMapper().createObjectNode());
        verify(notices).resolveReviewNotices("PRODUCTION_OVERPRODUCTION_RATE_REQUEST",request,"RETURNED");
        verify(notices).publishForUser(eq(submitter),contains("已退回"),contains("原有效比例未改变"),
                eq("workflow"),eq("系统"),eq("/production/overproduction-rate-requests/"+request),
                eq("PRODUCTION_OVERPRODUCTION_RATE_RETURNED"),eq("normal"),eq(request));
    }

    private void row(String status){
        Map<String,Object> row=new LinkedHashMap<>();
        row.put("status",status);row.put("submitted_by",submitter);row.put("before_rate",new BigDecimal(".10"));
        row.put("requested_rate",new BigDecimal(".20"));row.put("segment_code","ZX-TEST");row.put("reason","补充实际生产依据");
        when(jdbc.queryForList(contains("FROM production_overproduction_rate_requests"),eq(request))).thenReturn(List.of(row));
    }
    private void account(UUID id,Set<String> grants){UserAccount account=mock(UserAccount.class);
        when(account.isDeleted()).thenReturn(false);when(account.getStatus()).thenReturn("active");
        when(accounts.findById(id)).thenReturn(Optional.of(account));when(permissions.permsOf(account)).thenReturn(grants);}
}
