package com.uten.imp.features.admin.workflow;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.support.BatchPermissionFixture;
import com.uten.imp.support.ObservedSqlDataSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/** Real candidate SQL and current authorization sources, independent of department identity. */
@Testcontainers
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class WorkflowPermissionPoolsPostgresTest {
    @Container
    static final PostgreSQLContainer DB = new PostgreSQLContainer("postgres:16-alpine");

    private JdbcTemplate jdbc;
    private BatchPermissionFixture data;
    private SalesOrderFinanceConfirmerEligibility orders;
    private SalesQuoteFinanceReviewerEligibility quotes;
    private WorkflowReviewerEligibility procurement;
    private List<UUID> actionPermissions;
    private List<UUID> viewPermissions;

    @BeforeEach
    void fixture() {
        jdbc = new JdbcTemplate(new ObservedSqlDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword()));
        data = new BatchPermissionFixture(jdbc);
        UUID procurementView = permission("finance_order_approval:view");
        UUID approve = permission("finance_order_approval:approve");
        permission("finance_order_approval:reject");
        UUID quoteView = permission("sales_quote_finance:view");
        UUID quoteConfirm = permission("sales_quote_finance:confirm");
        permission("sales_quote_finance:reject");
        permission("sales_quote_finance:reverse");
        viewPermissions = List.of(data.view, procurementView, quoteView);
        actionPermissions = List.of(data.confirm, approve, quoteConfirm);
        PermissionResolver resolver = data.resolver(true);
        var users = mock(UserAccountRepository.class);
        orders = new SalesOrderFinanceConfirmerEligibility(jdbc, users, resolver);
        quotes = new SalesQuoteFinanceReviewerEligibility(jdbc, users, resolver);
        procurement = new WorkflowReviewerEligibility(jdbc, users, resolver);
    }

    @Test
    void anotherDepartmentCanGrantEveryFinanceActionWithoutPersonalOverrides() {
        UUID actor = data.account(data.other, false);
        grantDepartment();
        assertAllPools(actor);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM user_permission_overrides WHERE user_id = ?",
                Long.class, actor)).isZero();
    }

    @Test
    void managerDelegationIsAnEffectiveGrantRatherThanAnInferiorAuthorizationSource() {
        UUID actor = data.account(data.other, false);
        UUID administrator = data.account(data.other, true);
        data.delegation(actor, data.other, administrator, data.view, true, null);
        data.delegation(actor, data.other, administrator, data.confirm, true, null);
        assertThat(orders.eligibleUserIds()).containsExactly(actor);
        data.override(actor, data.confirm, "revoke", "SUPER_ADMIN_CONFIRMED");
        assertThat(orders.eligibleUserIds()).isEmpty();
    }

    @Test
    void anOrdinaryDepartmentManagerCanDelegateFinanceReviewWithoutASecondPersonalGrant() {
        UUID manager = data.account(data.other, false);
        UUID actor = data.account(data.other, false);
        jdbc.update("UPDATE departments SET manager_id = ? WHERE id = ?", manager, data.other);
        data.grant(manager, data.view);
        data.grant(manager, data.confirm);
        data.delegation(actor, data.other, manager, data.view, false, data.other);
        data.delegation(actor, data.other, manager, data.confirm, false, data.other);
        assertThat(orders.eligibleUserIds()).containsExactlyInAnyOrder(actor, manager);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM user_permission_overrides WHERE user_id = ?",
                Long.class, actor)).isZero();
        data.override(actor, data.confirm, "revoke", "SUPER_ADMIN_CONFIRMED");
        assertThat(orders.eligibleUserIds()).containsExactly(manager);
    }

    @Test
    void revokingEitherPageOrActionPermissionRemovesTheTaskFromEveryPool() {
        UUID actor = data.account(data.other, false);
        grantDepartment();
        assertAllPools(actor);
        for (UUID permission : viewPermissions) data.override(actor, permission, "revoke", "SUPER_ADMIN_CONFIRMED");
        assertNoPools();
        for (UUID permission : viewPermissions) data.grant(actor, permission);
        for (UUID permission : actionPermissions) data.override(actor, permission, "revoke", "SUPER_ADMIN_CONFIRMED");
        assertNoPools();
    }

    @Test
    void departedEmployeesAndDisabledAccountsAreNotAssignedWorkDespiteTheirGrants() {
        UUID resigned = data.account(data.other, false);
        UUID disabled = data.account(data.other, false);
        grantDepartment();
        jdbc.update("UPDATE employees SET status = 'resigned' WHERE id = ?", resigned);
        jdbc.update("UPDATE users SET status = 'disabled' WHERE id = ?", disabled);
        assertNoPools();
    }

    @Test
    void superAdminCatalogAccessDoesNotSubscribeAnAccountToAllTasks() {
        UUID actor = data.account(data.other, true);
        assertNoPools();
        for (UUID permission : viewPermissions) data.grant(actor, permission);
        for (UUID permission : actionPermissions) data.grant(actor, permission);
        assertAllPools(actor);
    }

    @Test
    void rejectionOnlyReviewerIsAssignedPendingQuotesButReopenOnlyReviewerIsNot() {
        UUID rejector = data.account(data.other, false);
        UUID reopener = data.account(data.other, false);
        UUID view = jdbc.queryForObject("SELECT id FROM permissions WHERE code='sales_quote_finance:view'", UUID.class);
        UUID reject = jdbc.queryForObject("SELECT id FROM permissions WHERE code='sales_quote_finance:reject'", UUID.class);
        UUID reverse = jdbc.queryForObject("SELECT id FROM permissions WHERE code='sales_quote_finance:reverse'", UUID.class);
        data.grant(rejector, view); data.grant(rejector, reject);
        data.grant(reopener, view); data.grant(reopener, reverse);
        assertThat(quotes.eligibleUserIds()).containsExactly(rejector);
        data.override(rejector, reject, "revoke", "SUPER_ADMIN_CONFIRMED");
        assertThat(quotes.eligibleUserIds()).isEmpty();
    }

    private void grantDepartment() {
        for (List<UUID> permissions : List.of(viewPermissions, actionPermissions)) {
            for (UUID permission : permissions) {
                jdbc.update("INSERT INTO department_permissions(department_id, permission_id) VALUES (?, ?)",
                        data.other, permission);
            }
        }
    }

    private void assertAllPools(UUID actor) {
        assertThat(orders.eligibleUserIds()).containsExactly(actor);
        assertThat(quotes.eligibleUserIds()).containsExactly(actor);
        assertThat(procurement.allEligible()).extracting(row -> row.userId()).containsExactly(actor);
    }

    private void assertNoPools() {
        assertThat(orders.eligibleUserIds()).isEmpty();
        assertThat(quotes.eligibleUserIds()).isEmpty();
        assertThat(procurement.allEligible()).isEmpty();
    }

    private UUID permission(String code) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO permissions(id, code) VALUES (?, ?)", id, code);
        return id;
    }
}
