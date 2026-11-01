package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.notice.SalesPlanningNoticeCatchUpService;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import com.uten.imp.features.notice.outbox.BusinessOutboxScheduler;
import com.uten.imp.features.notice.outbox.OutboxDeliveryException;
import com.uten.imp.features.sales.SalesManagerReviewService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.support.SalesManagerReviewFixtures;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual manager/finance generations, outbox transactions and unchanged recipient history. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.bootstrap.admin-login=planning-generation-fixture"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
class SalesPlanningNoticeGenerationPostgresTest {
    private static final PostgreSQLContainer DATABASE=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("planning_generation").withUsername("fixture_admin").withPassword("uten");
    // Runtime-only, isolated fixture secrets are never committed or copied from production.
    private static final String JWT=UUID.randomUUID().toString(),PGP=UUID.randomUUID().toString(),HMAC=UUID.randomUUID().toString();
    private static final String BOOTSTRAP_PASSWORD="Fixture-"+UUID.randomUUID()+"!";
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        DATABASE.start();
        FixtureDatabaseProperties.bindSameRole(registry,DATABASE::getJdbcUrl,DATABASE::getUsername,DATABASE::getPassword);
        registry.add("uten.jwt.secret",()->JWT);
        registry.add("uten.crypto.pgp-master-key",()->PGP);
        registry.add("uten.crypto.hmac-key",()->HMAC);
        registry.add("uten.bootstrap.admin-password",()->BOOTSTRAP_PASSWORD);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate jdbc;
    @Autowired PlatformTransactionManager transactionManager;
    @Autowired SalesOrderService sales;
    @Autowired SalesOrderFinanceConfirmService finance;
    @Autowired SalesManagerReviewService managers;
    @Autowired TaskClaimService claims;
    @Autowired ChainNoticeService chain;
    @Autowired SalesPlanningNoticeCatchUpService catchUp;
    @Autowired BusinessOutboxProcessor processor;
    @MockitoSpyBean NoticeService notices;
    @MockitoBean BusinessOutboxScheduler scheduler;
    private final ObjectMapper json=new ObjectMapper();
    private final List<UUID> recipients=new ArrayList<>();
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private TransactionTemplate transactions;
    private UUID order;

    @BeforeEach void setup() {
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("planning-generation-"+suffix());
        fixture.loginAs(world.superAdminUserId());
        transactions=new TransactionTemplate(transactionManager);
        order=sales.create(fixture.orderRequest(world,world.goodsA(),"10","100")).getId();
        sales.approve(order);
        SalesManagerReviewFixtures.approveOrderForFinance(jdbc,claims,managers,order,0);
        financeConfirm(1);
    }
    @AfterEach void cleanup() {
        for(UUID user:recipients)jdbc.update("UPDATE users SET status='disabled' WHERE id=?",user);
        SecurityContextHolder.clearContext();
    }

    @Test void supersessionKeepsBothReceiptIdentitiesAndUnmodifiedUnreadHistory() {
        UUID user=planner();drain();UUID original=notice(user,1);
        String oldIdentity=identity(original),oldState=state(original,user);
        reconfirm("10",1);drain();UUID current=notice(user,2);
        assertNotEquals(original,current);assertEquals(2,count(user));assertEquals(1,active(user));
        assertEquals("SUPERSEDED_BY_REVIEW",jdbc.queryForObject("SELECT resolved_reason FROM notices WHERE id=?",String.class,original));
        assertEquals(oldIdentity,identity(original));assertEquals(oldState,state(original,user));
        for(UUID id:List.of(original,current))assertNull(jdbc.queryForObject(
                "SELECT read_at FROM notice_user_states WHERE notice_id=? AND user_id=?",java.sql.Timestamp.class,id,user));
        assertNull(jdbc.queryForObject("SELECT resolved_at FROM notices WHERE id=?",java.sql.Timestamp.class,current));
        fixture.loginAs(user);
        assertEquals(1,notices.pendingReviews().stream().filter(n->"SALES_ORDER_APPROVED".equals(n.sourceEvent())
                && order.toString().equals(n.aggregateId())).count());
        fixture.loginAs(world.superAdminUserId());catchUp.runBatch();drain();deliver("SALES_ORDER_APPROVED",2);
        assertEquals(2,count(user));assertEquals(1,active(user));
    }

