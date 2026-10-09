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
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProductionOverLimitNoticeTest {
    private final NoticeService notices=mock(NoticeService.class);
    private final JdbcTemplate jdbc=mock(JdbcTemplate.class);
    private final UserAccountRepository accounts=mock(UserAccountRepository.class);
    private final PermissionResolver permissions=mock(PermissionResolver.class);
    private final ChainNoticeService service=new ChainNoticeService(notices,accounts,permissions,jdbc,
            mock(BusinessEventPublisher.class),mock(RdTaskService.class),mock(FinanceReviewerEligibilityPort.class),
            mock(SalesOrderFinanceConfirmerEligibility.class));
    private final UUID request=UUID.randomUUID(),submitter=UUID.randomUUID();

    @Test void onlyTheEligiblePlanningAudienceReceivesThePendingAction(){
        UUID planner=UUID.randomUUID(),viewer=UUID.randomUUID();row("PENDING",1);
        account(planner,Set.of("notice:read","production_plan:approve","production_plan:view:all"));
        account(viewer,Set.of("notice:read"));
        when(jdbc.queryForList(contains("candidate_employee"),eq(UUID.class),eq("SUB_PLAN"))).thenReturn(List.of(planner,viewer));
        service.deliverOutboxEvent("PRODUCTION_OVER_LIMIT_PENDING",request,new ObjectMapper().createObjectNode().put("version",1));
        verify(notices).publishForUser(eq(planner),contains("超限产出待处理"),argThat(text->text.contains("100")&&text.contains("正常办理")),
            eq("approval"),eq("系统"),eq("/production/over-limit-dispositions/"+request),eq("PRODUCTION_OVER_LIMIT_PENDING"),eq("normal"),eq(request));
        verifyNoMoreInteractions(notices);
        assertThat(ReviewNoticeCatalog.of("PRODUCTION_OVER_LIMIT_PENDING")).hasValueSatisfying(entry->
            assertThat(entry.aggregateKind()).isEqualTo("PRODUCTION_OVER_LIMIT_DISPOSITION"));
    }
    @Test void latePendingEventsCannotReopenAnAcceptedTask(){
        row("ACCEPTED",2);
        service.deliverOutboxEvent("PRODUCTION_OVER_LIMIT_PENDING",request,new ObjectMapper().createObjectNode().put("version",1));
        verifyNoInteractions(notices);
    }
    @Test void acceptanceResolvesPlanningCardsButDoesNotClaimGoodsAreAlreadyInStock(){
        row("ACCEPTED",2);account(submitter,Set.of("notice:read","production_execution:view"));
        service.deliverOutboxEvent("PRODUCTION_OVER_LIMIT_DECIDED",request,new ObjectMapper().createObjectNode().put("version",2));
        verify(notices).resolveReviewNotices("PRODUCTION_OVER_LIMIT_DISPOSITION",request,"ACCEPTED");
        verify(notices).publishForUser(eq(submitter),contains("已同意接收"),contains("仍须品质合格并由仓库实际点收"),
            eq("workflow"),eq("系统"),eq("/production/over-limit-dispositions/"+request),eq("PRODUCTION_OVER_LIMIT_DECIDED"),eq("normal"),eq(request));
    }
    @Test void holdingOutputKeepsItsPlanningTaskOpenAndWithdrawalClosesIt(){
        row("HELD",2);account(submitter,Set.of("notice:read","production_execution:view"));
        service.deliverOutboxEvent("PRODUCTION_OVER_LIMIT_DECIDED",request,new ObjectMapper().createObjectNode().put("version",2));
        verify(notices,never()).resolveReviewNotices(anyString(),any(),anyString());
        verify(notices).publishForUser(eq(submitter),contains("继续待处理"),contains("实物和实际产量保留"),
            eq("workflow"),eq("系统"),anyString(),eq("PRODUCTION_OVER_LIMIT_DECIDED"),eq("normal"),eq(request));
        row("WITHDRAWN",3);
        service.deliverOutboxEvent("PRODUCTION_OVER_LIMIT_WITHDRAWN",request,new ObjectMapper().createObjectNode().put("version",3));
        verify(notices).resolveReviewNotices("PRODUCTION_OVER_LIMIT_DISPOSITION",request,"WITHDRAWN");
    }
    private void row(String status,long version){
        Map<String,Object> row=new LinkedHashMap<>();
        row.put("status",status);row.put("row_version",version);row.put("created_by",submitter);row.put("qty",new BigDecimal("100"));
        row.put("segment_code","ZX-TEST");row.put("maker_id",UUID.randomUUID());row.put("reason","尾批已完成");row.put("decision_reason","已核对去向");
        when(jdbc.queryForList(contains("FROM production_over_limit_dispositions"),eq(request))).thenReturn(List.of(row));
    }
    private void account(UUID id,Set<String> grants){
        UserAccount account=mock(UserAccount.class);when(account.isDeleted()).thenReturn(false);when(account.getStatus()).thenReturn("active");
        when(accounts.findById(id)).thenReturn(Optional.of(account));when(permissions.grantedPermsOf(account)).thenReturn(grants);
    }
}
