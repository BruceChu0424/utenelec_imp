package com.uten.imp.features.auth;

import com.uten.imp.features.rbac.Permission;
import com.uten.imp.features.rbac.PermissionDependencyCatalog;
import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.PermissionGrantPolicyCatalog;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistryTestFixture;
import com.uten.imp.security.PermissionDelegationPolicy;
import com.uten.imp.support.BatchPermissionFixture;
import com.uten.imp.support.ObservedSqlDataSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.List;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PermissionDependencyBatchPostgresTest {
    @Container static final PostgreSQLContainer DB = new PostgreSQLContainer("postgres:16-alpine");
    private BatchPermissionFixture data;
    private JdbcTemplate jdbc;
    private ObservedSqlDataSource source;
    private PermissionResolver resolver;

    @BeforeEach void fixture() {
        source = new ObservedSqlDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(source);
        data = new BatchPermissionFixture(jdbc);
        resolver = data.resolver(true);
        Permission view = new Permission(); view.setCode(BatchPermissionFixture.VIEW); view.setActionType("VIEW");
        Permission confirm = new Permission(); confirm.setCode(BatchPermissionFixture.CONFIRM); confirm.setActionType("APPROVE");
        ReflectionTestUtils.setField(resolver, "dependencies", new PermissionDependencyCatalog(List.of(view, confirm)));
    }

    @Test void theSameAuthorityStatementSeesRequiredReadsAndTheirExplicitRevokes() {
        UUID actor = data.account(data.other, false);
        jdbc.update("INSERT INTO department_permissions VALUES (?, ?)", data.other, data.confirm);
        source.statements.set(0);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of(BatchPermissionFixture.CONFIRM))).isEmpty();
        assertThat(source.statements.get()).isEqualTo(1);
        jdbc.update("INSERT INTO department_permissions VALUES (?, ?)", data.other, data.view);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of(BatchPermissionFixture.CONFIRM))).containsExactly(actor);
        data.override(actor, data.view, "revoke", "SUPER_ADMIN_CONFIRMED");
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of(BatchPermissionFixture.CONFIRM))).isEmpty();
    }

    @Test void aValidDelegatedReadCanCompleteAnActionGrantedByAnotherSource() {
        UUID actor = data.account(data.other, false);
        UUID administrator = data.account(data.other, true);
        data.grant(actor, data.confirm);
        data.delegation(actor, data.other, administrator, data.view, true, null);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of(BatchPermissionFixture.CONFIRM))).containsExactly(actor);
        data.override(actor, data.view, "revoke", "SUPER_ADMIN_CONFIRMED");
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of(BatchPermissionFixture.CONFIRM))).isEmpty();
    }

    @Test void aManagerCannotDelegateAnActionWhoseOwnRequiredReadIsMissing() {
        UUID manager = data.account(data.other, false);
        UUID actor = data.account(data.other, false);
        jdbc.update("UPDATE departments SET manager_id = ? WHERE id = ?", manager, data.other);
        data.grant(manager, data.confirm);
        data.grant(actor, data.view);
        data.delegation(actor, data.other, manager, data.confirm, false, data.other);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of(BatchPermissionFixture.CONFIRM))).isEmpty();
        data.grant(manager, data.view);
        jdbc.update("DELETE FROM manager_permission_delegations WHERE user_id = ?", actor);
        data.delegation(actor, data.other, manager, data.confirm, false, data.other);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of(BatchPermissionFixture.CONFIRM))).containsExactly(actor);
        data.override(manager, data.view, "revoke", "SUPER_ADMIN_CONFIRMED");
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of(BatchPermissionFixture.CONFIRM))).isEmpty();
    }

    @Test void staffAccountSupportDoesNotImplyAccessToBankAndCashAccountMasters() {
        UUID actor = data.account(data.other, false);
        UUID support = extraPermission("account:support", "EXECUTE");
        extraPermission("account:view", "VIEW");
        installCurrentDefinitions();
        data.grant(actor, support);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("account:support"))).containsExactly(actor);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("account:view"))).isEmpty();
    }

    @Test void documentEnglishNameLearningRemainsIndependentOfGeneralGoodsBrowsing() {
        UUID actor = data.account(data.other, false);
        UUID learning = extraPermission("goods:name_en:edit", "EDIT");
        extraPermission("goods:view", "VIEW");
        installCurrentDefinitions();
        data.grant(actor, learning);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("goods:name_en:edit"))).containsExactly(actor);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("goods:view"))).isEmpty();
    }

    @Test void independentActionsRemainGrantedWhenTheirUnrelatedPageReadsAreExplicitlyRevoked() {
        UUID actor = data.account(data.other, false);
        List<String> commands = independentCommands();
        Map<String, UUID> identifiers = addIndependentDefinitions(commands);
        installCurrentDefinitions();
        commands.forEach(code -> data.grant(actor, identifiers.get(code)));
        unrelatedReads().forEach(code -> data.override(actor, identifiers.get(code), "revoke", "SUPER_ADMIN_CONFIRMED"));
        source.statements.set(0);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.copyOf(commands))).containsExactly(actor);
        assertThat(source.statements.get()).isEqualTo(1);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("employee:view"))).isEmpty();
        data.override(actor, identifiers.get("attachment:upload"), "revoke", "SUPER_ADMIN_CONFIRMED");
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("attachment:upload"))).isEmpty();
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("rd_task:resolve", "employee:create", "goods:price:edit")))
                .containsExactly(actor);
    }

    @Test void managerDelegationKeepsIndependentCommandsWithoutAnInventedGrantorOrTargetReadCeiling() {
        UUID manager = data.account(data.other, false);
        UUID actor = data.account(data.other, false);
        jdbc.update("UPDATE departments SET manager_id = ? WHERE id = ?", manager, data.other);
        List<String> commands = independentCommands();
        Map<String, UUID> identifiers = addIndependentDefinitions(commands);
        Map<String, Set<GrantPolicy>> policies = new LinkedHashMap<>();
        commands.forEach(code -> policies.put(code, Set.of(GrantPolicy.NORMAL)));
        ReflectionTestUtils.setField(resolver, "delegationPolicy",
                new PermissionDelegationPolicy(PermissionGrantPolicyCatalog.fixed(policies)));
        ReflectionTestUtils.setField(resolver, "surfaceRegistry", PermissionSurfaceRegistryTestFixture.registry(
                Map.of("sales.finance", Set.copyOf(commands))));
        installCurrentDefinitions();
        commands.forEach(code -> data.grant(manager, identifiers.get(code)));
        unrelatedReads().forEach(code -> {
            data.override(manager, identifiers.get(code), "revoke", "SUPER_ADMIN_CONFIRMED");
            data.override(actor, identifiers.get(code), "revoke", "SUPER_ADMIN_CONFIRMED");
        });
        commands.forEach(code -> data.delegation(actor, data.other, manager, identifiers.get(code), false, data.other));
        source.statements.set(0);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.copyOf(commands))).containsExactly(actor);
        assertThat(source.statements.get()).isEqualTo(1);
        data.override(manager, identifiers.get("rd_task:resolve"), "revoke", "SUPER_ADMIN_CONFIRMED");
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("rd_task:resolve"))).isEmpty();
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("employee:create", "goods:price:edit")))
                .containsExactly(actor);
    }

    @Test void costImportEditingNeedsItsSensitiveCostReadButNotGeneralGoodsBrowsing() {
        UUID actor = data.account(data.other, false);
        UUID edit = extraPermission("goods:cost:edit", "EDIT");
        UUID costRead = extraPermission("goods:cost:view", "VIEW");
        UUID goodsRead = extraPermission("goods:view", "VIEW");
        installCurrentDefinitions();
        data.grant(actor, edit);
        data.grant(actor, costRead);
        data.override(actor, goodsRead, "revoke", "SUPER_ADMIN_CONFIRMED");
        source.statements.set(0);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("goods:cost:edit"))).containsExactly(actor);
        assertThat(source.statements.get()).isEqualTo(1);
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("goods:view"))).isEmpty();
        data.override(actor, costRead, "revoke", "SUPER_ADMIN_CONFIRMED");
        assertThat(resolver.usersGrantedAll(List.of(actor), Set.of("goods:cost:edit"))).isEmpty();
    }

    private List<String> independentCommands() {
        return List.of("employee:create", "employee:pii:edit", "employee:compensation:edit", "goods:price:edit",
                "goods:edit", "attachment:upload", "attachment:download", "rd_task:resolve",
                "purchase_order:decompose", "subcontract_order:decompose", "account:balance:adjust");
    }

    private List<String> unrelatedReads() {
        return List.of("employee:view", "department:view", "goods:view", "attachment:view", "rd_task:view",
                "purchase_order:view", "purchase_request:view", "subcontract_order:view", "subcontract_application:view",
                "account:view", "account:balance:view");
    }

    private Map<String, UUID> addIndependentDefinitions(List<String> commands) {
        Map<String, UUID> identifiers = new LinkedHashMap<>();
        commands.forEach(code -> identifiers.put(code, extraPermission(code, "EDIT")));
        unrelatedReads().forEach(code -> identifiers.put(code, extraPermission(code, "VIEW")));
        return identifiers;
    }

    private UUID extraPermission(String code, String type) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO permissions(id, code, action_type) VALUES (?, ?, ?)", id, code, type);
        return id;
    }

    private void installCurrentDefinitions() {
        List<Permission> definitions = jdbc.query("SELECT code, action_type FROM permissions", (row, index) -> {
            Permission permission = new Permission();
            permission.setCode(row.getString(1)); permission.setActionType(row.getString(2));
            return permission;
        });
        ReflectionTestUtils.setField(resolver, "dependencies", new PermissionDependencyCatalog(definitions));
    }
}
