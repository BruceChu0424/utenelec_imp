package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.IssueWorkshopPlansRequest;
import com.uten.imp.features.rd_task.RdTaskService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Delivery SQL uses the complete migrated schema and actual route/request/ISSUE facts. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.inventory.value-work-initial-delay-ms=3600000",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class WorkshopNoticeDeliveryEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate jdbc;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired StockDocService stocks;

    private static final Set<String> ACTION = Set.of(
            "notice:read", "production_execution:view", "production_execution:start");
    private static final String TASK_EVENT = "PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED";
    private final ObjectMapper json = new ObjectMapper();

    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void delayedReadyEventCannotRecreateWorkshopCardAfterRequestWasSubmitted() {
        Scenario scenario = prepare(false);
        NoticeService notices = mock(NoticeService.class);
        UserAccountRepository users = mock(UserAccountRepository.class);
        assertThat(startReady(scenario.segment())).isFalse();
        scenario.draws().forEach(draw -> assertThat(jdbc.queryForObject(
                "SELECT fn_production_draw_fully_requested(?)", Boolean.class, draw)).isTrue());

        chain(notices, users, mock(PermissionResolver.class)).deliverOutboxEvent(
                "PRODUCTION_SEGMENT_READY", scenario.segment(), json.createObjectNode());

        verify(notices).resolveReviewNotices("PRODUCTION_EXECUTION_SEGMENT", scenario.segment(), "STATE_CHANGED");
        verifyNoMoreInteractions(notices);
        verifyNoInteractions(users);
    }

    @Test void issuedTaskMessageSummarizesEveryActualDrawOnceAndOnlyOffersStart() {
        Scenario scenario = prepare(true);
        UserAccountRepository users = mock(UserAccountRepository.class);
        PermissionResolver permissions = mock(PermissionResolver.class);
        for (UUID user : scenario.receivers()) {
            UserAccount account = mock(UserAccount.class);
            when(account.getStatus()).thenReturn("active");
            when(users.findById(user)).thenReturn(Optional.of(account));
            when(permissions.permsOf(account)).thenReturn(ACTION);
        }
        NoticeService notices = mock(NoticeService.class);
        assertThat(startReady(scenario.segment())).isTrue();
        assertThat(jdbc.queryForObject("SELECT status FROM production_execution_segments WHERE id=?", String.class,
                scenario.segment())).isEqualTo("READY");
        assertThat(jdbc.queryForObject("SELECT start_route FROM production_execution_segments WHERE id=?", String.class,
                scenario.segment())).isEqualTo("FULL_KIT");
        assertThat(jdbc.queryForObject("SELECT continuous_supply FROM production_execution_segments WHERE id=?", Boolean.class,
                scenario.segment())).isTrue(); // Existing incremental preparation is not the production route.
        chain(notices, users, permissions).deliverOutboxEvent("PRODUCTION_SEGMENT_WORKSHOP_ASSIGNED",
                scenario.segment(), json.createObjectNode());
        var content = ArgumentCaptor.forClass(String.class);
        var receivers = ArgumentCaptor.forClass(UUID.class);
        verify(notices, times(4)).publishForUser(receivers.capture(), startsWith("物料已领齐·可以开工"),
                content.capture(), eq("task"), anyString(), eq("/production/workshop-tasks"),
                eq(TASK_EVENT), eq("important"), eq(scenario.segment()));
        assertThat(receivers.getAllValues()).containsExactlyInAnyOrderElementsOf(scenario.receivers());
        for (String message : content.getAllValues()) {
            assertThat(message).contains("物料已领齐，可以开工").doesNotContain("可直接报工");
            for (String summary : scenario.summaries()) {
                assertThat(message).contains(summary);
                assertThat(message.indexOf(summary)).isEqualTo(message.lastIndexOf(summary));
            }
            scenario.otherDraws().forEach(number -> assertThat(message).doesNotContain(number));
        }
    }

    private Scenario prepare(boolean issue) {
        String tag = "notice-real-" + UUID.randomUUID().toString().substring(0, 8);
        var fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        var world = fixture.seedWorld(tag);
        fixture.loginAs(world.superAdminUserId());
        UUID main = UUID.randomUUID(), second = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES (?,?,?,'使用',TRUE)",
                main, "MAIN-" + tag, "主仓甲");
        jdbc.update("UPDATE warehouses SET parent_id=?,name='子仓一' WHERE id=?", main, world.warehouseId());
        jdbc.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES (?,?,?,'子仓二','使用',TRUE)",
                second, main, "SECOND-" + tag);
        var secondWorld = new FullChainEndToEndTest.World(world.departmentId(), world.employeeId(), world.superAdminUserId(),
                world.goodsA(), world.goodsB(), world.goodsC(), world.goodsD(), world.goodsE(), world.clientId(), world.supplierId(),
                second, world.unitId(), world.currencyId(), world.colorId(), world.unitLegacy());
        ReflectionTestUtils.invokeMethod(fixture, "putDirectTargetStock", world, world.goodsB(), "22");
        ReflectionTestUtils.invokeMethod(fixture, "putDirectTargetStock", secondWorld, world.goodsE(), "11");
        UUID plan = readyPlan(fixture, world, "10", tag);
        UUID segment = jdbc.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",
                UUID.class, plan);
        UUID workshop = jdbc.queryForObject("SELECT workshop_department_id FROM production_execution_segments WHERE id=?",
                UUID.class, segment);
        List<UUID> receivers = new ArrayList<>();
        for (int index = 0; index < 4; index++) {
            UUID user = ReflectionTestUtils.invokeMethod(fixture, "createUserWithPerms", world,
                    tag + "-recipient-" + index, (Object) ACTION.toArray(String[]::new));
            assertNotNull(user);
            jdbc.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)", workshop, user);
            receivers.add(user);
        }
        fixture.loginAs(world.superAdminUserId());
        UUID otherPlan = readyPlan(fixture, world, "1", tag + "-other");
        List<UUID> draws = draws(plan);
        assertThat(draws).hasSize(2);
        fixture.requestWorkshopDraws(tag, draws);
        if (issue) {
            for (UUID draw : draws) {
                StockDocIssueRequest request = ReflectionTestUtils.invokeMethod(fixture, "drawIssueRequest",
                        draw, tag + "-issue-" + draw, null, BigDecimal.ZERO);
                stocks.approveAndIssue(draw, request);
            }
        }
        List<String> summaries = jdbc.queryForList("""
                SELECT document.bill_no||'（'||parent.name||' - '||warehouse.name||'）'
                FROM stock_documents document JOIN warehouses warehouse ON warehouse.id=document.warehouse_id
                JOIN warehouses parent ON parent.id=warehouse.parent_id
                WHERE document.id=ANY(string_to_array(?,',')::uuid[]) ORDER BY document.id
                """, String.class, String.join(",", draws.stream().map(UUID::toString).toList()));
        List<String> others = draws(otherPlan).stream().map(draw -> jdbc.queryForObject(
                "SELECT bill_no FROM stock_documents WHERE id=?", String.class, draw)).toList();
        return new Scenario(segment, List.copyOf(receivers), draws, summaries, others);
    }

    private UUID readyPlan(FullChainEndToEndTest fixture, FullChainEndToEndTest.World world, String qty, String key) {
        BigDecimal quantity = new BigDecimal(qty);
        var view = analyses.preview(new PreviewRequest(null, null, null, world.warehouseId(), key + "-preview",
                List.of(new PreviewItem("OTHER", null, world.goodsA(), null, world.unitId(), key,
                        "车间通知真实物料链", BusinessTime.today(), quantity))));
        ReflectionTestUtils.invokeMethod(fixture, "confirmRootMakeRoute", view.analysisId(), view);
        view = analyses.detail(view.analysisId());
        UUID plan = commands.issueWorkshopPlans(view.analysisId(), new IssueWorkshopPlansRequest(
                view.version(), view.fingerprint(), key + "-issue", world.warehouseId(), BusinessTime.today(), null, true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(view.products().getFirst().analysisLineId(), quantity))))
                .plans().getFirst().planId();
        fixture.confirmFullKitRoutes(plan);
        assertThat(jdbc.queryForObject("SELECT material_analysis_id FROM production_plans WHERE id=?", UUID.class, plan))
                .isEqualTo(view.analysisId());
        return plan;
    }

    private List<UUID> draws(UUID plan) {
        return jdbc.queryForList("SELECT draw_id FROM plan_draw_links WHERE plan_id=? AND NOT is_deleted ORDER BY draw_id",
                UUID.class, plan);
    }
    private boolean startReady(UUID segment) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT fn_execution_start_material_ready(?)", Boolean.class, segment));
    }
    private ChainNoticeService chain(NoticeService notices, UserAccountRepository users, PermissionResolver permissions) {
        return new ChainNoticeService(notices, users, permissions, jdbc,
                mock(BusinessEventPublisher.class), mock(RdTaskService.class), mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class));
    }
    private record Scenario(UUID segment, List<UUID> receivers, List<UUID> draws, List<String> summaries, List<String> otherDraws) {}
}
