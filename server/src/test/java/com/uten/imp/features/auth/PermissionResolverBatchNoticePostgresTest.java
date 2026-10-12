package com.uten.imp.features.auth;

import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.support.BatchPermissionFixture;
import com.uten.imp.support.ObservedSqlDataSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.support.BatchPermissionFixture.REQUIRED;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

@Testcontainers
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class PermissionResolverBatchNoticePostgresTest {
    @Container static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine")
            .withLabel("uten.test", "permission-batch-notice");
    private JdbcTemplate jdbc;
    private BatchPermissionFixture data;
    private PermissionResolver resolver;
    private ObservedSqlDataSource source;

    @BeforeEach void schema() {
        source = new ObservedSqlDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(source);
        data = new BatchPermissionFixture(jdbc);
        resolver = data.resolver(true);
    }

    @Test void fourHundredFiftyOneFinanceCandidatesAreResolvedWithoutPerUserRepositoryReads() {
        List<UUID> candidates = data.accounts(451,data.finance,false);
        UUID eligible=candidates.get(271);
        data.grant(eligible, data.view); data.grant(eligible, data.confirm);
        var users=mock(UserAccountRepository.class);
        var eligibility=new SalesOrderFinanceConfirmerEligibility(jdbc,users,resolver);
        source.statements.set(0);
        assertThat(eligibility.eligibleUserIds()).containsExactly(eligible);
        verifyNoInteractions(users);
        // Both real recipient statements execute against PostgreSQL. No query
        // grows linearly with candidate count, including negative candidates.
        assertThat(source.statements.get()).isEqualTo(2);
    }

    @Test void primaryAndSecondaryAncestorGrantsPersonalRevokesAndSuperAdminTaskOwnershipStayExact() {
        UUID child=UUID.randomUUID(); data.department(child,"FIN_CHILD","二级班组",data.finance);
        data.departmentGrants(data.finance);
        UUID primary=data.account(child,false), secondary=data.account(data.other,false);
        UUID revoked=data.account(child,false), outsideAdmin=data.account(data.other,true);
        UUID grantedAdmin=data.account(data.other,true), disabled=data.account(child,false);
        jdbc.update("INSERT INTO employee_secondary_departments VALUES (?,?)",secondary,child);
        data.override(revoked,data.confirm,"revoke","SUPER_ADMIN_CONFIRMED");
        data.grant(grantedAdmin,data.view); data.grant(grantedAdmin,data.confirm);
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?",disabled);
        assertThat(resolver.usersGrantedAll(List.of(primary,secondary,revoked,outsideAdmin,grantedAdmin,disabled),REQUIRED))
                .containsExactly(primary,secondary,grantedAdmin);
        assertThat(resolver.usersGrantedAll(List.of(primary,primary),Set.of("removed:permission"))).isEmpty();
        assertThat(resolver.usersGrantedAll(List.of(primary,primary),REQUIRED)).containsExactly(primary);
    }

    @Test void currentManagerCeilingCannotUseLegacyGrantsAndBothSidesRevocationWin() {
        UUID target=data.account(data.finance,false), manager=data.account(data.other,false);
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",manager,data.finance);
        data.grant(target,data.view);
        data.override(manager,data.confirm,"grant","LEGACY_UNKNOWN");
        data.delegation(target,data.finance,manager,data.confirm,false,data.finance);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
        jdbc.update("UPDATE user_permission_overrides SET authority_source='SUPER_ADMIN_CONFIRMED' WHERE user_id=?",manager);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).containsExactly(target);
        data.override(manager,data.confirm,"revoke","SUPER_ADMIN_CONFIRMED");
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
        data.grant(manager,data.confirm);
        data.override(target,data.confirm,"revoke","LEGACY_UNKNOWN");
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
        jdbc.update("DELETE FROM user_permission_overrides WHERE user_id=? AND effect='revoke'",target);
        data.override(target,data.confirm,"grant","LEGACY_UNKNOWN");
        jdbc.update("UPDATE manager_permission_delegations SET enabled=false");
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).containsExactly(target);
    }

    @Test void everyDynamicDelegationGenerationAndAuthorizationEpochFailsClosed() {
        UUID target=data.account(data.finance,false), manager=data.account(data.other,false);
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",manager,data.finance);
        data.grant(target,data.view); data.grant(manager,data.confirm);
        data.delegation(target,data.finance,manager,data.confirm,false,data.finance);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).containsExactly(target);
        for (String column:List.of("target_user_generation","target_employee_generation","target_department_generation",
                "grantor_user_generation","grantor_employee_generation","grantor_auth_version",
                "grantor_authorization_epoch","scope_generation")) {
            jdbc.update("UPDATE manager_permission_delegations SET "+column+"=1");
            assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).as(column).isEmpty();
            jdbc.update("UPDATE manager_permission_delegations SET "+column+"=0");
        }
        jdbc.update("UPDATE authorization_state SET epoch=1");
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
        jdbc.update("UPDATE authorization_state SET epoch=0");
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?",data.other,target);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
        jdbc.update("UPDATE employees SET department_id=?,status='resigned' WHERE id=?",data.finance,target);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
    }

    @Test void employeeLessSuperAdminGrantorAndFeatureSwitchKeepDistinctAuthoritySemantics() {
        UUID target=data.account(data.finance,false), admin=data.account(data.other,true);
        jdbc.update("UPDATE users SET employee_id=null WHERE id=?",admin);
        data.grant(target,data.view);
        data.delegation(target,data.finance,admin,data.confirm,true,null);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).containsExactly(target);
        assertThat(data.resolver(false).usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
        data.grant(target,data.confirm);
        assertThat(data.resolver(false).usersGrantedAll(List.of(target),REQUIRED)).containsExactly(target);
        jdbc.update("DELETE FROM user_permission_overrides WHERE user_id=? AND permission_id=?",target,data.confirm);
        jdbc.update("UPDATE manager_permission_delegations SET surface_key='unknown'");
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
        jdbc.update("UPDATE manager_permission_delegations SET surface_key='sales.finance'");
        jdbc.update("UPDATE permissions SET baseline=true WHERE id=?",data.confirm);
        // Baseline itself grants the code; deleting it from target with a revoke
        // cannot be repaired by a delegation from the excluded baseline ceiling.
        data.override(target,data.confirm,"revoke","SUPER_ADMIN_CONFIRMED");
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
    }

    @Test void nearestManagerAncestorAndCanonicalGmCompanyScopeAreRevalidated() {
        UUID child=UUID.randomUUID(); data.department(child,"FIN_CHILD","二级班组",data.finance);
        UUID target=data.account(child,false), manager=data.account(data.other,false);
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",manager,data.finance);
        data.grant(target,data.view); data.grant(manager,data.confirm);
        data.delegation(target,child,manager,data.confirm,false,data.finance);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).containsExactly(target);
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",manager,child);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
        jdbc.update("UPDATE manager_permission_delegations SET scope_department_id=?",child);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).containsExactly(target);
        UUID gm=UUID.randomUUID(); data.department(gm,"GM","一级部门",data.company);
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",manager,gm);
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?",gm,manager);
        jdbc.update("UPDATE manager_permission_delegations SET scope_department_id=?",gm);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).containsExactly(target);
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?",data.other,manager);
        assertThat(resolver.usersGrantedAll(List.of(target),REQUIRED)).isEmpty();
    }
}
