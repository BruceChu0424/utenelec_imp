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
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WorkshopArrivalNoticeRegressionTest {
    @Test void firstPartialIssueNotifiesStartEvenWhenTheWholePlanIsNotIssued() {
        Fixture f = new Fixture("READY", "CONTINUOUS", true);
        f.task.put("issued", false); f.task.put("start_material_ready", true);
        f.task.put("draw_requested", true);
        UUID draw = UUID.randomUUID();
        when(f.jdbc.queryForList(contains("FROM stock_documents stock"), eq(draw)))
                .thenReturn(List.of(Map.of("bill_no", "DRAW-100")));
        when(f.jdbc.queryForList(contains("SELECT DISTINCT demand.execution_segment_id"), eq(UUID.class), eq(draw)))
                .thenReturn(List.of(f.segment));
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_DRAW_ISSUED, draw,
                new ObjectMapper().createObjectNode());
        assertThat(f.content()).contains("共同支持部分产量，可以开工").doesNotContain("物料已领齐");
    }

    @Test void completeKitAssignmentStillRequiresExplicitRouteConfirmation() {
        Fixture f = new Fixture("WAITING", "", false);
        f.task.put("issued", true);
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_SEGMENT_WORKSHOP_ASSIGNED, f.segment,
                new ObjectMapper().createObjectNode());
        assertThat(f.content()).contains("先确认齐套或持续生产路线").doesNotContain("物料已领齐，可以开工");
    }

    @Test void reversedArrivalDeliveredLateDropsTheOldQuantityAndRebuildsCurrentState() {
        Fixture f = new Fixture("IN_PROGRESS", "CONTINUOUS", true);
        UUID source = UUID.randomUUID();
        var payload = new ObjectMapper().createObjectNode().put("arrival", "本次已到货 900 件")
                .put("evidenceType", "FINISHED_IN");
        payload.putArray("evidenceIds").add(source.toString());
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL, f.segment, payload);
        assertThat(f.content()).contains("原到货数量不再作为当前可用量依据").doesNotContain("已到货 900");
        verify(f.notices).resolveReviewNotices("PRODUCTION_EXECUTION_SEGMENT", f.segment, "ARRIVAL_PROGRESS");
    }

    @Test void validEvidenceKeepsArrivalQuantityButDoesNotInventPartialReadiness() {
        Fixture f = new Fixture("WAITING", "CONTINUOUS", true);
        f.task.put("start_material_ready", true); // Material eligibility cannot bypass execution status.
        UUID source = UUID.randomUUID();
        when(f.jdbc.queryForList(contains("SELECT document.id FROM stock_documents"), eq(UUID.class), eq(source.toString())))
                .thenReturn(List.of(source));
        doReturn(true).when(f.service).workshopArrivalCanBenefit(f.segment,"FINISHED_IN",List.of(source));
        var payload = new ObjectMapper().createObjectNode().put("arrival", "本次合格入库 100 件")
                .put("evidenceType", "FINISHED_IN");
        payload.putArray("evidenceIds").add(source.toString());
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL, f.segment, payload);
        assertThat(f.content()).contains("合格入库 100 件", "仍需等待各项必需物料共同支持部分产量").doesNotContain("可以开工");
    }

    @Test void eventCarriesSourceIdentityAndDeduplicatesEvidence() {
        Fixture f = new Fixture("WAITING", "FULL_KIT", false);
        UUID source=UUID.randomUUID();
        f.service.notifyWorkshopMaterialArrival(f.segment, "one", "arrival", "FINISHED_IN", List.of(source,source));
        verify(f.outbox).publishOnce(eq(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL),
                eq("PRODUCTION_EXECUTION_SEGMENT"), eq(f.segment),
                eq(Map.of("arrival","arrival","evidenceType","FINISHED_IN","evidenceIds",List.of(source.toString()))), anyString());
        verifyNoInteractions(f.notices);
    }

    @Test void inactivePlanResolvesOldCardsWithoutPublishingNewArrival() {
        Fixture f = new Fixture("READY", "CONTINUOUS", true);
        when(f.jdbc.queryForList(contains("FROM v_production_execution_workbench_segments task"),eq(f.segment)))
                .thenReturn(List.of());
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                new ObjectMapper().createObjectNode());
        verify(f.notices).resolveReviewNotices("PRODUCTION_EXECUTION_SEGMENT",f.segment,"PLAN_INACTIVE");
        verifyNoMoreInteractions(f.notices);
    }

    @Test void directMaterialThatStartWillIssueAtomicallyCanGenerateTheStartNotice() {
        Fixture f=new Fixture("READY","CONTINUOUS",true);
        f.task.put("start_material_ready",true); // Physical ISSUE is deliberately not yet present.
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_SEGMENT_WORKSHOP_ASSIGNED,f.segment,
                new ObjectMapper().createObjectNode());
        assertThat(f.content()).contains("共同支持部分产量，可以开工");
    }

    private static final class Fixture {
        final UUID segment=UUID.randomUUID(), workshop=UUID.randomUUID(), person=UUID.randomUUID(), user=UUID.randomUUID();
        final JdbcTemplate jdbc=mock(JdbcTemplate.class);
        final NoticeService notices=mock(NoticeService.class);
        final BusinessEventPublisher outbox=mock(BusinessEventPublisher.class);
        final Map<String,Object> task=new HashMap<>();
        final ChainNoticeService service;
        Fixture(String status,String route,boolean continuous) {
            UserAccountRepository users=mock(UserAccountRepository.class);
            UserAccount account=mock(UserAccount.class);
            when(account.getStatus()).thenReturn("active");
            when(users.findById(user)).thenReturn(Optional.of(account));
            service=spy(new ChainNoticeService(notices,users,mock(PermissionResolver.class),jdbc,outbox,mock(RdTaskService.class),mock(FinanceReviewerEligibilityPort.class),
                    mock(SalesOrderFinanceConfirmerEligibility.class)));
            doReturn(List.of(user)).when(service).workshopRecipientUserIds(workshop,person);
            when(jdbc.queryForList(contains("FOR UPDATE"),eq(UUID.class),eq(segment))).thenReturn(List.of(segment));
            when(jdbc.queryForList(contains("FROM v_production_execution_workbench_segments task"),eq(segment))).thenReturn(List.of(task));
            task.put("segment_status",status);task.put("start_route",route);task.put("continuous_supply",continuous);
            task.put("segment_code","GD-001");task.put("workshop_department_id",workshop);
            task.put("responsible_employee_id",person);task.put("start_material_ready",false);
            task.put("prepared_capacity",BigDecimal.ZERO);
        }
        String content() {
            var value=ArgumentCaptor.forClass(String.class);
            verify(notices).publishForUser(eq(user),anyString(),value.capture(),eq("task"),anyString(),
                    eq("/production/workshop-tasks"),eq(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED),anyString(),eq(segment));
            return value.getValue();
        }
    }
}