    @Test void supersedingAReviewDoesNotResetReadAckDeleteOrSnoozeState() {
        var users=new ArrayList<UUID>();var oldIds=new ArrayList<UUID>();var states=new ArrayList<String>();
        for(String mode:List.of("read","ack","delete","snooze")) {
            UUID user=planner();users.add(user);catchUp.runBatch();drain();UUID id=notice(user,1);oldIds.add(id);
            fixture.loginAs(user);
            switch(mode) {
                case "read" -> notices.markRead(id);
                case "ack" -> notices.acknowledgePopup(id);
                case "delete" -> notices.deleteForCurrentUser(List.of(id));
                case "snooze" -> notices.snoozeNotice(id,5);
                default -> fail();
            }
            states.add(state(id,user));fixture.loginAs(world.superAdminUserId());
        }
        reconfirm("10",1);drain();
        for(int i=0;i<users.size();i++) {
            UUID user=users.get(i),current=notice(user,2);
            assertEquals(states.get(i),state(oldIds.get(i),user));assertEquals(1,active(user));
            assertNull(jdbc.queryForObject("SELECT read_at FROM notice_user_states WHERE notice_id=? AND user_id=?",
                    java.sql.Timestamp.class,current,user));
        }
    }

    @Test void lateOutboxGenerationsCannotSupersedeOrReviveAnyCurrentCard() {
        UUID user=planner();drain();UUID original=notice(user,1);
        reconfirm("11",2);drain();UUID current=notice(user,3);
        String currentIdentity=identity(current),currentState=state(current,user);
        for(String event:List.of("SALES_ORDER_APPROVED","SALES_ORDER_FINANCE_CONFIRMED","SALES_PLANNING_NOTICE_CATCH_UP"))
            deliver(event,1);
        assertEquals(2,count(user));assertEquals(1,active(user));
        assertEquals(currentIdentity,identity(current));assertEquals(currentState,state(current,user));
        assertNotNull(jdbc.queryForObject("SELECT resolved_at FROM notices WHERE id=?",java.sql.Timestamp.class,original));
        assertNull(jdbc.queryForObject("SELECT resolved_at FROM notices WHERE id=?",java.sql.Timestamp.class,current));
        sales.cancel(order);drain();
        deliver("SALES_PLANNING_NOTICE_CATCH_UP",3);deliver("SALES_ORDER_APPROVED",1);
        assertEquals(0,active(user));assertEquals(2,count(user));
    }

