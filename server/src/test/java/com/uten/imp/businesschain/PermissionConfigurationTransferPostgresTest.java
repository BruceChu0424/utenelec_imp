package com.uten.imp.businesschain;

import com.uten.imp.testsupport.FixtureDatabaseProperties;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.PermissionConfigurationTransferService;
import com.uten.imp.features.admin.PermissionTemplateService;
import com.uten.imp.features.admin.dto.PermissionTemplateDtos;
import com.uten.imp.features.admin.dto.PermissionTransferDtos.*;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.sql.Connection;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Actual database triggers, application services, exported identities and rollback boundaries. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.storage.uploads-enabled=false"})
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=PermissionConfigurationTransferPostgresTest.Cleanup.class,
        mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class PermissionConfigurationTransferPostgresTest {
    private static final PostgreSQLContainer DATABASE=new PostgreSQLContainer("postgres:16-alpine");
    private static final String SECRET=UUID.randomUUID()+"-"+UUID.randomUUID();
    @DynamicPropertySource static void database(DynamicPropertyRegistry p) {
        DATABASE.start();
        // Real migrations belong to this empty fixture database, never the host's dev migrator.
        FixtureDatabaseProperties.bindSameRole(p, DATABASE::getJdbcUrl,
                DATABASE::getUsername, DATABASE::getPassword);
        p.add("uten.jwt.secret",()->SECRET);
        p.add("uten.crypto.pgp-master-key",()->SECRET);p.add("uten.crypto.hmac-key",()->SECRET);
        p.add("uten.bootstrap.admin-login",()->"transfer-bootstrap");p.add("uten.bootstrap.admin-password",()->SECRET+"Aa1!");
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder(){return new DirtiesContextTestExecutionListener().getOrder()-1;}
        @Override public void afterTestClass(TestContext ignored){DATABASE.stop();}
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired PermissionConfigurationTransferService transfer;
    @Autowired PermissionTemplateService templates;
    @Autowired com.uten.imp.features.admin.PermissionTemplateAssignmentService assignments;
    @Autowired PermissionResolver resolver;
    @Autowired com.uten.imp.features.admin.serveroperations.ServerOperationsActorAuthority serverAuthority;
    @Autowired com.uten.imp.features.org.department.staffpermission.PagePermissionWorkspaceService pagePermissions;
    @Autowired UserAccountRepository users;
    @Autowired ObjectMapper mapper;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    private UUID admin;
    @BeforeEach void login() {
        admin=jdbc.queryForObject("SELECT id FROM users WHERE is_super_admin ORDER BY created_at LIMIT 1",UUID.class);
        jdbc.update("UPDATE users SET must_change_password=false WHERE id=?",admin);
        var account=users.findById(admin).orElseThrow();
        AuthUser principal=new AuthUser(admin,account.getEmployeeId(),account.getLoginAccount(),resolver.permsOf(account),false,true,true);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities()));
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void copyMatchesEffectivePermissionsAndRevokesExtraInheritanceWithoutAddingOptionalNavigation() {
        UUID source=account(department(),"源"),targetDept=department(),target=account(targetDept,"目标");
        personal(source,"goods:edit");
        departmentGrant(targetDept,"goods:view");departmentGrant(targetDept,"supplier:view");
        Set<String> expected=effective(source);
        assertThat(expected).contains("goods:edit").doesNotContain("goods:view","supplier:view");
        var snapshot=transfer.copySnapshot(source);
        var request=new CopyRequest(source,snapshot.fingerprint());
        var preview=transfer.previewCopy(target,request);
        assertThat(preview.canApply()).isTrue();
        assertThat(preview.changes().getFirst().removed()).contains("goods:view","supplier:view");
        transfer.copyPermissions(target,new CopyCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(effective(target)).isEqualTo(expected);
        assertThat(jdbc.queryForList("SELECT p.code FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND o.active AND o.effect='revoke'",String.class,target))
                .contains("goods:view","supplier:view");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='permission_configuration_copy' AND target_id=?",Long.class,target.toString())).isEqualTo(1);
        // Repeated paste is a no-op after the authority source was already confirmed.
        var again=transfer.previewCopy(target,request);
        assertThat(transfer.copyPermissions(target,new CopyCommit(request,again.fingerprint(),confirmations(again))).changed()).isFalse();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='permission_configuration_copy' AND target_id=?",Long.class,target.toString())).isEqualTo(1);
    }

    @Test void sensitiveCopyRequiresExplicitItemConfirmationAndStalePreviewNeverWrites() {
        UUID source=account(department(),"敏感源"),target=account(department(),"敏感目标");
        personal(source,"goods:price:view");
        var snapshot=transfer.copySnapshot(source);var request=new CopyRequest(source,snapshot.fingerprint());
        var preview=transfer.previewCopy(target,request);
        assertThat(preview.sensitiveAdditions()).extracting(SensitiveAddition::permissionCode).contains("goods:price:view");
        Set<String> before=effective(target);
        assertThatThrownBy(()->transfer.copyPermissions(target,new CopyCommit(request,preview.fingerprint(),List.of())))
                .isInstanceOf(ApiException.class).hasMessageContaining("逐项确认");
        assertThat(effective(target)).isEqualTo(before);
        personal(target,"supplier:view");
        assertThatThrownBy(()->transfer.copyPermissions(target,new CopyCommit(request,preview.fingerprint(),confirmations(preview))))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(effective(target)).doesNotContain("goods:price:view");
    }

    @Test void oneCopiedSnapshotCanBePastedTwiceButAChangedSourceMustBeCopiedAgain() {
        UUID source=account(department(),"连续源"),first=account(department(),"连续甲"),second=account(department(),"连续乙");
        personal(source,"supplier:view");
        var snapshot=transfer.copySnapshot(source);var request=new CopyRequest(source,snapshot.fingerprint());
        for(UUID target:List.of(first,second)) {
            var preview=transfer.previewCopy(target,request);
            assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
            transfer.copyPermissions(target,new CopyCommit(request,preview.fingerprint(),confirmations(preview)));
            assertThat(effective(target)).isEqualTo(effective(source));
        }
        personal(source,"goods:view");
        assertThat(transfer.previewCopy(first,request).canApply()).isFalse();
    }

    @Test void anAlreadyEffectiveSensitiveDelegationStillRequiresConfirmationWhenMadePersonal() {
        UUID source=account(department(),"委派源"),targetDept=department(),target=account(targetDept,"委派目标");
        personal(source,"goods:price:view");
        jdbc.update("""
                INSERT INTO manager_permission_delegations(user_id,permission_id,department_id,enabled,surface_key,granted_by_user_id,
                    target_user_generation,target_employee_generation,target_department_generation,grantor_user_generation,
                    grantor_employee_generation,grantor_auth_version,grantor_authorization_epoch,scope_source)
                SELECT target.id,p.id,d.id,true,'basic.goods',grantor.id,
                    target.permission_delegation_generation,te.permission_delegation_generation,d.permission_delegation_generation,
                    grantor.permission_delegation_generation,NULL,grantor.auth_version,a.epoch,'SUPER_ADMIN'
                FROM users target JOIN employees te ON te.id=target.employee_id JOIN departments d ON d.id=te.department_id
                CROSS JOIN users grantor JOIN employees ge ON ge.id=grantor.employee_id
                CROSS JOIN permissions p CROSS JOIN authorization_state a
                WHERE target.id=? AND grantor.id=? AND p.code='goods:price:view' AND a.singleton_id=1
                """,target,admin);
        assertThat(breakdown(target).managerGrants()).contains("goods:price:view");
        var snapshot=transfer.copySnapshot(source);var request=new CopyRequest(source,snapshot.fingerprint());var preview=transfer.previewCopy(target,request);
        assertThat(preview.changes().getFirst().added()).doesNotContain("goods:price:view");
        assertThat(preview.changes()).anyMatch(change->change.label().contains("授权来源"));
        assertThat(preview.sensitiveAdditions()).extracting(SensitiveAddition::permissionCode).contains("goods:price:view");
        assertThatThrownBy(()->transfer.copyPermissions(target,new CopyCommit(request,preview.fingerprint(),List.of())))
                .isInstanceOf(ApiException.class).hasMessageContaining("逐项确认");
        transfer.copyPermissions(target,new CopyCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND p.code='goods:price:view' AND o.active AND o.effect='grant' AND o.authority_source='SUPER_ADMIN_CONFIRMED'",Long.class,target)).isEqualTo(1);
    }

    @Test void displaySensitivityAndHighRiskNeverCreateASecondGrantPolicy() {
        UUID source=account(department(),"目录规则源"),target=account(department(),"目录规则目标");personal(source,"goods:view");
        var before=jdbc.queryForMap("SELECT sensitivity,high_risk FROM permissions WHERE code='goods:view'");
        try {
            jdbc.update("UPDATE permissions SET sensitivity='SENSITIVE_COMMERCIAL',high_risk=true WHERE code='goods:view'");
            var snapshot=transfer.copySnapshot(source);var request=new CopyRequest(source,snapshot.fingerprint());
            var preview=transfer.previewCopy(target,request);
            assertThat(preview.canApply()).isTrue();
            assertThat(preview.sensitiveAdditions()).extracting(SensitiveAddition::permissionCode).doesNotContain("goods:view");
            transfer.copyPermissions(target,new CopyCommit(request,preview.fingerprint(),confirmations(preview)));
            assertThat(effective(target)).contains("goods:view");
        } finally {
            jdbc.update("UPDATE permissions SET sensitivity=?,high_risk=? WHERE code='goods:view'",before.get("sensitivity"),before.get("high_risk"));
        }
    }

    @Test void crossIdentityImportRequiresExplicitMappingsAndRestoresScopesWithoutTouchingIdentityFlags() throws Exception {
        UUID oldDept=department(),source=account(oldDept,"旧员工"),oldOwnerUser=account(department(),"旧归属人");
        UUID oldOwner=users.findById(oldOwnerUser).orElseThrow().getEmployeeId();
        departmentGrant(oldDept,"goods:view");personal(source,"supplier:view");
        jdbc.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id,created_by) VALUES (?,'client',?,?)",source,oldOwner,admin);
        Backup exported=transfer.exportConfiguration();
        var sourceConfig=exported.users().stream().filter(row->row.key().equals(source.toString())).findFirst().orElseThrow();
        var deptConfig=exported.departments().stream().filter(row->row.key().equals(oldDept.toString())).findFirst().orElseThrow();
        var ownerConfig=exported.scopeOwners().stream().filter(row->row.key().equals(oldOwner.toString())).findFirst().orElseThrow();
        Backup file=new Backup(exported.format(),1,exported.exportedAt(),exported.baseline(),List.of(deptConfig),List.of(sourceConfig),List.of(ownerConfig));
        String json=mapper.writeValueAsString(file);
        assertThat(json).doesNotContain("passwordHash","remoteAccess","superAdmin");
        UUID newDept=department(),target=account(newDept,"新员工"),newOwnerUser=account(department(),"新归属人");
        UUID newOwner=users.findById(newOwnerUser).orElseThrow().getEmployeeId();
        ImportRequest unmatched=new ImportRequest(file,false,List.of(new Mapping(deptConfig.key(),null)),List.of(new Mapping(sourceConfig.key(),null)),true,List.of(new Mapping(ownerConfig.key(),null)));
        assertThat(transfer.previewImport(unmatched).canApply()).isFalse();
        ImportRequest request=new ImportRequest(file,false,List.of(new Mapping(deptConfig.key(),newDept)),List.of(new Mapping(sourceConfig.key(),target)),true,List.of(new Mapping(ownerConfig.key(),newOwner)));
        var preview=transfer.previewImport(request);
        assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        transfer.importConfiguration(new ImportCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(effective(target)).containsExactlyInAnyOrderElementsOf(sourceConfig.effective());
        assertThat(jdbc.queryForList("SELECT owner_employee_id FROM user_data_scopes WHERE user_id=? AND scope='client'",UUID.class,target)).containsExactly(newOwner);
        assertThat(jdbc.queryForMap("SELECT password_hash,is_super_admin,remote_access FROM users WHERE id=?",target))
                .containsEntry("password_hash","x").containsEntry("is_super_admin",false).containsEntry("remote_access",false);
        assertThat(jdbc.queryForList("SELECT p.code FROM department_permissions d JOIN permissions p ON p.id=d.permission_id WHERE d.department_id=?",String.class,newDept))
                .containsExactlyElementsOf(deptConfig.permissions());
    }

    @Test void unknownCodesPinnedBaselineAndDuplicateMappingsAreVisibleBeforeAnyWrite() {
        Backup baseline=transfer.exportConfiguration();
        UUID department=department();
        Backup unknown=new Backup(baseline.format(),1,baseline.exportedAt(),List.of(),
                List.of(new DepartmentConfiguration("source","OTHER","未知",List.of("gone:permission"))),List.of(),List.of());
        var request=new ImportRequest(unknown,true,List.of(new Mapping("source",department)),List.of(),false,List.of());
        var preview=transfer.previewImport(request);
        assertThat(preview.canApply()).isFalse();
        assertThat(preview.issues()).anyMatch(message->message.contains("gone:permission"));
        assertThat(preview.pinnedBaselineAdditions()).contains("notice:read");
        assertThatThrownBy(()->transfer.previewImport(new ImportRequest(unknown,false,List.of(new Mapping("source",department),new Mapping("source",department)),List.of(),false,List.of())))
                .isInstanceOf(ApiException.class).hasMessageContaining("重复");
    }

    @Test void backupIncludesLockedAndInactiveStoredPolicyWithoutReactivatingDisabledAccounts() {
        UUID locked=account(department(),"锁定保留"),disabled=account(department(),"停用保留");
        personal(locked,"goods:view");personal(disabled,"supplier:view");
        jdbc.update("UPDATE users SET status='locked' WHERE id=?",locked);
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?",disabled);
        jdbc.update("UPDATE user_permission_overrides SET active=false,row_version=row_version+1 WHERE user_id=?",disabled);
        Backup backup=transfer.exportConfiguration();
        var lockedRow=backup.users().stream().filter(user->user.key().equals(locked.toString())).findFirst().orElseThrow();
        var disabledRow=backup.users().stream().filter(user->user.key().equals(disabled.toString())).findFirst().orElseThrow();
        assertThat(lockedRow.accountStatus()).isEqualTo("locked");assertThat(lockedRow.restorable()).isTrue();
        assertThat(lockedRow.grants()).contains("goods:view");
        assertThat(disabledRow.restorable()).isFalse();assertThat(disabledRow.restoreReason()).contains("停用");
        assertThat(disabledRow.storedOverrides()).anyMatch(row->row.code().equals("supplier:view") && !row.active());
        UUID target=account(department(),"状态目标");
        assertThat(transfer.previewImport(new ImportRequest(backup,false,List.of(),List.of(new Mapping(disabledRow.key(),target)),false,List.of())).canApply()).isFalse();
        var request=new ImportRequest(backup,false,List.of(),List.of(new Mapping(lockedRow.key(),target)),false,List.of());
        var preview=transfer.previewImport(request);
        assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        transfer.importConfiguration(new ImportCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(effective(target)).contains("goods:view");
        assertThat(jdbc.queryForObject("SELECT status FROM users WHERE id=?",String.class,locked)).isEqualTo("locked");
    }

    @Test void restorePreservesDormantRevokesAndRedundantGrantsAndCopyKeepsUnrelatedRevokes() {
        UUID sourceDept=department(),source=account(sourceDept,"策略源"),targetDept=department(),target=account(targetDept,"策略目标");
        departmentGrant(sourceDept,"goods:view");departmentGrant(targetDept,"goods:view");personal(source,"goods:view");
        revoke(source,"supplier:view");
        Backup backup=transfer.exportConfiguration();
        var request=new ImportRequest(backup,false,List.of(),List.of(new Mapping(source.toString(),target)),false,List.of());
        var preview=transfer.previewImport(request);
        assertThat(preview.changes()).anyMatch(change->change.label().contains("个人覆盖") && !change.added().isEmpty());
        transfer.importConfiguration(new ImportCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(activeEffects(target)).contains("goods:view=grant","supplier:view=revoke");
        var snapshot=transfer.copySnapshot(source);var copy=new CopyRequest(source,snapshot.fingerprint());var copied=transfer.previewCopy(target,copy);
        transfer.copyPermissions(target,new CopyCommit(copy,copied.fingerprint(),confirmations(copied)));
        assertThat(activeEffects(target)).contains("goods:view=grant","supplier:view=revoke");
    }

    @Test void previewDisclosesUnselectedDelegationRecipientsAffectedByGlobalOrGrantorChanges() {
        UUID receiver=account(department(),"全局间接接收人"),changedDepartment=department();delegation(receiver,admin,"goods:price:view");
        assertThat(breakdown(receiver).managerGrants()).contains("goods:price:view");
        Backup exported=transfer.exportConfiguration();
        Backup file=new Backup(exported.format(),1,exported.exportedAt(),exported.baseline(),
                List.of(new DepartmentConfiguration("dept-source","NEW","新部门",List.of("goods:view"))),List.of(),List.of());
        var importRequest=new ImportRequest(file,false,List.of(new Mapping("dept-source",changedDepartment)),List.of(),false,List.of());
        var globalPreview=transfer.previewImport(importRequest);
        assertThat(globalPreview.changes()).anyMatch(change->receiver.equals(change.targetId()) && change.label().contains("委派来源失效") && change.removed().contains("goods:price:view"));

        UUID managed=department(),manager=account(managed,"被粘贴负责人"),staff=account(managed,"负责人间接接收人"),source=account(department(),"普通源");
        personal(manager,"goods:price:view");
        jdbc.update("UPDATE departments SET manager_id=(SELECT employee_id FROM users WHERE id=?) WHERE id=?",manager,managed);
        delegation(staff,manager,"goods:price:view");
        assertThat(breakdown(staff).managerGrants()).contains("goods:price:view");
        var snapshot=transfer.copySnapshot(source);var copyRequest=new CopyRequest(source,snapshot.fingerprint());
        var preview=transfer.previewCopy(manager,copyRequest);
        assertThat(preview.changes()).anyMatch(change->staff.equals(change.targetId()) && change.label().contains("委派来源失效") && change.removed().contains("goods:price:view"));
        transfer.copyPermissions(manager,new CopyCommit(copyRequest,preview.fingerprint(),confirmations(preview)));
        assertThat(breakdown(staff).managerGrants()).doesNotContain("goods:price:view");
    }

    @Test void laterFailureRollsBackEarlierDepartmentAndAuditWrites() {
        UUID dept=department(),target=account(dept,"回滚目标");
        Backup exported=transfer.exportConfiguration();
        var actual=exported.users().stream().filter(user->user.key().equals(target.toString())).findFirst().orElseThrow();
        List<String> expected=new ArrayList<>(actual.effective());expected.add("supplier:view");
        var user=new UserConfiguration("different-user","OTHER","源","source",List.of(),List.of(),expected,List.of(),Map.of());
        Backup file=new Backup(exported.format(),1,exported.exportedAt(),exported.baseline(),
                List.of(new DepartmentConfiguration("different-dept","OTHER","源部门",List.of("goods:view"))),List.of(user),List.of());
        var request=new ImportRequest(file,false,List.of(new Mapping("different-dept",dept)),List.of(new Mapping("different-user",target)),false,List.of());
        jdbc.execute("CREATE FUNCTION public.test_transfer_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'transfer fixture failure'; END $$");
        jdbc.execute("CREATE TRIGGER test_transfer_fail BEFORE INSERT ON user_permission_overrides FOR EACH ROW EXECUTE FUNCTION public.test_transfer_fail()");
        try {
            var preview=transfer.previewImport(request);
            assertThat(preview.canApply()).isTrue();
            assertThatThrownBy(()->transfer.importConfiguration(new ImportCommit(request,preview.fingerprint(),confirmations(preview))))
                    .hasStackTraceContaining("transfer fixture failure");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM department_permissions WHERE department_id=?",Long.class,dept)).isZero();
            assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='department_permission_change' AND target_id=?",Long.class,dept.toString())).isZero();
        } finally {
            jdbc.execute("DROP TRIGGER test_transfer_fail ON user_permission_overrides");jdbc.execute("DROP FUNCTION public.test_transfer_fail()");
        }
    }

    @Test void concurrentAuthorityWriteMakesCommitFailImmediatelyWithoutPartiallyApplying() throws Exception {
        UUID source=account(department(),"并发源"),target=account(department(),"并发目标");personal(source,"goods:view");
        var snapshot=transfer.copySnapshot(source);var request=new CopyRequest(source,snapshot.fingerprint());var preview=transfer.previewCopy(target,request);
        try(Connection connection=DATABASE.createConnection("")) {
            connection.setAutoCommit(false);
            try (var statement = connection.createStatement()) {
                statement.execute("LOCK TABLE users IN ROW EXCLUSIVE MODE");
            }
            assertThatThrownBy(()->transfer.copyPermissions(target,new CopyCommit(request,preview.fingerprint(),confirmations(preview))))
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
            connection.rollback();
        }
        assertThat(effective(target)).doesNotContain("goods:view");
    }

    @Test void anExistingDataScopeEditorIsRefusedBeforeTakingTableLocks() throws Exception {
        UUID target=account(department(),"范围并发");
        Backup backup=transfer.exportConfiguration();
        var request=new ImportRequest(backup,false,List.of(),List.of(new Mapping(target.toString(),target)),true,List.of());
        var preview=transfer.previewImport(request);
        try(Connection connection=DATABASE.createConnection("")) {
            connection.setAutoCommit(false);
            try(var statement=connection.prepareStatement("SELECT pg_advisory_xact_lock(hashtextextended(CAST(? AS text),0))")) {
                statement.setString(1,target+":client");statement.execute();
            }
            assertThatThrownBy(()->transfer.importConfiguration(new ImportCommit(request,preview.fingerprint(),confirmations(preview))))
                    .isInstanceOf(ApiException.class).hasMessageContaining("正在修改数据范围");
            connection.rollback();
        }
    }

    @Test void anExistingBaselineEditorIsRefusedBeforeTakingTableLocks() throws Exception {
        Backup backup=transfer.exportConfiguration();
        var request=new ImportRequest(backup,true,List.of(),List.of(),false,List.of());
        var preview=transfer.previewImport(request);
        try(Connection connection=DATABASE.createConnection("")) {
            connection.setAutoCommit(false);
            try (var statement = connection.createStatement()) {
                statement.execute("SELECT pg_advisory_xact_lock(hashtextextended('PERMISSION_BASELINE',0))");
            }
            assertThatThrownBy(()->transfer.importConfiguration(new ImportCommit(request,preview.fingerprint(),confirmations(preview))))
                    .isInstanceOf(ApiException.class).hasMessageContaining("正在修改全员基础权限");
            connection.rollback();
        }
    }

    private List<String> confirmations(Preview preview){return preview.sensitiveAdditions().stream().map(SensitiveAddition::key).toList();}

    @Test void appliedTemplatesStayBoundAndTemplateEditsPropagateWithoutTouchingPersonalRevokes() {
        UUID dept=department(),target=account(dept,"模板快照"),peer=account(dept,"模板收回");
        var created=templates.create(new PermissionTemplateDtos.Save("模板-"+UUID.randomUUID(),"采购用途",List.of("goods:view"),0L));
        assertThat(created.appliedCount()).isZero();
        assertThat(templates.list()).anyMatch(row->row.id().equals(created.id()) && row.permissions().contains("goods:view"));
        var request=new PermissionTemplateDtos.Apply(created.id(),created.version(),PermissionTemplateDtos.ApplyMode.MERGE);
        var preview=templates.preview(target,request);
        assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        templates.apply(target,new PermissionTemplateDtos.Commit(request,preview.fingerprint(),confirmations(preview)));
        // 绑定记录：最近应用该模板的账号（差量同步的目标集合）。
        assertThat(jdbc.queryForList("SELECT user_id::text FROM user_permission_template_bindings WHERE template_id=?",String.class,created.id()))
                .containsExactly(target.toString());
        assertThat(effective(target)).contains("goods:view");
        // peer 也应用同一模板，但把模板即将新增的码提前个人收回。
        var peerRequest=new PermissionTemplateDtos.Apply(created.id(),created.version(),PermissionTemplateDtos.ApplyMode.MERGE);
        var peerPreview=templates.preview(peer,peerRequest);
        templates.apply(peer,new PermissionTemplateDtos.Commit(peerRequest,peerPreview.fingerprint(),confirmations(peerPreview)));
        revoke(peer,"supplier:view");
        // 模板改为 supplier:view：绑定账号差量跟随；个人收回优先不被覆盖。
        var updated=templates.update(created.id(),new PermissionTemplateDtos.Save(created.name(),"新用途",List.of("supplier:view"),created.version()));
        assertThat(updated.version()).isEqualTo(created.version()+1);
        assertThat(updated.appliedCount()).isEqualTo(2);
        assertThat(templates.list().stream().filter(row->row.id().equals(created.id())).findFirst().orElseThrow().appliedCount()).isEqualTo(2);
        // 模板移除的码：个人加授被清（生效与否取决于基础包/部门继承，不在此断言）。
        assertThat(effective(target)).contains("supplier:view");
        assertThat(activeEffects(target)).doesNotContain("goods:view=grant","supplier:view=grant");
        assertThat(breakdown(target).templatePermissions()).contains("supplier:view");
        assertThat(effective(peer)).doesNotContain("supplier:view");
        assertThat(activeEffects(peer)).contains("supplier:view=revoke");
        assertThatThrownBy(()->templates.update(created.id(),new PermissionTemplateDtos.Save(created.name(),"过期",List.of(),created.version())))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        // 同步写的是中央个人覆盖（不是角色/新授权来源），并留有同步审计。
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='permission_template_sync' AND target_id=?",Long.class,created.id().toString())).isEqualTo(1);
        // 删除模板：解除关联，已应用账号保持当前权限（快照留存的个人覆盖不变）。
        templates.delete(updated.id(),new PermissionTemplateDtos.Delete(updated.version()));
        assertThat(effective(target)).contains("supplier:view");
        assertThat(activeEffects(target)).contains("supplier:view=grant");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM user_permission_template_bindings WHERE template_id=?",Long.class,updated.id())).isZero();
        assertThat(templates.list()).noneMatch(row->row.id().equals(created.id()));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='permission_template_apply' AND target_id=?",Long.class,target.toString())).isEqualTo(1);
    }

    @Test void mergePreservesExistingRightsAndNeverSilentlyRestoresExplicitRevocations() {
        UUID target=account(department(),"模板补充");personal(target,"supplier:view");
        var template=templates.create(new PermissionTemplateDtos.Save("补充-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        var request=new PermissionTemplateDtos.Apply(template.id(),template.version(),PermissionTemplateDtos.ApplyMode.MERGE);
        var preview=templates.preview(target,request);
        assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        templates.apply(target,new PermissionTemplateDtos.Commit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(effective(target)).contains("goods:view","supplier:view");
        UUID revoked=account(department(),"明确收回");revoke(revoked,"goods:view");
        var blocked=templates.preview(revoked,request);
        assertThat(blocked.canApply()).isTrue();
        assertThat(blocked.notes()).anyMatch(message->message.contains("个人收回"));
        templates.apply(revoked,new PermissionTemplateDtos.Commit(request,blocked.fingerprint(),confirmations(blocked)));
        assertThat(effective(revoked)).doesNotContain("goods:view");
        assertThat(activeEffects(revoked)).contains("goods:view=revoke");
    }

    @Test void replacementChangesDirectSettingsAndKeepsInheritedSourcesAndExplicitPersonalRevokes() {
        UUID dept=department(),target=account(dept,"模板覆盖");departmentGrant(dept,"supplier:view");revoke(target,"goods:view");
        var template=templates.create(new PermissionTemplateDtos.Save("覆盖-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        var request=new PermissionTemplateDtos.Apply(template.id(),template.version(),PermissionTemplateDtos.ApplyMode.REPLACE);
        var preview=templates.preview(target,request);
        assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        assertThat(preview.changes().getFirst().removed()).doesNotContain("supplier:view");
        templates.apply(target,new PermissionTemplateDtos.Commit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(effective(target)).contains("supplier:view").doesNotContain("goods:view");
        assertThat(activeEffects(target)).contains("goods:view=revoke").doesNotContain("supplier:view=revoke","goods:view=grant");
        assertThat(breakdown(target).templatePermissions()).contains("goods:view");
    }

    @Test void templateSensitiveRightsRequirePerEmployeeReviewAndStaleAuthorityOrTemplateNeverWrites() {
        UUID target=account(department(),"模板敏感");
        var template=templates.create(new PermissionTemplateDtos.Save("敏感-"+UUID.randomUUID(),"",List.of("goods:price:view"),0L));
        var request=new PermissionTemplateDtos.Apply(template.id(),template.version(),PermissionTemplateDtos.ApplyMode.MERGE);
        var preview=templates.preview(target,request);
        assertThat(preview.sensitiveAdditions()).extracting(SensitiveAddition::permissionCode).contains("goods:price:view");
        assertThatThrownBy(()->templates.apply(target,new PermissionTemplateDtos.Commit(request,preview.fingerprint(),List.of())))
                .isInstanceOf(ApiException.class).hasMessageContaining("逐项确认");
        personal(target,"supplier:view");
        assertThatThrownBy(()->templates.apply(target,new PermissionTemplateDtos.Commit(request,preview.fingerprint(),confirmations(preview))))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        var fresh=templates.preview(target,request);
        templates.update(template.id(),new PermissionTemplateDtos.Save(template.name(),"变化",template.permissions(),template.version()));
        assertThatThrownBy(()->templates.apply(target,new PermissionTemplateDtos.Commit(request,fresh.fingerprint(),confirmations(fresh))))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(effective(target)).doesNotContain("goods:price:view");
    }

    @Test void templateRejectsUnknownAndSuperadminOnlyCodesAndInvalidTargets() {
        assertThatThrownBy(()->templates.create(new PermissionTemplateDtos.Save("未知-"+UUID.randomUUID(),"",List.of("nonexistent:permission"),0L)))
                .isInstanceOf(ApiException.class).hasMessageContaining("不存在");
        String restricted=jdbc.queryForObject("SELECT code FROM permissions WHERE 'SUPERADMIN_ONLY'=ANY(grant_policy) ORDER BY code LIMIT 1",String.class);
        assertThatThrownBy(()->templates.create(new PermissionTemplateDtos.Save("超管-"+UUID.randomUUID(),"",List.of(restricted),0L))).isInstanceOf(ApiException.class);
        var template=templates.create(new PermissionTemplateDtos.Save("目标校验-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        var request=new PermissionTemplateDtos.Apply(template.id(),template.version(),PermissionTemplateDtos.ApplyMode.MERGE);
        assertThat(templates.preview(admin,request).canApply()).isFalse();
        UUID disabled=account(department(),"停用模板目标");jdbc.update("UPDATE users SET status='disabled' WHERE id=?",disabled);
        assertThat(templates.preview(disabled,request).canApply()).isFalse();
        UUID ordinary=account(department(),"普通操作者");var account=users.findById(ordinary).orElseThrow();
        AuthUser principal=new AuthUser(ordinary,account.getEmployeeId(),account.getLoginAccount(),Set.of("authorization:manage"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities()));
        assertThatThrownBy(()->templates.list()).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
    }

    @Test void deletingATemplateOrConcurrentTemplateEditorInvalidatesApplication() throws Exception {
        UUID target=account(department(),"模板并发");
        var template=templates.create(new PermissionTemplateDtos.Save("并发-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        var request=new PermissionTemplateDtos.Apply(template.id(),template.version(),PermissionTemplateDtos.ApplyMode.MERGE);
        var preview=templates.preview(target,request);
        try(Connection connection=DATABASE.createConnection("")) {
            connection.setAutoCommit(false);
            try(var statement=connection.prepareStatement("SELECT id FROM permission_templates WHERE id=? FOR UPDATE")) { statement.setObject(1,template.id());statement.execute(); }
            assertThatThrownBy(()->templates.apply(target,new PermissionTemplateDtos.Commit(request,preview.fingerprint(),confirmations(preview))))
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
            connection.rollback();
        }
        assertThat(effective(target)).doesNotContain("goods:view");
        templates.delete(template.id(),new PermissionTemplateDtos.Delete(template.version()));
        assertThatThrownBy(()->templates.apply(target,new PermissionTemplateDtos.Commit(request,preview.fingerprint(),confirmations(preview))))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
    }
    @Test void independentTemplateRemovalPreservesManualGrantsAndRefreshesAuthority() {
        UUID target=account(department(),"独立来源");personal(target,"goods:view");
        var template=templates.create(new PermissionTemplateDtos.Save("独立-"+UUID.randomUUID(),"",List.of("goods:view","supplier:view"),0L));
        applyTemplate(template,List.of(target),List.of());
        assertThat(activeEffects(target)).contains("goods:view=grant").doesNotContain("supplier:view=grant");
        long epoch=jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class);
        templates.update(template.id(),new PermissionTemplateDtos.Save(template.name(),"",List.of("client:view"),template.version()));
        assertThat(effective(target)).contains("goods:view","client:view").doesNotContain("supplier:view");
        assertThat(jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class)).isGreaterThan(epoch);
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?",target);
        var current=templates.list().stream().filter(row->row.id().equals(template.id())).findFirst().orElseThrow();
        templates.update(current.id(),new PermissionTemplateDtos.Save(current.name(),"",List.of("supplier:view"),current.version()));
        jdbc.update("UPDATE users SET status='active' WHERE id=?",target);
        assertThat(effective(target)).contains("goods:view","supplier:view").doesNotContain("client:view");
    }

    @Test void departmentTemplateTracksExistingFutureAndSecondaryMembersAndRespectsIndividualRevokes() {
        UUID dept=department(),child=department();jdbc.update("UPDATE departments SET parent_id=? WHERE id=?",dept,child);
        UUID primary=account(child,"部门继承"),secondary=account(department(),"兼职继承"),denied=account(dept,"个人收回");
        jdbc.update("INSERT INTO employee_secondary_departments(employee_id,department_id) SELECT employee_id,? FROM users WHERE id=?",dept,secondary);
        revoke(denied,"goods:view");
        var template=templates.create(new PermissionTemplateDtos.Save("部门关联-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        applyTemplate(template,List.of(),List.of(dept));
        assertThat(effective(primary)).contains("goods:view");assertThat(effective(secondary)).contains("goods:view");assertThat(effective(denied)).doesNotContain("goods:view");
        UUID future=account(dept,"新入职");assertThat(effective(future)).contains("goods:view");
        templates.update(template.id(),new PermissionTemplateDtos.Save(template.name(),"",List.of("supplier:view"),template.version()));
        for(UUID user:List.of(primary,secondary,denied,future)) assertThat(effective(user)).contains("supplier:view").doesNotContain("goods:view");
        var listed=templates.list().stream().filter(row->row.id().equals(template.id())).findFirst().orElseThrow();
        assertThat(listed.appliedDepartmentCount()).isEqualTo(1);assertThat(listed.appliedUserCount()).isZero();
        String individual=jdbc.queryForObject("SELECT code FROM permissions WHERE 'INDIVIDUAL_ONLY'=ANY(grant_policy) ORDER BY code LIMIT 1",String.class);
        assertThatThrownBy(()->templates.update(listed.id(),new PermissionTemplateDtos.Save(listed.name(),"",List.of(individual),listed.version())))
                .isInstanceOf(ApiException.class).hasMessageContaining("已关联部门");
    }

    @Test void multiEmployeeAndDepartmentTemplateApplicationIsAtomicAndRejectsStaleOrSensitiveUnreviewedWrites() {
        UUID first=account(department(),"批量一"),second=account(department(),"批量二"),dept=department();
        var template=templates.create(new PermissionTemplateDtos.Save("批量-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        var request=new PermissionTemplateDtos.BatchApply(template.id(),template.version(),PermissionTemplateDtos.ApplyMode.MERGE,List.of(first,second),List.of(dept));
        var preview=assignments.preview(request);assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        assignments.apply(new PermissionTemplateDtos.BatchCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(effective(first)).contains("goods:view");assertThat(effective(second)).contains("goods:view");
        assertThat(assignments.bindings()).filteredOn(binding->binding.templateId().equals(template.id())).hasSize(3);
        var stale=assignments.preview(request);personal(second,"supplier:view");
        assertThatThrownBy(()->assignments.apply(new PermissionTemplateDtos.BatchCommit(request,stale.fingerprint(),confirmations(stale))))
                .isInstanceOf(ApiException.class).hasMessageContaining("已变化");
        UUID invalid=account(department(),"停用目标");jdbc.update("UPDATE users SET status='disabled' WHERE id=?",invalid);
        var blockedRequest=new PermissionTemplateDtos.BatchApply(template.id(),template.version(),PermissionTemplateDtos.ApplyMode.MERGE,List.of(account(department(),"未提交"),invalid),List.of());
        var blocked=assignments.preview(blockedRequest);assertThat(blocked.canApply()).isFalse();
        assertThatThrownBy(()->assignments.apply(new PermissionTemplateDtos.BatchCommit(blockedRequest,blocked.fingerprint(),confirmations(blocked)))).isInstanceOf(ApiException.class);
        assertThat(assignments.bindings()).noneMatch(binding->binding.targetId().equals(blockedRequest.userIds().getFirst()));
    }

    @Test void incrementalBatchPreservesOtherRightsAndPersonalRevokeOverridesLinkedTemplateAndBaseline() {
        UUID first=account(department(),"增量一"),second=account(department(),"增量二");personal(first,"supplier:view");
        var template=templates.create(new PermissionTemplateDtos.Save("增量模板-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        applyTemplate(template,List.of(first,second),List.of());
        var request=new PermissionTemplateDtos.DeltaRequest(List.of(first,second),List.of(),List.of("client:view"),List.of("goods:view"));
        var preview=assignments.previewDelta(request);assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        assignments.applyDelta(new PermissionTemplateDtos.DeltaCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(effective(first)).contains("supplier:view","client:view").doesNotContain("goods:view");
        assertThat(effective(second)).contains("client:view").doesNotContain("goods:view");
        assertThat(assignments.bindings()).filteredOn(binding->binding.templateId().equals(template.id())).hasSize(2);
        jdbc.update("UPDATE permissions SET baseline=true WHERE code='goods:view'");
        try { assertThat(effective(first)).doesNotContain("goods:view");assertThat(effective(second)).doesNotContain("goods:view"); }
        finally { jdbc.update("UPDATE permissions SET baseline=false WHERE code='goods:view'"); }
    }

    @Test void unbindingFreezesLiveSourcesAndSamePermissionCopyDetachesTheRelationship() {
        UUID target=account(department(),"解绑"),source=account(department(),"同权复制"),dept=department();personal(source,"goods:view");
        var template=templates.create(new PermissionTemplateDtos.Save("解绑模板-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        applyTemplate(template,List.of(target),List.of(dept));
        var result=unbind(List.of(),List.of(dept));assertThat(result.changed()).isTrue();
        assertThat(jdbc.queryForList("SELECT p.code FROM department_permissions d JOIN permissions p ON p.id=d.permission_id WHERE d.department_id=?",String.class,dept)).contains("goods:view");
        var snapshot=transfer.copySnapshot(source);var request=new CopyRequest(source,snapshot.fingerprint());var preview=transfer.previewCopy(target,request);
        transfer.copyPermissions(target,new CopyCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(assignments.bindings()).noneMatch(binding->binding.targetId().equals(target));
        assertThat(effective(target)).contains("goods:view");
    }

    @Test void legacySnapshotIsExplicitAndNeverReclassifiedOrAutomaticallyReplayed() {
        UUID target=account(department(),"旧快照");personal(target,"goods:view");
        var template=templates.create(new PermissionTemplateDtos.Save("旧模板-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        jdbc.update("INSERT INTO permission_template_applies(user_id,template_id,applied_version,applied_by) VALUES (?,?,?,?)",target,template.id(),template.version(),admin);
        assertThat(assignments.bindings()).anyMatch(binding->binding.targetId().equals(target) && binding.legacySnapshot());
        var updated=templates.update(template.id(),new PermissionTemplateDtos.Save(template.name(),"",List.of("supplier:view"),template.version()));
        assertThat(activeEffects(target)).contains("goods:view=grant").doesNotContain("supplier:view=grant");
        applyTemplate(updated,List.of(target),List.of());
        assertThat(assignments.bindings()).anyMatch(binding->binding.targetId().equals(target) && !binding.legacySnapshot());
        assertThat(effective(target)).contains("goods:view","supplier:view");
    }

    @Test void addingSensitivePermissionsToLinkedTemplatesRequiresServerVerifiedConfirmation() {
        UUID target=account(department(),"模板敏感变更");
        var template=templates.create(new PermissionTemplateDtos.Save("保存敏感-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        applyTemplate(template,List.of(target),List.of());
        assertThatThrownBy(()->templates.update(template.id(),new PermissionTemplateDtos.Save(template.name(),"",List.of("goods:view","goods:price:view"),template.version())))
                .isInstanceOf(ApiException.class).hasMessageContaining("逐项确认");
        assertThat(effective(target)).doesNotContain("goods:price:view");
        templates.update(template.id(),new PermissionTemplateDtos.Save(template.name(),"",List.of("goods:view","goods:price:view"),template.version(),List.of("goods:price:view")));
        assertThat(effective(target)).contains("goods:price:view");
    }

    @Test void restoringTemplateBackedSnapshotsMaterializesTheirCurrentCodesAndDetachesDestinationBindings() {
        UUID sourceDept=department(),targetDept=department(),source=account(sourceDept,"模板备份源"),target=account(targetDept,"模板备份目标");
        var template=templates.create(new PermissionTemplateDtos.Save("备份模板-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        applyTemplate(template,List.of(source,target),List.of(sourceDept,targetDept));
        Backup backup=transfer.exportConfiguration();
        var request=new ImportRequest(backup,false,List.of(new Mapping(sourceDept.toString(),targetDept)),List.of(new Mapping(source.toString(),target)),false,List.of());
        var preview=transfer.previewImport(request);assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        transfer.importConfiguration(new ImportCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(effective(target)).contains("goods:view");
        assertThat(assignments.bindings()).noneMatch(binding->binding.targetId().equals(target) || binding.targetId().equals(targetDept));
        templates.update(template.id(),new PermissionTemplateDtos.Save(template.name(),"",List.of("supplier:view"),template.version()));
        assertThat(effective(source)).contains("supplier:view");assertThat(effective(target)).contains("goods:view").doesNotContain("supplier:view");
    }

    @Test void deletingTemplateWithDisabledMemberFreezesTheConfigurationAndDoesNotBlockDeletion() {
        UUID target=account(department(),"停用关联");
        var template=templates.create(new PermissionTemplateDtos.Save("停用解绑-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        applyTemplate(template,List.of(target),List.of());
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?",target);
        templates.delete(template.id(),new PermissionTemplateDtos.Delete(template.version()));
        assertThat(assignments.bindings()).noneMatch(binding->binding.templateId().equals(template.id()));
        assertThat(activeEffects(target)).contains("goods:view=grant");
        jdbc.update("UPDATE users SET status='active' WHERE id=?",target);assertThat(effective(target)).contains("goods:view");
    }

    @Test void pagePermissionDrawerAndSystemPermissionsShareTheIndependentTemplateSourceAndPersonalRevoke() {
        UUID dept=department(),target=account(dept,"页面模板来源");
        UUID employee=users.findById(target).orElseThrow().getEmployeeId();
        var template=templates.create(new PermissionTemplateDtos.Save("页面模板-"+UUID.randomUUID(),"",List.of("goods:cost:view"),0L));
        applyTemplate(template,List.of(target),List.of());
        var first=pagePermissions.employeePermissions(employee,dept,"basic.goods").groups().stream()
                .flatMap(group->group.permissions().stream()).filter(permission->permission.code().equals("goods:cost:view")).findFirst().orElseThrow();
        assertThat(first.effective()).isTrue();assertThat(first.targetBaseEffective()).isTrue();assertThat(first.configuredEffect()).isNull();
        assertThat(breakdown(target).templatePermissions()).contains("goods:cost:view");
        revoke(target,"goods:cost:view");
        var second=pagePermissions.employeePermissions(employee,dept,"basic.goods").groups().stream()
                .flatMap(group->group.permissions().stream()).filter(permission->permission.code().equals("goods:cost:view")).findFirst().orElseThrow();
        assertThat(second.effective()).isFalse();assertThat(second.configuredEffect()).isEqualTo("revoke");
        assertThat(effective(target)).doesNotContain("goods:cost:view");
    }

    @Test void repeatedIdenticalTemplateApplicationDoesNotInvalidateUnrelatedAuthority() {
        UUID target=account(department(),"重复关联"),dept=department();
        var template=templates.create(new PermissionTemplateDtos.Save("无改动模板-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        applyTemplate(template,List.of(target),List.of(dept));
        long epoch=jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class);
        long version=jdbc.queryForObject("SELECT auth_version FROM users WHERE id=?",Long.class,target);
        var request=new PermissionTemplateDtos.BatchApply(template.id(),template.version(),PermissionTemplateDtos.ApplyMode.MERGE,List.of(target),List.of(dept));
        var preview=assignments.preview(request);
        assertThat(assignments.apply(new PermissionTemplateDtos.BatchCommit(request,preview.fingerprint(),confirmations(preview))).changed()).isFalse();
        assertThat(jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class)).isEqualTo(epoch);
        assertThat(jdbc.queryForObject("SELECT auth_version FROM users WHERE id=?",Long.class,target)).isEqualTo(version);
    }

    @Test void templateBindingDoesNotReconfirmUnrelatedLegacyOverridesOrMakeThemRedelegable() {
        UUID target=account(department(),"历史来源保全");personal(target,"supplier:view");
        jdbc.update("UPDATE user_permission_overrides SET authority_source='LEGACY_UNKNOWN',source_actor_user_id=null WHERE user_id=?",target);
        var template=templates.create(new PermissionTemplateDtos.Save("保留来源-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        applyTemplate(template,List.of(target),List.of());
        assertThat(breakdown(target).legacyUnknownGrants()).contains("supplier:view");
        assertThat(breakdown(target).confirmedGrants()).doesNotContain("supplier:view");
        unbind(List.of(target),List.of());
        assertThat(breakdown(target).legacyUnknownGrants()).contains("supplier:view");
        assertThat(breakdown(target).confirmedGrants()).contains("goods:view").doesNotContain("supplier:view");
    }

    @Test void simultaneousParentAndChildDepartmentRevocationUsesTheSamePlannedHierarchy() {
        UUID parent=department(),child=department();jdbc.update("UPDATE departments SET parent_id=? WHERE id=?",parent,child);
        UUID target=account(child,"父子部门批量");departmentGrant(parent,"goods:view");
        assertThat(effective(target)).contains("goods:view");
        var request=new PermissionTemplateDtos.DeltaRequest(List.of(),List.of(parent,child),List.of(),List.of("goods:view"));
        var preview=assignments.previewDelta(request);assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        assignments.applyDelta(new PermissionTemplateDtos.DeltaCommit(request,preview.fingerprint(),confirmations(preview)));
        assertThat(effective(target)).doesNotContain("goods:view");
    }

    @Test void unattendedServerAuthorityUsesLiveIndividualTemplateSourcesAndAlwaysHonorsPersonalRevocation() {
        UUID target=account(department(),"模板运维授权");assertThat(serverAuthority.mayUpdate(target)).isFalse();
        var template=templates.create(new PermissionTemplateDtos.Save("运维模板-"+UUID.randomUUID(),"",List.of("server:update"),0L));
        applyTemplate(template,List.of(target),List.of());
        assertThat(serverAuthority.mayUpdate(target)).isTrue();assertThat(serverAuthority.currentUpdaters()).contains(target);
        revoke(target,"server:update");
        assertThat(serverAuthority.mayUpdate(target)).isFalse();assertThat(serverAuthority.currentUpdaters()).doesNotContain(target);
    }

    @Test void staleUnbindCannotRemoveANewerTemplateRelationshipAndMissingConfirmationNeverWrites() {
        UUID target=account(department(),"并发解绑");
        var first=templates.create(new PermissionTemplateDtos.Save("解绑A-"+UUID.randomUUID(),"",List.of("goods:view"),0L));
        var second=templates.create(new PermissionTemplateDtos.Save("解绑B-"+UUID.randomUUID(),"",List.of("supplier:view"),0L));
        applyTemplate(first,List.of(target),List.of());
        var seen=assignments.bindings().stream().filter(binding->binding.targetId().equals(target)).findFirst().orElseThrow();
        var oldRequest=new PermissionTemplateDtos.Unbind(List.of(target),List.of(),List.of(expectedBinding(seen)));
        applyTemplate(second,List.of(target),List.of());
        long auditBefore=jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='permission_template_unbind' AND target_id=?",Long.class,target.toString());
        assertThatThrownBy(()->assignments.unbind(oldRequest)).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThatThrownBy(()->assignments.unbind(new PermissionTemplateDtos.Unbind(List.of(target),List.of(),null))).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(assignments.bindings()).anyMatch(binding->binding.targetId().equals(target) && binding.templateId().equals(second.id()));
        assertThat(effective(target)).contains("supplier:view");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='permission_template_unbind' AND target_id=?",Long.class,target.toString())).isEqualTo(auditBefore);
        var beforeEdit=assignments.bindings().stream().filter(binding->binding.targetId().equals(target)).findFirst().orElseThrow();
        templates.update(second.id(),new PermissionTemplateDtos.Save(second.name(),"",List.of("supplier:view","client:view"),second.version()));
        assertThatThrownBy(()->assignments.unbind(new PermissionTemplateDtos.Unbind(List.of(target),List.of(),List.of(expectedBinding(beforeEdit)))))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(unbind(List.of(target),List.of()).changed()).isTrue();
    }

    private PermissionTemplateDtos.ExpectedBinding expectedBinding(PermissionTemplateDtos.Binding binding) {
        return new PermissionTemplateDtos.ExpectedBinding(binding.kind(),binding.targetId(),binding.templateId(),binding.templateVersion(),binding.legacySnapshot());
    }
    private Result unbind(List<UUID> users,List<UUID> departments) {
        var expected=assignments.bindings().stream().filter(binding->binding.kind().equals("user")
                ? users.contains(binding.targetId()):departments.contains(binding.targetId())).map(this::expectedBinding).toList();
        return assignments.unbind(new PermissionTemplateDtos.Unbind(users,departments,expected));
    }

    private void applyTemplate(PermissionTemplateDtos.Template template,List<UUID> users,List<UUID> departments) {
        var request=new PermissionTemplateDtos.BatchApply(template.id(),template.version(),PermissionTemplateDtos.ApplyMode.MERGE,users,departments);
        var preview=assignments.preview(request);assertThat(preview.canApply()).as(preview.issues().toString()).isTrue();
        assignments.apply(new PermissionTemplateDtos.BatchCommit(request,preview.fingerprint(),confirmations(preview)));
    }

    private PermissionResolver.PermBreakdown breakdown(UUID user){
        return new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                .execute(status->resolver.breakdownOf(users.findById(user).orElseThrow()));
    }
    private Set<String> effective(UUID user){return breakdown(user).effective();}
    private UUID department(){
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO departments(id,code,name,level) VALUES (?,?,?,'一级部门')",id,"TR-"+id,"同名部门");return id;
    }
    private UUID account(UUID department,String name){
        UUID employee=UUID.randomUUID(),user=UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES (?,?,?,'其他',?,current_date,'active','regular')",employee,"TE-"+employee,name,department);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES (?,?,?,'x',false,false,'active')",user,employee,"tu-"+user);
        return user;
    }
    private void departmentGrant(UUID department,String code){jdbc.update("INSERT INTO department_permissions(department_id,permission_id,created_by) SELECT ?,id,? FROM permissions WHERE code=?",department,admin,code);}
    private void personal(UUID user,String code){jdbc.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect,active,authority_source,source_actor_user_id,row_version) SELECT ?,id,'grant',true,'SUPER_ADMIN_CONFIRMED',?,1 FROM permissions WHERE code=?",user,admin,code);}
    private void revoke(UUID user,String code){jdbc.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect,active,authority_source,source_actor_user_id,row_version) SELECT ?,id,'revoke',true,'SUPER_ADMIN_CONFIRMED',?,1 FROM permissions WHERE code=?",user,admin,code);}
    private List<String> activeEffects(UUID user){return jdbc.queryForList("SELECT p.code||'='||o.effect FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND o.active ORDER BY p.code",String.class,user);}
    private void delegation(UUID target,UUID grantor,String code){
        jdbc.update("""
                INSERT INTO manager_permission_delegations(user_id,permission_id,department_id,enabled,surface_key,granted_by_user_id,
                    target_user_generation,target_employee_generation,target_department_generation,grantor_user_generation,
                    grantor_employee_generation,grantor_auth_version,grantor_authorization_epoch,scope_source,scope_department_id,scope_generation)
                SELECT target.id,p.id,d.id,true,'basic.goods',grantor.id,
                    target.permission_delegation_generation,te.permission_delegation_generation,d.permission_delegation_generation,
                    grantor.permission_delegation_generation,CASE WHEN grantor.is_super_admin THEN NULL ELSE ge.permission_delegation_generation END,
                    grantor.auth_version,a.epoch,CASE WHEN grantor.is_super_admin THEN 'SUPER_ADMIN' ELSE 'DEPARTMENT_MANAGER' END,
                    CASE WHEN grantor.is_super_admin THEN NULL ELSE d.id END,
                    CASE WHEN grantor.is_super_admin THEN NULL ELSE d.permission_delegation_generation END
                FROM users target JOIN employees te ON te.id=target.employee_id JOIN departments d ON d.id=te.department_id
                CROSS JOIN users grantor JOIN employees ge ON ge.id=grantor.employee_id
                CROSS JOIN permissions p CROSS JOIN authorization_state a
                WHERE target.id=? AND grantor.id=? AND p.code=? AND a.singleton_id=1
                """,target,grantor,code);
    }
}
