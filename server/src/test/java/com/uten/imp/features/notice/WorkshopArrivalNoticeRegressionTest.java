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
        // 撤销不受闸门约束, 但水位仍同步成当前产能(此处为 0), 让之后的回涨能再通知。
        verify(f.jdbc).update(contains("arrival_notice_capacity"), eq(BigDecimal.ZERO), eq(f.segment), eq(BigDecimal.ZERO));
    }

    @Test void continuousWaitingWithoutProducibleCapacityStaysSilentUntilCapacityGrows() {
        // 2026-10-06 修订二(ADR-165): 开工就绪信号(start_material_ready)不再触发到货卡;
        // 可支撑产能(prepared_capacity)为 0 就静默——没有「可以生产 X 件」可说的到货不弹窗。
        Fixture f = new Fixture("WAITING", "CONTINUOUS", true);
        f.task.put("start_material_ready", true);
        f.validArrival();
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL, f.segment,
                f.arrivalPayload("本次合格入库 100 件"));
        verify(f.notices, never()).publishForUser(any(), any(), any(), any(), any(), any(), any(), any(), any());
        verify(f.notices, never()).resolveReviewNotices(any(), any(), eq("ARRIVAL_PROGRESS"));
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

    @Test void partialArrivalWithoutProducibleCapacityNoLongerPublishesTheArrivalCard() {
        // 修订二: 齐套路线缺口没被盖住 = 可支撑产能 0——静默, 不发行动卡。
        Fixture f=new Fixture("WAITING","FULL_KIT",false);
        f.task.put("auto_promote_when_ready",true);f.task.put("route_allows_auto_promote",true);
        f.shortage("V5一开铁架","83.3334");
        f.validArrival();
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次合格入库 100 件"));
        verify(f.notices,never()).publishForUser(any(),any(),any(),any(),any(),any(),any(),any(),any());
        verify(f.notices,never()).resolveReviewNotices(any(),any(),eq("ARRIVAL_PROGRESS"));
    }

    @Test void autoPromotableFullKitLeavesThePopupToTheReadyCard() {
        // 会自动提升的段由齐套/可开工行动卡负责弹窗，到货进展不发第二张。
        Fixture f=new Fixture("WAITING","FULL_KIT",false);
        f.task.put("auto_promote_when_ready",true);f.task.put("route_allows_auto_promote",true);
        f.validArrival();
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次合格入库 1000 件"));
        verify(f.notices,never()).publishForUser(any(),any(),any(),any(),any(),any(),any(),any(),any());
        verify(f.notices,never()).resolveReviewNotices(any(),any(),eq("ARRIVAL_PROGRESS"));
    }

    @Test void batchFullKitStillGetsTheArrivalCardBecauseBatchNeverAutoPromotes() {
        // 分批路线 fn_execution_route_allows_auto_promote 恒 FALSE，全齐感知只能靠到货卡补位;
        // 数字与分批领料核对页同一把尺子(workshopBatchCapacity)。
        Fixture f=new Fixture("WAITING","BATCH",false);
        f.task.put("auto_promote_when_ready",true);f.task.put("route_allows_auto_promote",false);
        doReturn(new BigDecimal("1000")).when(f.service).workshopBatchCapacity(f.segment);
        f.validArrival();
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次合格入库 1000 件"));
        assertThat(f.content()).contains("合格入库 1000 件","当前物料没有缺口","可支撑生产 1000 件");
    }

    @Test void arrivalCardFiresOnlyWhenProducibleCapacityGrows() {
        // 2026-10-06 修订二核心口径: 每种物料都有一些→首次「可以生产 20 件」;
        // 后续到货产能不涨(还是 20)→不弹; 再到货涨到 120(扣已领)→再弹。
        Fixture f=new Fixture("WAITING","BATCH",false);
        f.task.put("auto_promote_when_ready",false);
        f.validArrival();
        doReturn(new BigDecimal("20")).when(f.service).workshopBatchCapacity(f.segment);
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次合格入库 40 件"));
        assertThat(f.content()).contains("可支撑生产 20 件");
        // 第二次到货: 产能没涨(水位已是 20)——静默。
        f.task.put("arrival_notice_capacity",new BigDecimal("20"));
        doReturn(new BigDecimal("20")).when(f.service).workshopBatchCapacity(f.segment);
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次又合格入库 30 件"));
        verify(f.notices,times(1)).publishForUser(any(),any(),any(),any(),any(),any(),any(),any(),any());
        // 第三次到货: 产能涨到 120——再弹, 卡上说的是 120。
        f.task.put("arrival_notice_capacity",new BigDecimal("20"));
        doReturn(new BigDecimal("120")).when(f.service).workshopBatchCapacity(f.segment);
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次又合格入库 200 件"));
        var contents=ArgumentCaptor.forClass(String.class);
        verify(f.notices,times(2)).publishForUser(eq(f.user),anyString(),contents.capture(),eq("task"),anyString(),
                eq("/production/workshop-tasks"),eq(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED),
                anyString(),eq(f.segment));
        assertThat(contents.getAllValues().getLast()).contains("可支撑生产 120 件");
    }

    @Test void watermarkDecaysWhenCapacityDropsSoLaterGrowthNotifiesAgain() {
        // 领料后产能回落(20), 水位跟着落下来; 之后回涨到 50 就能再通知, 不会被旧水位 100 压住。
        Fixture f=new Fixture("WAITING","CONTINUOUS",true);
        f.task.put("prepared_capacity",new BigDecimal("100"));
        f.validArrival();
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次合格入库 100 件"));
        assertThat(f.content()).contains("可支撑生产 100 件");
        // 领走一部分: 产能回落到 20——静默, 水位同步成 20。
        f.task.put("arrival_notice_capacity",new BigDecimal("100"));
        f.task.put("prepared_capacity",new BigDecimal("20"));
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次又到货 10 件"));
        verify(f.notices,times(1)).publishForUser(any(),any(),any(),any(),any(),any(),any(),any(),any());
        verify(f.jdbc).update(contains("arrival_notice_capacity"),eq(new BigDecimal("20")),eq(f.segment),
                eq(new BigDecimal("20")));
        // 再到货回涨到 50——重新弹窗。
        f.task.put("arrival_notice_capacity",new BigDecimal("20"));
        f.task.put("prepared_capacity",new BigDecimal("50"));
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次又到货 40 件"));
        var contents=ArgumentCaptor.forClass(String.class);
        verify(f.notices,times(2)).publishForUser(eq(f.user),anyString(),contents.capture(),eq("task"),anyString(),
                eq("/production/workshop-tasks"),eq(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED),
                anyString(),eq(f.segment));
        assertThat(contents.getAllValues().getLast()).contains("可支撑生产 50 件");
    }

    @Test void fullKitCoveredNotifiesOnceAndExcessArrivalsStaySilent() {
        // 齐套路线全有或全无: 盖住全部缺口弹一次「已齐套」; 之后多余到货产能不涨, 不再弹。
        Fixture f=new Fixture("WAITING","FULL_KIT",false);
        f.task.put("auto_promote_when_ready",false);f.task.put("route_allows_auto_promote",true);
        f.validArrival();
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次合格入库 1000 件"));
        assertThat(f.content()).contains("物料已齐套，可提交领料");
        f.task.put("arrival_notice_capacity",new BigDecimal("100"));
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次又合格入库 50 件"));
        verify(f.notices,times(1)).publishForUser(any(),any(),any(),any(),any(),any(),any(),any(),any());
    }

    @Test void batchCapacityUnmeasurableStaysSilentAndKeepsTheWatermark() {
        // 尺子不可计量(如路线已改/前批固定料未领齐): 不发卡, 水位不动。
        Fixture f=new Fixture("WAITING","BATCH",false);
        f.validArrival();
        // workshopBatchCapacity 默认返回 null(batchSplits 缺位)。
        f.service.deliverOutboxEvent(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_MATERIAL_ARRIVAL,f.segment,
                f.arrivalPayload("本次合格入库 100 件"));
        verify(f.notices,never()).publishForUser(any(),any(),any(),any(),any(),any(),any(),any(),any());
        verify(f.jdbc,never()).update(contains("arrival_notice_capacity"),any(),any(),any());
    }

    private static final class Fixture {
        final UUID segment=UUID.randomUUID(), workshop=UUID.randomUUID(), person=UUID.randomUUID(), user=UUID.randomUUID();
        final JdbcTemplate jdbc=mock(JdbcTemplate.class);
        final NoticeService notices=mock(NoticeService.class);
        final BusinessEventPublisher outbox=mock(BusinessEventPublisher.class);
        final Map<String,Object> task=new HashMap<>();
        UUID sourceId;
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
            task.put("planned_qty",new BigDecimal("100"));
            task.put("product_unit_name","件");
        }
        void shortage(String name,String qty) {
            Map<String,Object> row=new HashMap<>();
            row.put("demand_id",UUID.randomUUID());
            row.put("goods_code","V5-"+name.hashCode()%1000);
            row.put("goods_name",name);row.put("color_name","");
            row.put("stock_shortage_qty",new BigDecimal(qty));
            row.put("unit_name","个");row.put("in_house_child",false);
            when(jdbc.queryForList(contains("FROM v_production_execution_segment_materials"),eq(segment)))
                    .thenReturn(List.of(row));
        }
        com.fasterxml.jackson.databind.node.ObjectNode arrivalPayload(String summary) {
            var payload=new ObjectMapper().createObjectNode().put("arrival",summary)
                    .put("evidenceType","FINISHED_IN");
            payload.putArray("evidenceIds").add(sourceId.toString());
            return payload;
        }
        void validArrival() {
            sourceId=UUID.randomUUID();
            when(jdbc.queryForList(contains("SELECT document.id FROM stock_documents"),eq(UUID.class),eq(sourceId.toString())))
                    .thenReturn(List.of(sourceId));
            doReturn(true).when(service).workshopArrivalCanBenefit(segment,"FINISHED_IN",List.of(sourceId));
        }
        String content() {
            var value=ArgumentCaptor.forClass(String.class);
            verify(notices).publishForUser(eq(user),anyString(),value.capture(),eq("task"),anyString(),
                    eq("/production/workshop-tasks"),eq(ChainNoticeService.EVENT_PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED),anyString(),eq(segment));
            return value.getValue();
        }
    }
}