    @Test void newPublicationFailureRollsBackOldSupersessionAndAllNewStateRows() {
        UUID user=planner();drain();UUID original=notice(user,1);String oldState=state(original,user);
        reconfirm("10",1);
        doAnswer(call->{call.callRealMethod();throw new IllegalStateException("intentional generation receipt failure");})
                .when(notices).publishSalesPlanningHandoff(eq(user),eq(order),eq(2L),anyString(),anyString());
        try { assertThrows(OutboxDeliveryException.class,this::drain); }
        finally { doCallRealMethod().when(notices).publishSalesPlanningHandoff(eq(user),eq(order),eq(2L),anyString(),anyString()); }
        assertEquals(1,count(user));assertEquals(1,active(user));assertEquals(oldState,state(original,user));
        assertNull(jdbc.queryForObject("SELECT resolved_at FROM notices WHERE id=?",java.sql.Timestamp.class,original));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM notice_user_states s JOIN notices n ON n.id=s.notice_id "
                +"WHERE n.aggregate_id=? AND n.source_revision=2 AND s.user_id=?",Integer.class,order,user));
        drain();assertEquals(2,count(user));assertEquals(1,active(user));
        catchUp.runBatch();drain();assertEquals(2,count(user));
    }

    @Test void catchUpRepairsAnEarlierActiveGenerationEvenWhenCurrentAlreadyExists() {
        UUID user=planner();drain();reconfirm("10",1);drain();UUID current=notice(user,2);
        // Reproduce a persisted older known-generation card from the old producer,
        // through the native notice writer; no business approval is fabricated.
        UUID older=notices.publishSalesPlanningHandoff(user,order,0,"旧投递证据","保留原记录").getId();
        String oldState=state(older,user),currentState=state(current,user);
        assertEquals(2,active(user));assertTrue(chain.enqueueSalesPlanningCatchUp(order));drain();
        assertEquals(1,active(user));assertEquals(3,count(user));
        assertEquals(oldState,state(older,user));assertEquals(currentState,state(current,user));
        assertNotNull(jdbc.queryForObject("SELECT resolved_at FROM notices WHERE id=?",java.sql.Timestamp.class,older));
        assertNull(jdbc.queryForObject("SELECT resolved_at FROM notices WHERE id=?",java.sql.Timestamp.class,current));
        assertFalse(chain.enqueueSalesPlanningCatchUp(order));
    }

    @Test void legacyNullGenerationRemainsUnattributedAndNewRecipientsGetOnlyCurrent() {
        drain();UUID oldUser=planner();
        UUID legacy=notices.publishForUser(oldUser,"历史计划提醒","来源代次未证明","task","系统",
                "/production/material-analysis","SALES_ORDER_APPROVED","normal",order).getId();
        String oldIdentity=identity(legacy),oldState=state(legacy,oldUser);
        reconfirm("10",1);drain();UUID newcomer=planner();catchUp.runBatch();drain();
        assertEquals(1,count(oldUser));assertEquals(1,active(oldUser));
        assertEquals(oldIdentity,identity(legacy));assertEquals(oldState,state(legacy,oldUser));
        assertNull(jdbc.queryForObject("SELECT source_revision FROM notices WHERE id=?",Long.class,legacy));
        assertNull(jdbc.queryForObject("SELECT resolved_at FROM notices WHERE id=?",java.sql.Timestamp.class,legacy));
        assertNotNull(notice(newcomer,2));assertEquals(1,active(newcomer));
    }

    private void reconfirm(String qty,long displayedManagerRevision) {
        fixture.loginAs(world.superAdminUserId());
        var request=fixture.orderRequest(world,world.goodsA(),qty,"100");
        request.getItems().getFirst().setId(jdbc.queryForObject("SELECT id FROM sales_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,order));
        sales.update(order,request);
        SalesManagerReviewFixtures.approveOrderForFinance(jdbc,claims,managers,order,displayedManagerRevision);
        financeConfirm(displayedManagerRevision+1);
    }
    private void financeConfirm(long displayedRevision) {
        var lease=claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.toString());
        finance.confirm(order,new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null,displayedRevision,lease.claimId()));
    }
    private UUID planner() {
        UUID user=fixture.createUserWithPerms(world,"generation-planner-"+suffix(),
                "notice:read","production_material_analysis:view","production_material_analysis:create");
        recipients.add(user);return user;
    }
    private void drain() { for(int n=0;n<1000;n++){if(!processor.processNext())return;}fail("Outbox did not settle"); }
    private void deliver(String event,long revision) {
        transactions.executeWithoutResult(status->chain.deliverOutboxEvent(event,order,json.createObjectNode().put("reviewRevision",revision)));
    }
    private UUID notice(UUID user,long revision) {
        return jdbc.queryForObject("SELECT id FROM notices WHERE source_event='SALES_ORDER_APPROVED' AND aggregate_id=? "
                +"AND audience_user_id=? AND source_revision=?",UUID.class,order,user,revision);
    }
    private int count(UUID user) {return jdbc.queryForObject("SELECT count(*) FROM notices WHERE source_event='SALES_ORDER_APPROVED' "
            +"AND aggregate_id=? AND audience_user_id=?",Integer.class,order,user);}
    private int active(UUID user) {return jdbc.queryForObject("SELECT count(*) FROM notices WHERE source_event='SALES_ORDER_APPROVED' "
            +"AND aggregate_id=? AND audience_user_id=? AND resolved_at IS NULL",Integer.class,order,user);}
    private String state(UUID notice,UUID user) {return jdbc.queryForObject("SELECT to_jsonb(s)::text FROM notice_user_states s "
            +"WHERE notice_id=? AND user_id=?",String.class,notice,user);}
    private String identity(UUID notice) {return jdbc.queryForObject("SELECT jsonb_build_array(id,aggregate_kind,aggregate_id,audience_user_id,"
            +"source_event,source_revision,title,content,published_at)::text FROM notices WHERE id=?",String.class,notice);}
    private static String suffix(){return UUID.randomUUID().toString().substring(0,8);}
}
