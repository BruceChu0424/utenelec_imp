package com.uten.imp.features.notice;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.admin.workflow.SalesQuoteFinanceReviewerEligibility;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.rd_task.RdTaskService;
import com.uten.imp.security.EmployeeHandoverVisibility;
import com.uten.imp.support.BatchPermissionFixture;
import com.uten.imp.support.ObservedSqlDataSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

@Testcontainers
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ChainNoticeBatchRecipientsPostgresTest {
    @Container static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine")
            .withLabel("uten.test","chain-notice-batch-recipients");
    private BatchPermissionFixture data;
    private JdbcTemplate jdbc;
    private ObservedSqlDataSource source;
    private ChainNoticeService chain;
    private UUID draw,viewAll;

    @BeforeEach void fixture() {
        source=new ObservedSqlDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());
        jdbc=new JdbcTemplate(source); data=new BatchPermissionFixture(jdbc);
        UUID read=permission("notice:read"),view=permission("subcontract_order:view");
        draw=permission("subcontract_order:draw"); viewAll=permission("subcontract:view:all");
        jdbc.update("INSERT INTO department_permissions VALUES (?,?),(?,?),(?,?)",
                data.finance,read,data.finance,view,data.finance,draw);
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(jdbc,"employment_history","user_data_scopes");
        var users=mock(UserAccountRepository.class);
        when(users.findAll()).thenAnswer(call -> jdbc.query("SELECT id,employee_id,status,is_deleted FROM users",(rs,row)->{
            var user=new UserAccount(); user.setId(rs.getObject(1,UUID.class)); user.setEmployeeId(rs.getObject(2,UUID.class));
            user.setStatus(rs.getString(3)); user.setDeleted(rs.getBoolean(4)); return user;
        }));
        chain=new ChainNoticeService(mock(NoticeService.class),users,data.resolver(true),jdbc,
                mock(BusinessEventPublisher.class),mock(RdTaskService.class),mock(FinanceReviewerEligibilityPort.class),
                mock(SalesOrderFinanceConfirmerEligibility.class));
    }

    @Test void fourHundredFiftyOneDrawCandidatesKeepOwnerHandoverRehireScopeAndActualViewAllWithFourReads() {
        List<UUID> all=data.accounts(451,data.finance,false);
        UUID owner=all.get(0),responsible=all.get(1),scoped=all.get(2),global=all.get(3),stale=all.get(4);
        var handover=mock(EmployeeHandoverVisibility.class);
        when(handover.currentResponsible("subcontract",owner)).thenReturn(responsible);
        chain.setHandoverVisibility(handover);
        data.grant(global,viewAll);
        jdbc.update("INSERT INTO employment_history(employee_id,event_type) VALUES (?,'rehire')",owner);
        jdbc.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id,owner_employment_generation) VALUES (?,'subcontract',?,1),(?,'subcontract',?,0)",scoped,owner,stale,owner);
        source.statements.set(0);
        assertThat(drawRecipients(owner)).containsExactlyInAnyOrder(owner,responsible,scoped,global);
        assertThat(source.statements.get()).isEqualTo(4);
        verify(handover,times(1)).currentResponsible("subcontract",owner);
        jdbc.update("INSERT INTO employment_history(employee_id,event_type) VALUES (?,'rehire')",owner);
        assertThat(drawRecipients(owner)).containsExactlyInAnyOrder(owner,responsible,global);
        data.override(global,viewAll,"revoke","SUPER_ADMIN_CONFIRMED");
        assertThat(drawRecipients(owner)).containsExactlyInAnyOrder(owner,responsible);
        data.override(responsible,draw,"revoke","SUPER_ADMIN_CONFIRMED");
        assertThat(drawRecipients(owner)).containsExactly(owner);
    }

    @Test void anyActionRequiresItsPageGateAndSuperAdminCatalogDoesNotAssignDrawWork() {
        UUID read=permission("task:read"),view=permission("task:view"),approve=permission("task:approve"),reject=permission("task:reject");
        UUID normal=data.account(data.other,false),rejectOnly=data.account(data.other,false),missingView=data.account(data.other,false);
        UUID administrator=data.account(data.other,true);
        for(UUID user:List.of(normal,rejectOnly,missingView))data.grant(user,read);
        data.grant(normal,view);data.grant(normal,approve);
        data.grant(rejectOnly,view);data.grant(rejectOnly,reject);data.grant(missingView,approve);
        var resolver=data.resolver(true);
        assertThat(resolver.usersGrantedAllAndAny(List.of(normal,rejectOnly,missingView,administrator),
                Set.of("task:read","task:view"),Set.of("task:approve","task:reject")))
                .containsExactly(normal,rejectOnly);
        data.override(normal,view,"revoke","SUPER_ADMIN_CONFIRMED");
        assertThat(resolver.usersGrantedAllAndAny(List.of(normal,rejectOnly),
                Set.of("task:read","task:view"),Set.of("task:approve","task:reject"))).containsExactly(rejectOnly);
        assertThat(drawRecipients(administrator)).isEmpty();
    }

    @Test void planningScopeAtScaleUsesTheSameCurrentHandoverAndRehireBinding() {
        List<UUID> candidates=data.accounts(451,data.finance,false);
        UUID owner=candidates.get(0),successor=candidates.get(1),scoped=candidates.get(2),global=candidates.get(3);
        UUID allPlans=permission("production_plan:view:all");data.grant(global,allPlans);
        var handover=mock(EmployeeHandoverVisibility.class);
        when(handover.currentResponsible("production_plan",owner)).thenReturn(successor);
        chain.setHandoverVisibility(handover);
        jdbc.update("INSERT INTO employment_history(employee_id,event_type) VALUES (?,'rehire')",owner);
        jdbc.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id,owner_employment_generation) VALUES (?,'production_plan',?,1)",scoped,owner);
        source.statements.set(0);
        List<UUID> readers=ReflectionTestUtils.invokeMethod(chain,"productionAnalysisReaders",candidates,owner);
        assertThat(readers).containsExactlyInAnyOrder(owner,successor,scoped,global);
        assertThat(source.statements.get()).isEqualTo(2);
        data.override(global,allPlans,"revoke","SUPER_ADMIN_CONFIRMED");
        jdbc.update("INSERT INTO employment_history(employee_id,event_type) VALUES (?,'rehire')",owner);
        readers=ReflectionTestUtils.invokeMethod(chain,"productionAnalysisReaders",candidates,owner);
        assertThat(readers).containsExactlyInAnyOrder(owner,successor);
    }

    @Test void generalFinanceAndQuotePoolsUseOneCurrentPermissionStatementWithoutExpandingSuperAdmins() {
        UUID view=permission("finance_order_approval:view"),approve=permission("finance_order_approval:approve"),reject=permission("finance_order_approval:reject");
        UUID quoteView=permission("sales_quote_finance:view"),quoteConfirm=permission("sales_quote_finance:confirm");
        List<UUID> all=data.accounts(451,data.finance,false);
        UUID approving=all.get(0),rejecting=all.get(1),quote=all.get(2),admin=data.account(data.finance,true);
        data.grant(approving,view);data.grant(approving,approve);
        data.grant(rejecting,view);data.grant(rejecting,reject);
        data.grant(quote,quoteView);data.grant(quote,quoteConfirm);
        var users=mock(UserAccountRepository.class);var resolver=data.resolver(true);
        source.statements.set(0);
        assertThat(new WorkflowReviewerEligibility(jdbc,users,resolver).allEligible()).extracting(row -> row.userId())
                .containsExactlyInAnyOrder(approving,rejecting);
        assertThat(source.statements.get()).isEqualTo(2);
        source.statements.set(0);
        assertThat(new SalesQuoteFinanceReviewerEligibility(jdbc,users,resolver).eligibleUserIds()).containsExactly(quote);
        assertThat(source.statements.get()).isEqualTo(2);
        verifyNoInteractions(users);
        assertThat(resolver.usersGrantedAll(List.of(admin),Set.of("finance_order_approval:view","finance_order_approval:approve"))).isEmpty();
    }

    @SuppressWarnings("unchecked")
    private List<UUID> drawRecipients(UUID owner) {
        return (List<UUID>) ReflectionTestUtils.invokeMethod(chain,"subcontractDrawRecipients",owner);
    }

    private UUID permission(String code) {
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO permissions(id,code) VALUES (?,?)",id,code);return id;
    }
}
