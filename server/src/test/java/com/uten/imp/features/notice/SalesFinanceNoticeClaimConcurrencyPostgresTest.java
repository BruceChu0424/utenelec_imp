package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.SalesOrderFinanceReviewerEligibilityPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.common.taskclaim.TaskClaimRepository;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.rd_task.RdTaskService;
import com.uten.imp.features.sales.order.SalesFinanceClaimTargetLocks;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.BatchPermissionFixture;
import com.uten.imp.support.ObservedSqlDataSource;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.List;
import java.util.Optional;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

import static com.uten.imp.support.BatchPermissionFixture.REQUIRED;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real notice transaction/header lock and actual TaskClaimService contention. */
@Testcontainers
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class SalesFinanceNoticeClaimConcurrencyPostgresTest {
    @Container static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine")
            .withLabel("uten.test", "sales-finance-notice-claim");
    private ObservedSqlDataSource source;
    private JdbcTemplate jdbc;
    private BatchPermissionFixture data;
    private PermissionResolver permissions;
    private ChainNoticeService notices;
    private TaskClaimService claims;
    private TransactionTemplate noticeTx, claimTx;
    private EntityManagerFactory emf;
    private EntityManager em;
    private UUID order, reviewer, revoked;
    private final AtomicBoolean failSecondRecipient = new AtomicBoolean();
    private final AtomicInteger published = new AtomicInteger();

    @BeforeEach void fixture() {
        source = new ObservedSqlDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        jdbc = new JdbcTemplate(source);
        data = new BatchPermissionFixture(jdbc);
        permissions = data.resolver(true);
        reviewer=data.account(data.finance,false); revoked=data.account(data.finance,false);
        data.accounts(449,data.finance,false);
        for (UUID id:List.of(reviewer,revoked)) { data.grant(id,data.view); data.grant(id,data.confirm); }
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(jdbc,"sales_orders","notices");
        order=UUID.randomUUID(); jdbc.update("INSERT INTO sales_orders(id,bill_no,status) VALUES (?,'XD-BATCH-451',1)",order);
        var users=mock(UserAccountRepository.class);
        when(users.findById(any())).thenAnswer(call -> account(call.getArgument(0)));
        var recipientPool=new SalesOrderFinanceConfirmerEligibility(jdbc,users,permissions);
        var publisher=mock(NoticeService.class);
        when(publisher.publishForUser(any(),anyString(),anyString(),anyString(),anyString(),anyString(),
                anyString(),isNull(),any())).thenAnswer(call -> {
            if (published.incrementAndGet()==2 && failSecondRecipient.get()) throw new IllegalStateException("receiver write failed");
            jdbc.update("INSERT INTO notices(id,aggregate_kind,aggregate_id,source_event,audience_user_id,resolved_at) VALUES (?,'SALES_ORDER',?,?,?,null)",UUID.randomUUID(),
                    call.getArgument(8),call.getArgument(6),call.getArgument(0));
            return null;
        });
        when(publisher.resolveReviewNotices(anyString(),any(),anyString())).thenAnswer(call -> {
            String kind=call.getArgument(0,String.class);
            UUID aggregate=call.getArgument(1,UUID.class);
            return jdbc.update("UPDATE notices SET resolved_at=now() WHERE aggregate_kind=? AND aggregate_id=? AND resolved_at IS NULL",
                    kind,aggregate);
        });
        notices=new ChainNoticeService(publisher,users,permissions,jdbc,mock(BusinessEventPublisher.class),
                mock(RdTaskService.class),mock(FinanceReviewerEligibilityPort.class),recipientPool);
        noticeTx=new TransactionTemplate(new DataSourceTransactionManager(source));
        var factory=new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(source); factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        var properties=new Properties(); properties.setProperty("hibernate.hbm2ddl.auto","update");
        properties.setProperty("hibernate.jdbc.time_zone","UTC"); factory.setJpaProperties(properties);
        factory.afterPropertiesSet(); emf=factory.getObject(); em=SharedEntityManagerCreator.createSharedEntityManager(emf);
        claimTx=new TransactionTemplate(new JpaTransactionManager(emf)); claimTx.setTimeout(15);
        jdbc.execute("CREATE UNIQUE INDEX uq_task_claim_active ON task_claims(target_type,target_key) WHERE released_at IS NULL");
        var names=mock(EmployeeNameResolver.class); when(names.nameOf(any())).thenReturn("Reviewer");
        var claimEligibility=mock(SalesOrderFinanceReviewerEligibilityPort.class);
        when(claimEligibility.isEligible(any())).thenAnswer(call -> {
            UUID candidate=call.getArgument(0,UUID.class);
            return permissions.usersGrantedAll(List.of(candidate),REQUIRED).contains(candidate);
        });
        claims=new TaskClaimService(new JpaRepositoryFactory(em).getRepository(TaskClaimRepository.class),names,
                new SecurityContextCurrentUser(),mock(AuditService.class),List.of(new SalesFinanceClaimTargetLocks(em)),
                mock(FinanceReviewerEligibilityPort.class),claimEligibility);
    }

    @AfterEach void close() { source.beforePrepare=ignored -> {}; if (emf!=null) emf.close(); }

    @Test void oneBoundedAuthorityReadAtScaleReleasesTheRealClaimLockAndSeesCommittedRevocation() throws Exception {
        var reached=new CountDownLatch(1); var continueQuery=new CountDownLatch(1);
        var pause=new AtomicBoolean(true); var batchReads=new AtomicInteger();
        source.beforePrepare=sql -> {
            if (Thread.currentThread().getName().equals("notice-delivery") && sql.contains("requested AS MATERIALIZED")) {
                batchReads.incrementAndGet();
                if (pause.compareAndSet(true,false)) {
                    reached.countDown();
                    try { if (!continueQuery.await(8,TimeUnit.SECONDS)) throw new IllegalStateException("batch read gate not released"); }
                    catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new IllegalStateException(failure); }
                }
            }
        };
        try (var workers=Executors.newFixedThreadPool(2)) {
            try {
                Future<?> delivery=workers.submit(() -> { Thread.currentThread().setName("notice-delivery"); deliver(); });
                assertThat(reached.await(8,TimeUnit.SECONDS)).isTrue();
                Callable<Object> claimWork=this::claim;
                Future<?> claim=workers.submit(claimWork);
                assertDatabaseLockWait(claim);
                data.override(revoked,data.confirm,"revoke","SUPER_ADMIN_CONFIRMED");
                continueQuery.countDown();
                delivery.get(10,TimeUnit.SECONDS); claim.get(10,TimeUnit.SECONDS);
            } finally { continueQuery.countDown(); }
        }
        assertThat(batchReads.get()).isEqualTo(1);
        assertThat(jdbc.queryForList("SELECT audience_user_id FROM notices WHERE resolved_at IS NULL",UUID.class)).containsExactly(reviewer);
        assertThat(jdbc.queryForObject("SELECT claimed_by FROM task_claims WHERE released_at IS NULL",UUID.class)).isEqualTo(reviewer);
    }

    @Test void recipientFailureRollsBackDuplicateDeliveryIsIdempotentAndCancellationCannotBeResurrected() {
        failSecondRecipient.set(true);
        assertThatThrownBy(this::deliver).isInstanceOf(IllegalStateException.class);
        assertThat(activeNotices()).isZero();
        failSecondRecipient.set(false); deliver(); deliver();
        assertThat(activeNotices()).isEqualTo(2);
        noticeTx.executeWithoutResult(status -> {
            jdbc.update("UPDATE sales_orders SET is_stopped=true WHERE id=?",order);
            notices.notifyOrderCanceled(order);
        });
        assertThat(activeNotices()).isZero();
        deliver();
        assertThat(activeNotices()).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices WHERE resolved_at IS NOT NULL",Integer.class)).isEqualTo(2);
        assertThatThrownBy(this::claim).isInstanceOf(ApiException.class);
    }

    private void deliver() {
        noticeTx.executeWithoutResult(status -> notices.deliverOutboxEvent(
                ChainNoticeService.EVENT_ORDER_PENDING_FINANCE,order,new ObjectMapper().createObjectNode()));
    }

    private Object claim() {
        String previousThreadName=Thread.currentThread().getName();
        Thread.currentThread().setName("claim-mutation");
        var user=new AuthUser(reviewer,reviewer,"reviewer",REQUIRED,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
        try {
            return claimTx.execute(status -> {
                em.createNativeQuery("SELECT set_config('application_name','notice-claim-mutation',true)").getSingleResult();
                return claims.claim("SALES_ORDER_FINANCE_CONFIRM",order.toString());
            });
        } finally { SecurityContextHolder.clearContext(); Thread.currentThread().setName(previousThreadName); }
    }

    private void assertDatabaseLockWait(Future<?> claim) throws Exception {
        long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(8);
        while (System.nanoTime()<deadline) {
            if (claim.isDone()) { claim.get(); Assertions.fail("Claim completed before the notice header lock was released"); }
            if (jdbc.queryForObject("SELECT count(*) FROM pg_stat_activity WHERE application_name='notice-claim-mutation' AND wait_event_type='Lock'",Long.class)>0) return;
            TimeUnit.MILLISECONDS.sleep(20);
        }
        Assertions.fail("Claim did not reach the database header lock");
    }

    private Optional<UserAccount> account(UUID id) {
        return jdbc.query("SELECT id,employee_id,status,is_deleted FROM users WHERE id=?",(rs,row) -> {
            var user=new UserAccount(); user.setId(rs.getObject(1,UUID.class)); user.setEmployeeId(rs.getObject(2,UUID.class));
            user.setStatus(rs.getString(3)); user.setDeleted(rs.getBoolean(4)); return user;
        },id).stream().findFirst();
    }

    private int activeNotices() { return jdbc.queryForObject("SELECT count(*) FROM notices WHERE resolved_at IS NULL",Integer.class); }
}
