package com.uten.imp.responsibility;

import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.admin.DataScopeAdminService;
import com.uten.imp.features.org.employee.EmployeeCommandService;
import com.uten.imp.features.org.employee.dto.OffboardRequest;
import com.uten.imp.responsibility.dto.DataHandoverRequest;
import com.uten.imp.responsibility.dto.DataHandoverResult;
import com.uten.imp.security.AuthUser;
import com.uten.imp.features.auth.PermissionResolver;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.storage.uploads-enabled=true",
                "uten.storage.malware-scan.provider=test-only",
                "uten.jwt.secret=handover-postgres-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=handover-postgres-pgp-key-test-only-0123456789",
                "uten.crypto.hmac-key=handover-postgres-hmac-key-test-only",
                "uten.bootstrap.admin-login=handover-bootstrap-admin-test",
                "uten.bootstrap.admin-password=HarnessAdminPass-1!"
        })
class DataHandoverPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");
    private static final AtomicInteger SEQUENCE = new AtomicInteger(700000);

    @DynamicPropertySource
    static void dataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        try {
            var storage = java.nio.file.Files.createTempDirectory("uten-handover-test-");
            registry.add("uten.storage.local-dir", storage::toString);
        } catch (java.io.IOException error) {
            throw new IllegalStateException(error);
        }
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired private JdbcTemplate jdbc;
    @Autowired private EntityManagerFactory entityManagerFactory;
    @Autowired private DocNumberService docNumberService;
    @Autowired private PermissionResolver permissionResolver;
    @Autowired private DataHandoverService handovers;
    @Autowired private com.uten.imp.security.EmployeeHandoverVisibility handoverVisibility;
    @Autowired private com.uten.imp.security.OwnerVisibility ownerVisibility;
    @Autowired private DataScopeAdminService dataScopes;
    @Autowired private DataHandoverCandidateService candidates;
    @Autowired private EmployeeCommandService employees;

    @AfterEach
    void clearAuthentication() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void staleWholeAccountSaveCannotOverwriteOffboardingFinalState() {
        UUID department = departmentId();
        Staff source = staff("account-cas", department, "active", false, false);
        var stale = entityManagerFactory.createEntityManager();
        var departure = entityManagerFactory.createEntityManager();
        try {
            stale.getTransaction().begin();
            UserAccount staleAccount = stale.find(UserAccount.class, source.userId());
            assertEquals(0L, staleAccount.getVersion());

            departure.getTransaction().begin();
            UserAccount departing = departure.find(UserAccount.class, source.userId());
            departing.setStatus("disabled");
            departing.setRemoteAccess(false);
            departing.setMustChangePassword(true);
            departing.setTempPasswordExpiresAt(null);
            departure.getTransaction().commit();

            staleAccount.setRemoteAccess(true);
            staleAccount.setStatus("active");
            staleAccount.setMustChangePassword(false);
            staleAccount.setLastLoginAt(OffsetDateTime.now());
            RuntimeException conflict = assertThrows(
                    RuntimeException.class, stale.getTransaction()::commit);
            assertTrue(hasCause(conflict, jakarta.persistence.OptimisticLockException.class)
                            || hasCause(conflict,
                            org.hibernate.StaleObjectStateException.class),
                    "stale UserAccount write must fail through JPA version CAS");
        } finally {
            if (stale.getTransaction().isActive()) stale.getTransaction().rollback();
            if (departure.getTransaction().isActive()) departure.getTransaction().rollback();
            stale.close();
            departure.close();
        }

        Map<String, Object> finalState = jdbc.queryForMap("""
                SELECT status, remote_access, must_change_password,
                       temp_password_expires_at, version
                FROM users WHERE id=?
                """, source.userId());
        assertEquals("disabled", finalState.get("status"));
        assertEquals(false, finalState.get("remote_access"));
        assertEquals(true, finalState.get("must_change_password"));
        assertEquals(null, finalState.get("temp_password_expires_at"));
        assertEquals(1L, ((Number) finalState.get("version")).longValue());
    }

    @Test
    void clientScopeExpandsOnlyToTransferredClientsAndReplayIsCountStable() {
        loginAsSuperAdministrator();
        UUID department = departmentId();
        Staff source = staff("client-a", department, "active", false, false);
        Staff target = staff("client-b", department, "active", false, true);
        Staff viewer = staff("client-c", department, "active", false, true);
        Staff alreadyVisible = staff("client-f", department, "active", false, true);
        Staff disabledViewer = staff("client-e", department, "active", false, true);

        UUID targetOriginalClient = client("target-original", target.employeeId());
        UUID sourceClient1 = client("source-1", source.employeeId());
        UUID sourceClient2 = client("source-2", source.employeeId());
        grantOwnerScope(viewer.userId(), "client", source.employeeId());
        grantOwnerScope(alreadyVisible.userId(), "client", source.employeeId());
        grantOwnerScope(disabledViewer.userId(), "client", source.employeeId());
        grantOwnerScope(viewer.userId(), "sales", source.employeeId());
        jdbc.update("update users set status='disabled' where id=?", disabledViewer.userId());

        var targetCandidates = candidates.search("target", "client-e", 1, 20);
        var sourceCandidates = candidates.search("source", "client-e", 1, 20);
        assertEquals(0, targetCandidates.total());
        assertEquals(1, sourceCandidates.total());
        assertEquals(disabledViewer.employeeId(),
                sourceCandidates.items().getFirst().employeeId());

        // Existing active and revoked rows prove ON CONFLICT does not duplicate and reactivation works.
        insertViewer(sourceClient1, alreadyVisible.employeeId(), true);
        insertViewer(sourceClient1, viewer.employeeId(), false);

        var preview = handovers.preview(
                source.employeeId(), target.employeeId(), Set.of("client"));
        assertEquals(5, preview.transferCount()); // 2 owners + 3 source-scope rows
        assertEquals(5, preview.total());
        assertEquals(preview.total(), preview.transferCount()
                + preview.historyAccessCount() + preview.releaseCount()
                + preview.blockingCount());

        UUID requestId = UUID.randomUUID();
        String reason = "客户负责人交接" + "理".repeat(1100);
        DataHandoverRequest request = new DataHandoverRequest(
                requestId, source.employeeId(), target.employeeId(),
                Set.of("client"), reason, BusinessTime.today());
        DataHandoverResult first = handovers.executeManual(request);

        assertFalse(first.replayed());
        assertEquals(2L, first.resultSummary().get("client.owner"));
        assertEquals(3L, first.resultSummary().get("client.scopeDelegations"));
        assertEquals(5L, first.resultSummary().get("total"));
        assertEquals(2, count("select count(*) from clients where id in (?,?) and owner_employee_id=?",
                sourceClient1, sourceClient2, target.employeeId()));
        assertEquals(2, activeViewerClientCount(viewer.employeeId(), sourceClient1, sourceClient2));
        assertEquals(2, activeViewerClientCount(alreadyVisible.employeeId(), sourceClient1, sourceClient2));
        assertEquals(2, activeViewerClientCount(source.employeeId(), sourceClient1, sourceClient2));
        assertEquals(0, activeViewerClientCount(disabledViewer.employeeId(), sourceClient1, sourceClient2));
        assertEquals(0, activeViewerClientCount(viewer.employeeId(), targetOriginalClient));
        assertEquals(0, count("select count(*) from user_data_scopes where owner_employee_id=? and scope='client'",
                source.employeeId()));
        assertEquals(1, count("select count(*) from user_data_scopes where user_id=? and owner_employee_id=? and scope='sales'",
                viewer.userId(), source.employeeId()));
        assertEquals(2, count("select count(*) from client_access_change_events where client_id in (?,?)",
                sourceClient1, sourceClient2));
        assertEquals(2, count("select count(*) from clients where id in (?,?) and access_version=1",
                sourceClient1, sourceClient2));
        assertEquals(2, count("""
                select count(*) from client_access_change_events
                where client_id in (?,?) and ?=any(new_viewer_ids)
                  and ?=any(new_viewer_ids) and ?=any(new_viewer_ids)
                  and not (?=any(new_viewer_ids))
                """, sourceClient1, sourceClient2,
                source.employeeId(), viewer.employeeId(), alreadyVisible.employeeId(),
                target.employeeId()));
        assertEquals(1, count("select count(*) from employee_data_handover_scopes where handover_id=? and scope='client'",
                first.id()));

        DataHandoverResult replay = handovers.executeManual(request);
        assertTrue(replay.replayed());
        assertEquals(first.resultSummary(), replay.resultSummary());
        assertEquals(2, count("select count(*) from client_access_change_events where client_id in (?,?)",
                sourceClient1, sourceClient2));
        assertThrows(ApiException.class, () -> handovers.executeManual(
                new DataHandoverRequest(requestId, source.employeeId(), target.employeeId(),
                        Set.of("sales"), reason, BusinessTime.today())));
    }

    @Test
    void releaseOnlyWholePersonBatchDoesNotCreateEightVisibilityEdges() {
        loginAsSuperAdministrator();
        UUID department = departmentId();
        Staff source = staff("claim-a", department, "active", false, true);
        Staff target = staff("claim-b", department, "active", false, true);
        jdbc.update("""
                insert into task_claims(target_type,target_key,claimed_by,lease_until)
                values ('HANDOVER_TEST',?,?,now()+interval '1 hour')
                """, UUID.randomUUID().toString(), source.employeeId());

        LinkedHashSet<String> allScopes = new LinkedHashSet<>(DataHandoverService.ALL_SCOPES);
        DataHandoverResult result = handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), source.employeeId(), target.employeeId(),
                allScopes, "整人交接释放认领", BusinessTime.today()));

        assertEquals(1L, result.resultSummary().get("workflow.claims"));
        assertEquals(1L, result.resultSummary().get("total"));
        assertEquals(0, count("select count(*) from employee_data_handover_scopes where handover_id=?",
                result.id()));
        assertEquals(8, jdbc.queryForObject(
                "select cardinality(requested_scopes) from employee_data_handovers where id=?",
                Integer.class, result.id()));
        assertEquals(1, count("select count(*) from task_claims where claimed_by=? and released_at is not null",
                source.employeeId()));

        Staff emptySource = staff("zero-a", department, "active", false, true);
        Staff emptyTarget = staff("zero-b", department, "active", false, true);
        // V471 起主仓库必填（含已删除行），夹具补一个合规仓库。
        UUID zeroWarehouseId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO warehouses(id, code, name, status)
                VALUES (?, ?, '交接零影响测试仓', '使用')
                """, zeroWarehouseId, "WH-ZERO-" + zeroWarehouseId);
        jdbc.update("""
                INSERT INTO production_material_analyses(
                    id,fingerprint,initial_idempotency_key,maker_id,
                    warehouse_id,participating_warehouse_ids,
                    is_deleted,deleted_at)
                VALUES (?,? ,?,?,?,ARRAY[?]::UUID[],true,now())
                """, UUID.randomUUID(), "a".repeat(64),
                "deleted-only-" + UUID.randomUUID(), emptySource.employeeId(),
                zeroWarehouseId, zeroWarehouseId);
        var deletedOnly = handovers.preview(
                emptySource.employeeId(), emptyTarget.employeeId(),
                Set.of("production_plan"));
        assertEquals(0, deletedOnly.total());
        UUID deletedOnlyRequestId = UUID.randomUUID();
        assertThrows(ApiException.class, () -> handovers.executeManual(
                new DataHandoverRequest(
                        deletedOnlyRequestId, emptySource.employeeId(),
                        emptyTarget.employeeId(), Set.of("production_plan"),
                        "已删除生产分析不构成交接影响", BusinessTime.today())));
        assertEquals(0, count("SELECT count(*) FROM employee_data_handovers WHERE request_id=?",
                deletedOnlyRequestId));
        assertThrows(ApiException.class, () -> handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), emptySource.employeeId(), emptyTarget.employeeId(),
                Set.of("finance"), "零数据不得造边", BusinessTime.today())));
        assertThrows(ApiException.class, () -> handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), emptySource.employeeId(), emptyTarget.employeeId(),
                Set.of(), "空范围不得扩大", BusinessTime.today())));
    }

    @Test
    void offboardingPreservesPerScopeSuccessorsIsIdempotentAndRehireRestoresNoPersonalGrant() {
        loginAsSuperAdministrator();
        UUID department = departmentId();
        Staff source = staff("off-a", department, "active", true, false);
        Staff salesTarget = staff("off-b", department, "active", false, true);
        Staff productionTarget = staff("off-c", department, "active", false, true);
        Staff defaultTarget = staff("off-d", department, "active", false, true);

        websiteInquiry("before-sales", source.employeeId());
        rdTask("before-production", source.employeeId());
        DataHandoverRequest firstSalesHandover = new DataHandoverRequest(
                UUID.randomUUID(), source.employeeId(), salesTarget.employeeId(),
                Set.of("sales"), "销售模块先行交接", BusinessTime.today());
        handovers.executeManual(firstSalesHandover);
        handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), source.employeeId(), productionTarget.employeeId(),
                Set.of("production_plan"), "生产模块先行交接", BusinessTime.today()));
        UUID laterInquiry = websiteInquiry("later-sales", source.employeeId());
        UUID laterTask = rdTask("later-production", source.employeeId());
        assertEquals(salesTarget.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));
        UUID deletedViewerClient = client(
                "off-deleted-viewer", defaultTarget.employeeId());
        insertViewer(deletedViewerClient, source.employeeId(), true);
        jdbc.update("UPDATE clients SET is_deleted=true,deleted_at=now() WHERE id=?",
                deletedViewerClient);
        UUID uploadSessionId = UUID.randomUUID();
        String uploadStorageKey = "offboard-upload-" + uploadSessionId;
        jdbc.update("""
                INSERT INTO attachment_upload_sessions(
                    id,storage_key,owner_type,owner_id,user_id,original_name,
                    content_type,expected_size_bytes,expires_at,status)
                VALUES (?,?, 'CLIENT',?,?, 'handover.txt','text/plain',16,
                        now()+interval '1 hour','PENDING')
                """, uploadSessionId, uploadStorageKey,
                deletedViewerClient, source.userId());

        jdbc.update("""
                insert into user_permission_overrides(
                    user_id,permission_id,effect,authority_source,active)
                select ?,permission.id,'grant','SUPER_ADMIN_CONFIRMED',true
                from permissions permission where permission.code='employee:view'
                on conflict (user_id,permission_id) do update set active=true
                """, source.userId());
        grantOwnerScope(source.userId(), "goods", source.employeeId());
        grantOwnerScope(salesTarget.userId(), "goods", source.employeeId());
        jdbc.update("""
                update users set remote_access=true,must_change_password=false,
                    temp_password_expires_at=now()+interval '1 day'
                where id=?
                """, source.userId());

        UUID requestId = UUID.randomUUID();
        OffboardRequest request = new OffboardRequest(
                "VOLUNTARY", BusinessTime.today(), "完整离职链路验证",
                defaultTarget.employeeId(), requestId, "离职责任交接",
                requiredChecklist());
        employees.offboard(source.employeeId(), request);

        assertEquals("resigned", employeeStatus(source.employeeId()));
        assertEquals("disabled", accountStatus(source.userId()));
        assertEquals(salesTarget.employeeId(), jdbc.queryForObject(
                "select assignee_employee_id from website_inquiries where id=?",
                UUID.class, laterInquiry));
        assertEquals(productionTarget.employeeId(), jdbc.queryForObject(
                "select assignee_employee_id from rd_tasks where id=?",
                UUID.class, laterTask));
        assertEquals(salesTarget.employeeId(), latestSuccessor(source.employeeId(), "sales"));
        assertEquals(productionTarget.employeeId(), latestSuccessor(source.employeeId(), "production_plan"));
        assertEquals(0, count("""
                select count(*) from employee_data_handovers handover
                join employee_data_handover_scopes scope on scope.handover_id=handover.id
                where handover.source_employee_id=? and handover.target_employee_id=?
                  and scope.scope in ('sales','production_plan')
                """, source.employeeId(), defaultTarget.employeeId()));
        assertEquals(0, count("select count(*) from user_permission_overrides where user_id=? and active=true",
                source.userId()));
        assertEquals(0, count(
                "select count(*) from user_data_scopes where user_id=?",
                source.userId()));
        assertEquals(1, count("""
                select count(*) from user_data_scopes
                where user_id=? and scope='goods' and owner_employee_id=?
                """, salesTarget.userId(), source.employeeId()));
        assertEquals("1", jdbc.queryForObject("""
                select result_summary->>'access.dataScopes'
                from employee_offboarding_events where request_id=?
                """, String.class, requestId));
        Map<String, Object> account = jdbc.queryForMap(
                "select remote_access,must_change_password,temp_password_expires_at from users where id=?",
                source.userId());
        assertEquals(false, account.get("remote_access"));
        assertEquals(true, account.get("must_change_password"));
        assertEquals(null, account.get("temp_password_expires_at"));
        assertEquals(1, count("select count(*) from employee_offboarding_events where request_id=? and status='COMPLETED'",
                requestId));
        assertEquals(2, count("""
                select count(*) from audit_log audit
                join employee_offboarding_events event on audit.target_id=event.id::text
                where event.request_id=? and audit.target_type='employee_offboarding_events'
                  and not jsonb_exists(coalesce(audit.before,'{}'::jsonb),'reason')
                  and not jsonb_exists(coalesce(audit."after",'{}'::jsonb),'reason')
                  and not jsonb_exists(coalesce(audit."after",'{}'::jsonb),'handover_reason')
                """, requestId));
        assertEquals("1", jdbc.queryForObject("""
                SELECT result_summary->>'access.clientViewerGrants'
                FROM employee_offboarding_events WHERE request_id=?
                """, String.class, requestId));
        assertEquals(0, activeViewerClientCount(
                source.employeeId(), deletedViewerClient));
        assertEquals(1, count("""
                SELECT count(*) FROM clients
                WHERE id=? AND is_deleted=true AND access_version=1 AND version=1
                """, deletedViewerClient));
        assertEquals(1, count("""
                SELECT count(*) FROM client_access_change_events
                WHERE client_id=? AND previous_owner_employee_id=new_owner_employee_id
                  AND ?=ANY(previous_viewer_ids)
                  AND NOT (?=ANY(new_viewer_ids))
                """, deletedViewerClient, source.employeeId(), source.employeeId()));
        assertEquals("1", jdbc.queryForObject("""
                SELECT result_summary->>'access.attachmentUploads'
                FROM employee_offboarding_events WHERE request_id=?
                """, String.class, requestId));
        Map<String, Object> uploadState = jdbc.queryForMap("""
                SELECT status,last_failure_code,completed_at
                FROM attachment_upload_sessions WHERE id=?
                """, uploadSessionId);
        assertEquals("EXPIRED", uploadState.get("status"));
        assertEquals("EXPIRY_CLEANUP_PENDING", uploadState.get("last_failure_code"));
        assertTrue(uploadState.get("completed_at") != null);
        assertThrows(DataAccessException.class, () -> jdbc.update("""
                INSERT INTO attachment_upload_sessions(
                    id,storage_key,owner_type,owner_id,user_id,original_name,
                    content_type,expected_size_bytes,expires_at,status)
                VALUES (?,?, 'CLIENT',?,?, 'after-offboard.txt','text/plain',16,
                        now()+interval '1 hour','PENDING')
                """, UUID.randomUUID(), "after-offboard-" + UUID.randomUUID(),
                deletedViewerClient, source.userId()));
        loginAsStaff(salesTarget);
        assertTrue(ownerVisibility.evaluate("goods", "goods:view:all")
                .visibleOwners().contains(source.employeeId()));
        loginAsSuperAdministrator();

        int historyBeforeReplay = count(
                "select count(*) from employment_history where employee_id=? and event_type='resign'",
                source.employeeId());
        employees.offboard(source.employeeId(), request);
        assertEquals(historyBeforeReplay, count(
                "select count(*) from employment_history where employee_id=? and event_type='resign'",
                source.employeeId()));

        employees.rehire(source.employeeId());
        assertEquals("active", employeeStatus(source.employeeId()));
        assertEquals("active", accountStatus(source.userId()));
        assertEquals(0, count("select count(*) from user_permission_overrides where user_id=? and active=true",
                source.userId()));
        assertEquals(true, jdbc.queryForObject(
                "select must_change_password from users where id=?", Boolean.class, source.userId()));
        assertEquals(false, jdbc.queryForObject(
                "select remote_access from users where id=?", Boolean.class, source.userId()));
        assertThrows(ApiException.class, () -> employees.offboard(source.employeeId(), request));
        assertEquals(source.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));
        assertFalse(handoverVisibility.inheritedOwners(
                salesTarget.employeeId(), "sales").contains(source.employeeId()));
        assertThrows(ApiException.class,
                () -> handovers.executeManual(firstSalesHandover));
        assertEquals(1, count("""
                SELECT count(*) FROM user_data_scopes
                WHERE user_id=? AND scope='goods' AND owner_employee_id=?
                  AND owner_employment_generation=0
                """, salesTarget.userId(), source.employeeId()));
        loginAsStaff(salesTarget);
        assertFalse(ownerVisibility.evaluate("goods", "goods:view:all")
                .visibleOwners().contains(source.employeeId()));
        loginAsSuperAdministrator();

        // Explicit post-rehire replacement deletes the stale generation row and
        // inserts a grant stamped by the DB with generation 1.
        dataScopes.setDataScopes(
                salesTarget.userId(), "goods", List.of(source.employeeId()), List.of());
        assertEquals(1L, jdbc.queryForObject("""
                SELECT owner_employment_generation FROM user_data_scopes
                WHERE user_id=? AND scope='goods' AND owner_employee_id=?
                """, Long.class, salesTarget.userId(), source.employeeId()));
        loginAsStaff(salesTarget);
        assertTrue(ownerVisibility.evaluate("goods", "goods:view:all")
                .visibleOwners().contains(source.employeeId()));
        loginAsSuperAdministrator();

        // The old A->B edge belongs to A's previous employment generation, so it
        // must not create a false cycle when B formally hands sales back to A.
        handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), salesTarget.employeeId(), source.employeeId(),
                Set.of("sales"), "复职后销售责任交回", BusinessTime.today()));
        assertEquals(source.employeeId(),
                handoverVisibility.currentResponsible("sales", salesTarget.employeeId()));

        handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), source.employeeId(), defaultTarget.employeeId(),
                Set.of("sales"), "第二任职销售交接", BusinessTime.today()));
        assertEquals(defaultTarget.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));
        assertTrue(handoverVisibility.inheritedOwners(
                defaultTarget.employeeId(), "sales").contains(source.employeeId()));

        UUID secondRequestId = UUID.randomUUID();
        OffboardRequest secondRequest = new OffboardRequest(
                "VOLUNTARY", BusinessTime.today(), "第二段任职离职",
                defaultTarget.employeeId(), secondRequestId, "第二次离职交接",
                requiredChecklist());
        employees.offboard(source.employeeId(), secondRequest);
        assertEquals("resigned", employeeStatus(source.employeeId()));
        assertEquals(0L, jdbc.queryForObject("""
                SELECT employment_generation FROM employee_offboarding_events
                WHERE request_id=?
                """, Long.class, requestId));
        assertEquals(1L, jdbc.queryForObject("""
                SELECT employment_generation FROM employee_offboarding_events
                WHERE request_id=?
                """, Long.class, secondRequestId));
        ApiException priorEmployment = assertThrows(
                ApiException.class,
                () -> employees.offboard(source.employeeId(), request));
        assertTrue(priorEmployment.getMessage().contains("上一段任职"));
    }

    @Test
    void handoverScopeRowsStayInsideRequestedExecutingParent() {
        loginAsSuperAdministrator();
        UUID department = departmentId();
        Staff source = staff("scope-parent-a", department, "active", false, true);
        Staff target = staff("scope-parent-b", department, "active", false, true);
        UUID actor = superAdministratorUserId();
        UUID handoverId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employee_data_handovers(
                    id,request_id,source_employee_id,target_employee_id,mode,
                    effective_date,reason,requested_scopes,status,result_summary,
                    source_employment_generation,target_employment_generation,created_by_user_id)
                VALUES (?,?,?,?, 'MANUAL',current_date,'scope guard',
                        ARRAY['sales']::text[],'EXECUTING','{}'::jsonb,0,0,?)
                """, handoverId, UUID.randomUUID(), source.employeeId(),
                target.employeeId(), actor);
        jdbc.update("""
                INSERT INTO employee_data_handover_scopes(handover_id,scope)
                VALUES (?,'sales')
                """, handoverId);
        assertThrows(DataAccessException.class, () -> jdbc.update("""
                INSERT INTO employee_data_handover_scopes(handover_id,scope)
                VALUES (?,'finance')
                """, handoverId));
        jdbc.update("""
                UPDATE employee_data_handovers
                SET status='COMPLETED',result_summary='{"history.sales":1}'::jsonb
                WHERE id=?
                """, handoverId);
        assertThrows(DataAccessException.class, () -> jdbc.update("""
                INSERT INTO employee_data_handover_scopes(handover_id,scope)
                VALUES (?,'purchase')
                """, handoverId));
        assertThrows(DataAccessException.class, () -> jdbc.update("""
                UPDATE employee_data_handover_scopes SET scope='finance'
                WHERE handover_id=? AND scope='sales'
                """, handoverId));
        assertThrows(DataAccessException.class, () -> jdbc.update("""
                DELETE FROM employee_data_handover_scopes
                WHERE handover_id=? AND scope='sales'
                """, handoverId));
        assertThrows(DataAccessException.class, () -> jdbc.update("""
                INSERT INTO employee_data_handovers(
                    id,request_id,source_employee_id,target_employee_id,mode,
                    effective_date,reason,requested_scopes,status,result_summary,
                    source_employment_generation,target_employment_generation,created_by_user_id)
                VALUES (?,?,?,?,'MANUAL',current_date,'duplicate scopes',
                        ARRAY['sales','sales']::text[],'EXECUTING','{}'::jsonb,0,0,?)
                """, UUID.randomUUID(), UUID.randomUUID(), source.employeeId(),
                target.employeeId(), actor));

        UUID historyId = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employment_history(
                    id,employee_id,event_type,event_date,remark)
                VALUES (?,?,'transfer',current_date,'append-only positive control')
                """, historyId, source.employeeId());
        assertEquals(1, count(
                "SELECT count(*) FROM employment_history WHERE id=?", historyId));
        assertThrows(DataAccessException.class, () -> jdbc.update("""
                UPDATE employment_history SET remark='mutated' WHERE id=?
                """, historyId));
        assertThrows(DataAccessException.class, () -> jdbc.update("""
                DELETE FROM employment_history WHERE id=?
                """, historyId));
        assertEquals("append-only positive control", jdbc.queryForObject(
                "SELECT remark FROM employment_history WHERE id=?",
                String.class, historyId));
    }

    @Test
    void managerCannotUseKnownUuidOutsideSubtreeAndSuperAdminEmployeesStayProtected() {
        UUID managedDepartment = department("HOVM", "交接管理范围");
        UUID outsideDepartment = department("HOVO", "交接范围外");
        Staff manager = staff("scope-manager", managedDepartment, "active", false, true);
        Staff source = staff("scope-source", managedDepartment, "active", false, true);
        Staff outside = staff("scope-outside", outsideDepartment, "active", false, true);
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",
                manager.employeeId(), managedDepartment);
        loginAsStaff(manager);

        ApiException targetOutside = assertThrows(ApiException.class, () ->
                handovers.preview(source.employeeId(), outside.employeeId(), Set.of("sales")));
        assertEquals(com.uten.imp.common.web.ErrorCode.NOT_FOUND, targetOutside.getCode());
        ApiException sourceOutside = assertThrows(ApiException.class, () ->
                handovers.preview(outside.employeeId(), source.employeeId(), Set.of("sales")));
        assertEquals(com.uten.imp.common.web.ErrorCode.NOT_FOUND, sourceOutside.getCode());

        loginAsSuperAdministrator();
        UUID protectedEmployee = superAdministratorEmployeeId();
        assertEquals(com.uten.imp.common.web.ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class, () -> handovers.preview(
                        protectedEmployee, source.employeeId(), Set.of("sales"))).getCode());
        assertEquals(com.uten.imp.common.web.ErrorCode.FORBIDDEN,
                assertThrows(ApiException.class, () -> handovers.preview(
                        source.employeeId(), protectedEmployee, Set.of("sales"))).getCode());
    }

    @Test
    void targetRehireInvalidatesIncomingEdgeAndCutsTheMiddleOfAChain() {
        loginAsSuperAdministrator();
        UUID department = departmentId();
        Staff source = staff("target-gen-a", department, "active", false, true);
        Staff middle = staff("target-gen-b", department, "active", false, true);
        Staff successor = staff("target-gen-c", department, "active", false, true);
        websiteInquiry("target-gen-first", source.employeeId());
        handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), source.employeeId(), middle.employeeId(),
                Set.of("sales"), "A到B同任职交接", BusinessTime.today()));
        assertEquals(middle.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));

        OffboardRequest middleOffboard = new OffboardRequest(
                "VOLUNTARY", BusinessTime.today(), "中间接手人离职",
                successor.employeeId(), UUID.randomUUID(), "B到C离职交接",
                requiredChecklist());
        employees.offboard(middle.employeeId(), middleOffboard);
        assertEquals(successor.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));

        employees.rehire(middle.employeeId());
        assertEquals(source.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));
        assertFalse(handoverVisibility.inheritedOwners(
                middle.employeeId(), "sales").contains(source.employeeId()));
        assertFalse(handoverVisibility.inheritedOwners(
                successor.employeeId(), "sales").contains(source.employeeId()));

        websiteInquiry("target-gen-new", source.employeeId());
        handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), source.employeeId(), successor.employeeId(),
                Set.of("sales"), "目标复职后新边接管", BusinessTime.today()));
        assertEquals(successor.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));
        assertTrue(handoverVisibility.inheritedOwners(
                successor.employeeId(), "sales").contains(source.employeeId()));
    }

    @Test
    void offboardingReplayRejectsARehiredDefaultSuccessor() {
        loginAsSuperAdministrator();
        UUID department = departmentId();
        Staff source = staff("event-target-a", department, "active", false, true);
        Staff target = staff("event-target-b", department, "active", false, true);
        Staff fallback = staff("event-target-c", department, "active", false, true);
        websiteInquiry("event-target-work", source.employeeId());
        UUID sourceRequestId = UUID.randomUUID();
        OffboardRequest sourceRequest = new OffboardRequest(
                "VOLUNTARY", BusinessTime.today(), "来源员工离职",
                target.employeeId(), sourceRequestId, "来源到默认接手人",
                requiredChecklist());
        employees.offboard(source.employeeId(), sourceRequest);

        OffboardRequest targetRequest = new OffboardRequest(
                "VOLUNTARY", BusinessTime.today(), "默认接手人离职",
                fallback.employeeId(), UUID.randomUUID(), "默认接手人继续交接",
                requiredChecklist());
        employees.offboard(target.employeeId(), targetRequest);
        employees.rehire(target.employeeId());

        ApiException staleReplay = assertThrows(ApiException.class, () ->
                employees.offboard(source.employeeId(), sourceRequest));
        assertTrue(staleReplay.getMessage().contains("上一段任职"));
        assertEquals(0L, jdbc.queryForObject("""
                SELECT default_successor_employment_generation
                FROM employee_offboarding_events WHERE request_id=?
                """, Long.class, sourceRequestId));
        assertEquals(1, count("""
                SELECT count(*) FROM employment_history
                WHERE employee_id=? AND event_type='rehire'
                """, target.employeeId()));
    }

    @Test
    void invalidLatestTargetNeverFallsBackToAnOlderTarget() {
        loginAsSuperAdministrator();
        UUID department = departmentId();
        Staff source = staff("no-fallback-a", department, "active", false, true);
        Staff olderTarget = staff("no-fallback-b", department, "active", false, true);
        Staff latestTarget = staff("no-fallback-c", department, "active", false, true);
        Staff newTarget = staff("no-fallback-d", department, "active", false, true);
        websiteInquiry("no-fallback-old", source.employeeId());
        handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), source.employeeId(), olderTarget.employeeId(),
                Set.of("sales"), "旧接手边", BusinessTime.today()));
        websiteInquiry("no-fallback-latest", source.employeeId());
        handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), source.employeeId(), latestTarget.employeeId(),
                Set.of("sales"), "最新接手边", BusinessTime.today()));
        assertEquals(latestTarget.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));

        employees.offboard(latestTarget.employeeId(), new OffboardRequest(
                "VOLUNTARY", BusinessTime.today(), "最新接手人离职",
                newTarget.employeeId(), UUID.randomUUID(), "继续交接",
                requiredChecklist()));
        employees.rehire(latestTarget.employeeId());

        assertEquals(source.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));
        assertFalse(handoverVisibility.inheritedOwners(
                olderTarget.employeeId(), "sales").contains(source.employeeId()));
        assertFalse(handoverVisibility.inheritedOwners(
                newTarget.employeeId(), "sales").contains(source.employeeId()));

        websiteInquiry("no-fallback-new-generation", source.employeeId());
        handovers.executeManual(new DataHandoverRequest(
                UUID.randomUUID(), source.employeeId(), newTarget.employeeId(),
                Set.of("sales"), "失效后显式新边", BusinessTime.today()));
        assertEquals(newTarget.employeeId(),
                handoverVisibility.currentResponsible("sales", source.employeeId()));
    }

    @Test
    void resignedDisabledRecipientCanClearButCannotReceiveDataScope() {
        loginAsSuperAdministrator();
        UUID department = departmentId();
        Staff owner = staff("scope-clear-owner", department, "active", false, true);
        Staff recipient = staff("scope-clear-recipient", department, "active", false, true);
        grantOwnerScope(recipient.userId(), "goods", owner.employeeId());
        jdbc.update("UPDATE employees SET status='resigned' WHERE id=?",
                recipient.employeeId());
        jdbc.update("UPDATE users SET status='disabled' WHERE id=?",
                recipient.userId());

        dataScopes.setDataScopes(
                recipient.userId(), "goods", List.of(), List.of(owner.employeeId()));
        assertEquals(0, count("""
                SELECT count(*) FROM user_data_scopes
                WHERE user_id=? AND scope='goods'
                """, recipient.userId()));

        ApiException grantRejected = assertThrows(ApiException.class, () ->
                dataScopes.setDataScopes(
                        recipient.userId(), "goods",
                        List.of(owner.employeeId()), List.of()));
        assertTrue(grantRejected.getMessage().contains("离职")
                || grantRejected.getMessage().contains("停用"));
        assertEquals(0, count("""
                SELECT count(*) FROM user_data_scopes
                WHERE user_id=? AND scope='goods'
                """, recipient.userId()));
    }

    private Staff staff(
            String tag, UUID departmentId, String status,
            boolean remoteAccess, boolean mustChangePassword) {
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        String suffix = tag + "-" + SEQUENCE.incrementAndGet();
        jdbc.update("""
                insert into employees(
                    id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                values (?,?,?,'其他',?,date '2026-01-01',?,'regular')
                """, employeeId, "EMP-" + suffix, "员工-" + suffix, departmentId, status);
        jdbc.update("""
                insert into users(
                    id,employee_id,login_account,password_hash,must_change_password,
                    is_super_admin,status,remote_access)
                values (?,?,?,'argon2-test-not-used',?,false,'active',?)
                """, userId, employeeId, "USER-" + suffix, mustChangePassword, remoteAccess);
        return new Staff(employeeId, userId);
    }

    private UUID client(String tag, UUID ownerId) {
        UUID id = UUID.randomUUID();
        int sequence = SEQUENCE.incrementAndGet();
        jdbc.update("""
                insert into clients(id,code,name,status,owner_employee_id,code_sequence,sales_payment_type)
                values (?,?,?,'使用',?,?,'MONTHLY')
                """, id, "KH" + String.format("%08d", sequence),
                "客户-" + tag + "-" + sequence, ownerId, sequence);
        return id;
    }

    private void grantOwnerScope(UUID userId, String scope, UUID ownerId) {
        jdbc.update("""
                insert into user_data_scopes(user_id,scope,owner_employee_id,created_by)
                values (?,?,?,?)
                """, userId, scope, ownerId, superAdministratorUserId());
    }

    private void insertViewer(UUID clientId, UUID employeeId, boolean active) {
        UUID actor = superAdministratorUserId();
        jdbc.update("""
                insert into client_visibility_grants(
                    client_id,grantee_employee_id,active,row_version,granted_by_user_id,
                    revoked_by_user_id,revoked_at)
                values (?,?,?,1,?,?,case when ? then null else now() end)
                """, clientId, employeeId, active, actor,
                active ? null : actor, active);
    }

    private UUID websiteInquiry(String tag, UUID assigneeId) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into website_inquiries(id,source_id,name,message,status,assignee_employee_id)
                values (?,?,?,'测试询盘','new',?)
                """, id, "web-" + tag + "-" + UUID.randomUUID(), "询盘-" + tag, assigneeId);
        return id;
    }

    private UUID rdTask(String tag, UUID employeeId) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into rd_tasks(
                    id,task_no,title,category,status,priority,
                    assignee_employee_id,reporter_employee_id)
                values (?,?,?,'OTHER','OPEN','NORMAL',?,?)
                """, id, docNumberService.nextNumber(DocNumberPrefix.RD_TASK),
                "研发-" + tag, employeeId, employeeId);
        return id;
    }

    private int activeViewerClientCount(UUID viewerId, UUID... clientIds) {
        return jdbc.queryForObject("""
                select count(*) from client_visibility_grants
                where grantee_employee_id=? and active=true and client_id=any(?)
                """, Integer.class, viewerId, clientIds);
    }

    private int count(String sql, Object... args) {
        Integer result = jdbc.queryForObject(sql, Integer.class, args);
        return result == null ? 0 : result;
    }

    private UUID latestSuccessor(UUID sourceId, String scope) {
        return jdbc.queryForObject("""
                select handover.target_employee_id
                from employee_data_handovers handover
                join employee_data_handover_scopes handover_scope
                  on handover_scope.handover_id=handover.id
                where handover.source_employee_id=? and handover_scope.scope=?
                  and handover.status='COMPLETED'
                order by handover.sequence_no desc limit 1
                """, UUID.class, sourceId, scope);
    }

    private String employeeStatus(UUID employeeId) {
        return jdbc.queryForObject(
                "select status from employees where id=?", String.class, employeeId);
    }

    private String accountStatus(UUID userId) {
        return jdbc.queryForObject(
                "select status from users where id=?", String.class, userId);
    }

    private static boolean hasCause(Throwable error, Class<?> type) {
        Throwable current = error;
        while (current != null) {
            if (type.isInstance(current)) return true;
            current = current.getCause();
        }
        return false;
    }

    private UUID department(String prefix, String name) {
        int sequence = SEQUENCE.incrementAndGet();
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO departments(id,code,name,level)
                VALUES (?,?,?,'一级部门')
                """, id, prefix + sequence, name + sequence);
        return id;
    }

    private void loginAsStaff(Staff staff) {
        String login = jdbc.queryForObject(
                "SELECT login_account FROM users WHERE id=?",
                String.class, staff.userId());
        AuthUser principal = new AuthUser(
                staff.userId(), staff.employeeId(), login,
                Set.of(), Set.of(), false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(
                        principal, null, principal.getAuthorities()));
    }

    private UUID superAdministratorEmployeeId() {
        return jdbc.queryForObject("""
                SELECT employee_id FROM users
                WHERE is_super_admin=true AND is_deleted=false
                ORDER BY created_at,id LIMIT 1
                """, UUID.class);
    }

    private UUID departmentId() {
        return jdbc.queryForObject(
                "select id from departments where code='DEPT_SALES'", UUID.class);
    }

    private Set<String> requiredChecklist() {
        return Set.of(
                "ACCESS_CARD_RETURNED",
                "COMPANY_ASSETS_ACCOUNTED",
                "ACCOUNT_DISABLE_ACKNOWLEDGED",
                "SOCIAL_BENEFITS_ARRANGED");
    }

    private void loginAsSuperAdministrator() {
        UUID userId = superAdministratorUserId();
        Map<String, Object> user = jdbc.queryForMap("""
                select employee_id,login_account,is_super_admin,
                       must_change_password,status
                from users where id=?
                """, userId);
        UUID employeeId = (UUID) user.get("employee_id");
        boolean superAdmin = Boolean.TRUE.equals(user.get("is_super_admin"));
        PermissionResolver.AuthorizationSnapshot snapshot =
                permissionResolver.authorizationSnapshot(userId, employeeId, superAdmin);
        AuthUser principal = new AuthUser(
                userId, employeeId, (String) user.get("login_account"),
                snapshot.roles(), snapshot.permissions(),
                false, "active".equals(user.get("status")), superAdmin);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(
                        principal, null, principal.getAuthorities()));
    }

    private UUID superAdministratorUserId() {
        return jdbc.queryForObject("""
                select id from users
                where is_super_admin=true and is_deleted=false
                order by created_at,id limit 1
                """, UUID.class);
    }

    private record Staff(UUID employeeId, UUID userId) {
    }
}
