package com.uten.imp.ops;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.audit.AuditLog;
import com.uten.imp.audit.AuditLogRepository;
import com.uten.imp.audit.AuditRequestContext;
import com.uten.imp.audit.AuditService;
import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.systemtest.BusinessDataResetDrainGate;
import com.uten.imp.features.admin.systemtest.BusinessDataResetFeatureGate;
import com.uten.imp.features.admin.systemtest.BusinessDataResetService;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.postgresql.Driver;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.datasource.SimpleDriverDataSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.TransactionManager;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import jakarta.persistence.EntityManagerFactory;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 工作台「清空业务数据」的真实库执行证明（V462 函数 + 服务编排全链路）：
 * 种子业务行被清空、主档金额归零且行数保留、identity 序列重启、
 * 全局 epoch 递增踢掉所有 staff token、refresh_tokens 被清空、
 * outbox 待处理事件按 UT900 拒绝为 409、可重复执行。
 *
 * <p>写法约束（Mimosa 写入门）：每条 SQL 在各自方法内内联字面量，经独立
 * Statement/PreparedStatement 执行；不存在把 SQL 字符串当参数传递的帮手。</p>
 */
@Testcontainers(disabledWithoutDocker = true)
class BusinessDataResetServicePostgresTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16.15-alpine")
                    .withDatabaseName("uten_business_reset")
                    .withUsername("uten")
                    .withPassword("uten");

    private final List<EntityManagerFactory> entityManagerFactories = new ArrayList<>();

    @AfterEach
    void releaseJpaAndRequestContext() {
        RequestContextHolder.resetRequestAttributes();
        entityManagerFactories.forEach(EntityManagerFactory::close);
    }

    @Test
    void resetsBusinessDataZeroesProjectionsRestartsIdentityAndKicksEveryone() throws Exception {
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();

        SimpleDriverDataSource dataSource = new SimpleDriverDataSource(
                new Driver(), POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());

        // Compare the actually migrated function with the operator's script, including loop-added rows.
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)")) {
            assertThat(rows.next()).isTrue();
            String ops = java.nio.file.Files.readString(java.nio.file.Path.of("ops", "reset_business_data.sql"));
            assertThat(BusinessDataResetSqlContractTest.policy(rows.getString(1)))
                    .isEqualTo(BusinessDataResetSqlContractTest.policy(ops));
        }

        insertSeedDepartment(dataSource);
        insertSeedEmployee(dataSource);
        insertSeedUser(dataSource);
        insertSeedRefreshToken(dataSource);
        long epochBefore = readEpoch(dataSource);

        // 2026-09-09 起清空前置「业务附件彻底清理」：本测试没有业务附件，预览恒 0 阻塞
        // → purge 直接返回；drainNextDeletion 不会被调用（mock 默认 false）。
        BusinessAttachmentResetPreparationPort attachmentReset =
                mock(BusinessAttachmentResetPreparationPort.class);
        when(attachmentReset.preview(any())).thenReturn(
                new BusinessAttachmentResetPreparationPort.Preview(
                        "uten_imp", "fp-empty", 0L, List.of(), false));
        var drain = new BusinessDataResetDrainGate();
        BusinessDataResetService service = newService(dataSource, attachmentReset, drain);

        // —— 阶段一：outbox 有待处理事件 → UT900 拒绝（409）——
        insertSeedBusinessOutboxRow(dataSource, (short) 0);
        ApiException refused = assertThrows(ApiException.class,
                () -> service.reset(UUID.randomUUID(), "superadmin"));
        assertThat(refused.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(refused.getMessage()).contains("待处理或失败事件");
        assertThat(countBusinessOutbox(dataSource)).isEqualTo(1);

        // —— 阶段二：事件已处理 → 种子齐备后执行清空 ——
        markSeedBusinessOutboxProcessed(dataSource);
        insertSeedBusinessOutboxRow(dataSource, (short) 1);
        insertSeedAccount(dataSource);
        insertSeedLegacyValuePool(dataSource);

        long auditBefore = countAuditLog(dataSource);
        long usersBefore = countUsers(dataSource);

        UUID operator = UUID.randomUUID();
        UUID attempt = UUID.randomUUID();
        UUID session = UUID.randomUUID();
        UUID operation = UUID.randomUUID();
        UUID installation = UUID.randomUUID();
        var request = new MockHttpServletRequest("POST", "/api/system-test/business-data/reset");
        request.setRemoteAddr("192.0.2.12");
        request.addHeader("User-Agent", "reset-receipt-test");
        request.addHeader(AuditDeviceContext.HEADER_CLIENT_EVENT_ID, operation.toString());
        String device = new ObjectMapper().writeValueAsString(Map.of(
                "version", 1, "installationId", installation.toString(), "platform", "windows",
                "appVersion", "receipt-test", "deviceName", "Reset test device"));
        request.addHeader(AuditDeviceContext.HEADER_DEVICE_CONTEXT,
                Base64.getUrlEncoder().withoutPadding().encodeToString(device.getBytes(StandardCharsets.UTF_8)));
        AuditRequestContext.bindSessionId(request, session);
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));

        // A deferred database failure occurs at the actual commit, after the
        // reset function and JPA receipt INSERT have both returned successfully.
        installFailingReceiptTrigger(dataSource);
        long postingBefore = nextPostingSeqValue(dataSource);
        try {
            ApiException auditFailure = assertThrows(ApiException.class,
                    () -> service.reset(operator, "superadmin", attempt));
            assertThat(auditFailure.getCode()).isEqualTo(ErrorCode.INTERNAL);
            assertThat(auditFailure.getMessage()).contains("未确认完成", "重新登录核对本次结果")
                    .doesNotContain("已整体回滚");
            assertThat(auditFailure).hasStackTraceContaining("reset completion unavailable");
            assertThat(readEpoch(dataSource)).isEqualTo(epochBefore);
            assertThat(countRefreshTokens(dataSource)).isEqualTo(1);
            assertThat(countBusinessOutbox(dataSource)).isEqualTo(2);
            // ADR-067 §9：受理回执独立于清库事务、先行提交，回滚后仍在（+1）；提交确认丢失
            // 的不确定结果不写失败回执，完成回执随事务回滚——重登核对时只看到「已受理未完成」。
            assertThat(countAuditLog(dataSource)).isEqualTo(auditBefore + 1);
            assertThat(countFullyZeroedAccounts(dataSource)).isZero();
            assertThat(nextPostingSeqValue(dataSource)).isEqualTo(postingBefore + 1);
            assertUnchangedMoneyAndStock(dataSource);
            var uncertain = service.lastResult(operator, attempt);
            assertThat(uncertain.available()).isFalse();
            assertThat(uncertain.attemptReceived()).isTrue();
            assertThat(uncertain.attemptReceivedByCurrentServer()).isTrue();
            assertThat(uncertain.attemptFailed()).isFalse();
            assertThat(drain.blockingNewRequests()).isFalse();
            assertThat(drain.tryEnter()).isTrue();
            drain.leave();
            verify(attachmentReset, never()).cleanupAbandonedScratch();
        } finally {
            removeFailingReceiptTrigger(dataSource);
        }

        var result = service.reset(operator, "superadmin", attempt);
        assertThat(drain.blockingNewRequests()).isFalse();
        var receipt = service.lastResult(operator, attempt);
        assertThat(receipt.available()).isTrue();
        assertThat(receipt.operatorId()).isEqualTo(operator);
        assertThat(receipt.attemptId()).isEqualTo(attempt);
        assertThat(receipt.clearedRows()).isEqualTo(result.clearedRows());
        assertThat(receipt.authorizationEpochAfter()).isEqualTo(result.authorizationEpochAfter());
        assertThat(service.lastResult(UUID.randomUUID(), attempt).available()).isFalse();
        assertThat(service.lastResult(operator, UUID.randomUUID()).available()).isFalse();
        assertReceiptMetadata(dataSource, attempt, session, operation, installation,
                AuditRequestContext.ensureRequestId(request));

        // V463/V464：+purchase/subcontract_order_item_sources 两张 CLEAR 表（222→224）；
        // V474 运行时补丁再 +preplan_public_supply_events（224→225）。
        // V478 再 +preplan_root_output_events(225→226)；V479 只修函数，不新增表。
        // V484 运行时补丁再 +sales_order_qty_change_logs（226→227）；
        // V486 再 +procurement_order_qty_change_logs（227→228）。
        // V492 adds sales_order_revision_logs to the runtime reset policy.
        // V496 adds the append-only notification reversal ledger.
        // V504 adds all eight V500 value tables and three V503 source revision tables.
        // V547 +2（品质检查单头/明细）、V548 +1（登记撤回记录）：266→269。
        // V560 +3（退料事实）、V561 +1（分批谱系）、V568 +1（让料补供）、
        // V569 +2（在途转拨及撤销）：269→276；V570/V571 不新增业务表。
        // V579 再 +3 张 party 子表（联系方式/地址/跟进记录，PRESERVE）：96→99。
        // V586 补登记 V583 报工实耗表与 V584 车间直送三张表（两个建表迁移都漏了
        // 这一步，清库函数 fail-closed 会整体拒跑）：276→280。
        // V590 废弃车间偏好表（数据搬进货品表随 goods 保留）：PRESERVE 99→98。
        // V608 +2 报销，V614 +2 完结溯源，V615 +3 直送分配/流水/历史隔离：V618 +1 收仓确认，V619 +8 保管溯源：280→296。
        // V636 +2（委外回厂短交案件头/事件）：296→298。
        // V658 +2(服务端登录会话、再认证失败计数；清库后所有人重新登录)：298→300。
        assertThat(result.clearedTableCount()).isEqualTo(300);
        // V617 preserves expense settings; V624/V626/V627 preserve original import-source evidence.
        assertThat(result.preservedTableCount()).isEqualTo(102);
        // cleared_rows 只统计 CLEAR 表：2 条 outbox、1 条库存余额、1 条待核历史价值池。
        // refresh_tokens 属 PRESERVE，
        // 在终局校验后单独清空，不计入）
        assertThat(result.clearedRows()).isEqualTo(4);
        assertThat(result.authorizationEpochAfter()).isEqualTo(epochBefore + 1);

        // 业务事实清空 + identity 序列重启（TRUNCATE RESTART IDENTITY 的直接证据：
        // 清空后 nextval 从 1 重新开始）
        assertThat(countBusinessOutbox(dataSource)).isZero();
        assertLegacyValueAndQuantityClearedButMasterPreserved(dataSource);
        assertThat(nextPostingSeqValue(dataSource)).isEqualTo(1);

        // 保留主档：行数不变、五个金额字段全部归零
        assertThat(countUsers(dataSource)).isEqualTo(usersBefore);
        assertThat(countAccounts(dataSource)).isEqualTo(1);
        assertThat(countFullyZeroedAccounts(dataSource)).isEqualTo(1);
        assertThat(queryZeroedPaymentStyle(dataSource)).isEqualTo(1);

        // 全员下线：epoch 已递增、refresh_tokens 已清空
        assertThat(readEpoch(dataSource)).isEqualTo(epochBefore + 1);
        assertThat(countRefreshTokens(dataSource)).isZero();

        // 主档归零 UPDATE 不停审计：审计行有增长
        assertThat(countAuditLog(dataSource)).isGreaterThan(auditBefore);

        // —— 阶段三：清空后可再次执行（幂等可重复）——
        insertSeedBusinessOutboxRow(dataSource, (short) 1);
        var second = service.reset(UUID.randomUUID(), "superadmin");
        assertThat(second.clearedRows()).isEqualTo(1);
        assertThat(second.authorizationEpochAfter()).isEqualTo(epochBefore + 2);
        assertThat(service.lastResult(operator, attempt).authorizationEpochAfter())
                .isEqualTo(epochBefore + 1); // A later reset must not replace this exact receipt.
        RequestContextHolder.resetRequestAttributes();

        // Exercise the operator's actual psql script against this disposable
        // migrated database, with the required database and cluster identity.
        String systemIdentifier;
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT system_identifier::text FROM pg_control_system()")) {
            assertThat(rows.next()).isTrue();
            systemIdentifier = rows.getString(1);
        }
        insertSeedBusinessOutboxRow(dataSource, (short) 1);
        POSTGRES.copyFileToContainer(org.testcontainers.utility.MountableFile.forHostPath(
                java.nio.file.Path.of("ops", "reset_business_data.sql")), "/tmp/reset-under-test.sql");
        var scriptResult = POSTGRES.execInContainer("psql", "-X", "-U", POSTGRES.getUsername(),
                "-d", POSTGRES.getDatabaseName(), "-v", "ON_ERROR_STOP=1",
                "-v", "confirm=CLEAR_BUSINESS", "-v", "expected_database=" + POSTGRES.getDatabaseName(),
                "-v", "expected_system_identifier=" + systemIdentifier, "-f", "/tmp/reset-under-test.sql");
        assertThat(scriptResult.getExitCode()).withFailMessage(scriptResult.getStderr()).isZero();
        assertThat(countBusinessOutbox(dataSource)).isZero();
        assertThat(countUsers(dataSource)).isEqualTo(usersBefore);
        assertThat(countAccounts(dataSource)).isEqualTo(1);
    }

    /**
     * 2026-09-09 附件自动清理循环：预览阻塞 2→1→0 时 prepare 被调两次、排水删除队列后循环退出，
     * 物理删除文件数 = 前后 SUCCEEDED 删除任务差值并回显在结果里；库本身照常清空。
     */
    @Test
    void purgesBusinessAttachmentsUntilPreviewReportsNoBlockers() throws Exception {
        SimpleDriverDataSource dataSource = migratedDataSource();
        BusinessAttachmentResetPreparationPort attachmentReset =
                mock(BusinessAttachmentResetPreparationPort.class);
        when(attachmentReset.unpurgeableBlockers(any())).thenReturn(List.of());
        when(attachmentReset.preview(any())).thenReturn(
                new BusinessAttachmentResetPreparationPort.Preview("uten_imp", "fp-2", 2L, List.of(), false),
                new BusinessAttachmentResetPreparationPort.Preview("uten_imp", "fp-1", 1L, List.of(), false),
                new BusinessAttachmentResetPreparationPort.Preview("uten_imp", "fp-0", 0L, List.of(), false));
        when(attachmentReset.prepare(any(), anyString(), any())).thenReturn(
                new BusinessAttachmentResetPreparationPort.Preview("uten_imp", "fp-after", 1L, List.of(), false));
        // 第一轮排水 1 项后队列空；第二轮直接空（Mockito 连续桩最后一个值重复）。
        when(attachmentReset.drainNextDeletion()).thenReturn(true, false);
        when(attachmentReset.succeededDeletionCount()).thenReturn(10L, 13L);
        BusinessDataResetService service = newService(dataSource, attachmentReset);

        var result = service.reset(UUID.randomUUID(), "superadmin");

        assertThat(result.deletedAttachmentFiles()).isEqualTo(3);
        assertThat(result.clearedTableCount()).isPositive();
        verify(attachmentReset, times(3)).preview(any());
        verify(attachmentReset, times(2)).prepare(any(), anyString(), any());
        verify(attachmentReset, times(1)).cleanupAbandonedScratch();
    }

    /**
     * 自动清理消化不了的阻塞（LEGACY_UNVERIFIED / oss / 凭证未到期 / 删除失败达阈值）
     * 在排水之前直接 409：按原因分组计数 + 文件名 + 处置指引；不预览、不 prepare、不清库，
     * 且排水闸保持 IDLE（随后正常清空仍可执行）。
     */
    @Test
    void refusesBeforeDrainWhenAttachmentsCannotBePurgedAutomatically() throws Exception {
        SimpleDriverDataSource dataSource = migratedDataSource();
        BusinessAttachmentResetPreparationPort attachmentReset =
                mock(BusinessAttachmentResetPreparationPort.class);
        when(attachmentReset.unpurgeableBlockers(any())).thenReturn(List.of(
                new BusinessAttachmentResetPreparationPort.UnpurgeableGroup(
                        "原件状态为 LEGACY_UNVERIFIED，需先附件对账", 2L, List.of("合同A.pdf", "合同B.pdf")),
                new BusinessAttachmentResetPreparationPort.UnpurgeableGroup(
                        "上传凭证仍有效，需等待到期后重试", 1L, List.of("图纸.dwg"))));
        BusinessDataResetService service = newService(dataSource, attachmentReset);
        long epochBefore = readEpoch(dataSource);

        ApiException refused = assertThrows(ApiException.class,
                () -> service.reset(UUID.randomUUID(), "superadmin"));

        assertThat(refused.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(refused.getMessage())
                .contains("3 项无法自动清理")
                .contains("原件状态为 LEGACY_UNVERIFIED，需先附件对账 ×2")
                .contains("合同A.pdf")
                .contains("上传凭证仍有效，需等待到期后重试 ×1")
                .contains("处置指引");
        verify(attachmentReset, never()).preview(any());
        verify(attachmentReset, never()).prepare(any(), anyString(), any());
        assertThat(readEpoch(dataSource)).isEqualTo(epochBefore);

        // 排水闸未被占用：阻塞处置后同一服务可正常清空。
        when(attachmentReset.unpurgeableBlockers(any())).thenReturn(List.of());
        when(attachmentReset.preview(any())).thenReturn(
                new BusinessAttachmentResetPreparationPort.Preview("uten_imp", "fp-empty", 0L, List.of(), false));
        assertThat(service.reset(UUID.randomUUID(), "superadmin").authorizationEpochAfter())
                .isEqualTo(epochBefore + 1);
    }

    /**
     * ADR-067 §9 受理/失败回执：服务器从未收到的请求没有受理回执；排水前被拒绝的请求有受理回执
     * 和带原因的失败回执而没有完成回执；成功的请求有受理回执且由当前进程受理；受理进程与当前
     * 进程不同(重启)时 {@code attemptReceivedByCurrentServer=false}。别的操作者查不到这些回执。
     */
    @Test
    void attemptReceiptsDistinguishNeverReceivedRefusedAndCompletedRequests() throws Exception {
        SimpleDriverDataSource dataSource = migratedDataSource();
        BusinessAttachmentResetPreparationPort attachmentReset =
                mock(BusinessAttachmentResetPreparationPort.class);
        when(attachmentReset.unpurgeableBlockers(any())).thenReturn(List.of(
                new BusinessAttachmentResetPreparationPort.UnpurgeableGroup(
                        "原件状态为 LEGACY_UNVERIFIED，需先附件对账", 1L, List.of("合同A.pdf"))));
        BusinessDataResetService service = newService(dataSource, attachmentReset);
        var request = new MockHttpServletRequest("POST", "/api/system-test/business-data/reset");
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(request));
        UUID operator = UUID.randomUUID();
        UUID neverSent = UUID.randomUUID();
        UUID refusedAttempt = UUID.randomUUID();
        UUID completedAttempt = UUID.randomUUID();
        long auditBefore = countAuditLog(dataSource);

        var unknown = service.lastResult(operator, neverSent);
        assertThat(unknown.available()).isFalse();
        assertThat(unknown.attemptReceived()).isFalse();
        assertThat(unknown.attemptFailed()).isFalse();

        ApiException refused = assertThrows(ApiException.class,
                () -> service.reset(operator, "superadmin", refusedAttempt));
        assertThat(refused.getCode()).isEqualTo(ErrorCode.CONFLICT);
        var refusedReceipt = service.lastResult(operator, refusedAttempt);
        assertThat(refusedReceipt.available()).isFalse();
        assertThat(refusedReceipt.attemptReceived()).isTrue();
        assertThat(refusedReceipt.attemptReceivedAt()).isNotNull();
        assertThat(refusedReceipt.attemptReceivedByCurrentServer()).isTrue();
        assertThat(refusedReceipt.attemptFailed()).isTrue();
        assertThat(refusedReceipt.attemptFailureMessage()).contains("无法自动清理").contains("合同A.pdf");
        assertThat(countAuditLog(dataSource)).isEqualTo(auditBefore + 2);
        // 别的操作者查同一 attemptId：既无完成回执也无受理回执。
        assertThat(service.lastResult(UUID.randomUUID(), refusedAttempt).attemptReceived()).isFalse();

        when(attachmentReset.unpurgeableBlockers(any())).thenReturn(List.of());
        when(attachmentReset.preview(any())).thenReturn(
                new BusinessAttachmentResetPreparationPort.Preview("uten_imp", "fp-empty", 0L, List.of(), false));
        var result = service.reset(operator, "superadmin", completedAttempt);
        var completed = service.lastResult(operator, completedAttempt);
        assertThat(completed.available()).isTrue();
        assertThat(completed.attemptId()).isEqualTo(completedAttempt);
        assertThat(completed.clearedRows()).isEqualTo(result.clearedRows());
        assertThat(completed.attemptReceived()).isTrue();
        assertThat(completed.attemptReceivedByCurrentServer()).isTrue();
        assertThat(completed.attemptFailed()).isFalse();

        // 受理它的进程已经不在(模拟重启后另一实例)：仍有受理回执，但不属于当前进程。
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(
                     "UPDATE audit_log SET result = 'received,server=' || gen_random_uuid()::text WHERE action = 'business_data_reset_received' AND target_id = ?")) {
            statement.setString(1, refusedAttempt.toString());
            assertThat(statement.executeUpdate()).isEqualTo(1);
        }
        var restarted = service.lastResult(operator, refusedAttempt);
        assertThat(restarted.attemptReceived()).isTrue();
        assertThat(restarted.attemptReceivedByCurrentServer()).isFalse();
    }

    private static SimpleDriverDataSource migratedDataSource() {
        Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        return new SimpleDriverDataSource(
                new Driver(), POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private BusinessDataResetService newService(
            SimpleDriverDataSource dataSource, BusinessAttachmentResetPreparationPort attachmentReset) {
        return newService(dataSource, attachmentReset, new BusinessDataResetDrainGate());
    }

    private BusinessDataResetService newService(
            SimpleDriverDataSource dataSource, BusinessAttachmentResetPreparationPort attachmentReset,
            BusinessDataResetDrainGate drain) {
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan(AuditLog.class.getPackageName());
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none"));
        factory.afterPropertiesSet();
        EntityManagerFactory entityManagerFactory = factory.getObject();
        entityManagerFactories.add(entityManagerFactory);
        var transactions = new JpaTransactionManager(entityManagerFactory);
        assertThat(transactions.getDataSource()).isSameAs(dataSource);
        var entityManager = SharedEntityManagerCreator.createSharedEntityManager(entityManagerFactory);
        AuditLogRepository auditRepository = new JpaRepositoryFactory(entityManager)
                .getRepository(AuditLogRepository.class);
        var auditProxy = new ProxyFactory(new AuditService(
                auditRepository, new AuditDeviceContext(new ObjectMapper())));
        auditProxy.addAdvice(new TransactionInterceptor(
                (TransactionManager) transactions,
                new AnnotationTransactionAttributeSource()));
        return new BusinessDataResetService(
                dataSource,
                transactions,
                new BusinessDataResetFeatureGate(true),
                drain,
                (AuditService) auditProxy.getProxy(),
                attachmentReset);
    }

    private void installFailingReceiptTrigger(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection(); Statement statement = connection.createStatement()) {
            statement.execute("""
                    CREATE FUNCTION reset_receipt_commit_probe() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN
                        IF NEW.action = 'business_data_reset' THEN
                            IF current_setting('app.actor_id', true) IS DISTINCT FROM NEW.actor_id::text
                               OR EXISTS (SELECT 1 FROM business_outbox)
                               OR EXISTS (SELECT 1 FROM refresh_tokens)
                               OR (SELECT epoch::text FROM authorization_state WHERE singleton_id=1)
                                  IS DISTINCT FROM substring(NEW.result FROM 'epoch=([0-9]+)') THEN
                                RAISE EXCEPTION 'receipt must share the reset connection and transaction';
                            END IF;
                            RAISE EXCEPTION 'reset completion unavailable';
                        END IF;
                        RETURN NEW;
                    END $$
                    """);
            statement.execute("""
                    CREATE CONSTRAINT TRIGGER reset_receipt_commit_probe
                    AFTER INSERT ON audit_log DEFERRABLE INITIALLY DEFERRED
                    FOR EACH ROW EXECUTE FUNCTION reset_receipt_commit_probe()
                    """);
        }
    }

    private void removeFailingReceiptTrigger(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection(); Statement statement = connection.createStatement()) {
            statement.execute("DROP TRIGGER IF EXISTS reset_receipt_commit_probe ON audit_log");
            statement.execute("DROP FUNCTION IF EXISTS reset_receipt_commit_probe()");
        }
    }

    private void assertUnchangedMoneyAndStock(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection(); Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("""
                     SELECT (SELECT count(*) FROM accounts WHERE code='ACCT-TEST-1'
                         AND init_balance=100 AND receipts_total=200 AND payments_total=300
                         AND balance_adjustments_total=50 AND balance_current=50),
                         (SELECT count(*) FROM stock_balances WHERE qty=7 AND amount_local=999),
                         (SELECT count(*) FROM stock_value_pools WHERE legacy_qty=7 AND legacy_amount_local=999)
                     """)) {
            assertThat(rows.next()).isTrue();
            assertThat(rows.getInt(1)).isEqualTo(1);
            assertThat(rows.getInt(2)).isEqualTo(1);
            assertThat(rows.getInt(3)).isEqualTo(1);
        }
    }

    private void assertReceiptMetadata(SimpleDriverDataSource dataSource, UUID attempt,
            UUID session, UUID operation, UUID installation, UUID requestId) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement("""
                     SELECT session_id, client_event_id, device_installation_id, request_id,
                            ip, user_agent, device_platform, device_name, app_version, event_source,
                            http_method, http_path, device_profile_hash
                     FROM audit_log WHERE action='business_data_reset' AND target_id=?
                     """)) {
            statement.setString(1, attempt.toString());
            try (ResultSet rows = statement.executeQuery()) {
                assertThat(rows.next()).isTrue();
                assertThat(rows.getObject("session_id", UUID.class)).isEqualTo(session);
                assertThat(rows.getObject("client_event_id", UUID.class)).isEqualTo(operation);
                assertThat(rows.getObject("device_installation_id", UUID.class)).isEqualTo(installation);
                assertThat(rows.getObject("request_id", UUID.class)).isEqualTo(requestId);
                assertThat(rows.getString("ip")).isEqualTo("192.0.2.12");
                assertThat(rows.getString("user_agent")).isEqualTo("reset-receipt-test");
                assertThat(rows.getString("device_platform")).isEqualTo("windows");
                assertThat(rows.getString("device_name")).isEqualTo("Reset test device");
                assertThat(rows.getString("app_version")).isEqualTo("receipt-test");
                assertThat(rows.getString("event_source")).isEqualTo("business");
                assertThat(rows.getString("http_method")).isEqualTo("POST");
                assertThat(rows.getString("http_path")).isEqualTo("/api/system-test/business-data/reset");
                assertThat(rows.getString("device_profile_hash")).isNotBlank();
                assertThat(rows.next()).isFalse();
            }
        }
    }

    private void insertSeedDepartment(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO departments(code, name, level) VALUES ('TEST', '清空测试部', '一级部门')");
        }
    }

    private void insertSeedEmployee(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO employees(code, full_name, id_type, department_id, hire_date, status, employment_type) SELECT 'T0001', '清空测试员', '身份证', id, current_date, 'active', 'regular' FROM departments WHERE code = 'TEST'");
        }
    }

    private void insertSeedUser(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO users(employee_id, login_account, password_hash, must_change_password, status) SELECT id, 't0001', 'x', false, 'active' FROM employees WHERE code = 'T0001'");
        }
    }

    private void insertSeedRefreshToken(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO refresh_tokens(user_id, session_id, token_hash, expires_at) SELECT id, gen_random_uuid(), 'seed-hash', now() + interval '7 days' FROM users WHERE login_account = 't0001'");
        }
    }

    private void insertSeedBusinessOutboxRow(
            SimpleDriverDataSource dataSource, short status) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             PreparedStatement statement = connection.prepareStatement(
                     "INSERT INTO business_outbox(id, event_type, aggregate_type, dedupe_key, status) VALUES (gen_random_uuid(), 'TEST_EVENT', 'TEST_AGGREGATE', 'seed-' || gen_random_uuid()::text, ?)")) {
            statement.setShort(1, status);
            statement.executeUpdate();
        }
    }

    private void markSeedBusinessOutboxProcessed(SimpleDriverDataSource dataSource)
            throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("UPDATE business_outbox SET status = 1, processed_at = now()");
        }
    }

    private void insertSeedAccount(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO payment_styles(code, name, category, init_balance) VALUES ('999', '清空测试账户类别', 'ACCOUNT', 88)");
        }
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO currencies(code, name, exchange_rate, status) VALUES ('CNY-T', '清空测试币', 1, '使用')");
        }
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO accounts(name, code, account_type, style_id, currency_id, init_balance, receipts_total, payments_total, balance_adjustments_total, balance_current) SELECT '清空测试账户', 'ACCT-TEST-1', 'CASH', ps.id, c.id, 100, 200, 300, 50, 50 FROM payment_styles ps CROSS JOIN currencies c WHERE ps.code = '999' AND ps.category = 'ACCOUNT' AND c.code = 'CNY-T'");
        }
    }

    private long readEpoch(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(
                     "SELECT epoch FROM authorization_state WHERE singleton_id = 1")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private void insertSeedLegacyValuePool(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection(); Statement statement = connection.createStatement()) {
            statement.execute("INSERT INTO units(id,code,name) VALUES ('00500504-0000-0000-0000-000000000001','RESET-UNIT','reset piece')");
            statement.execute("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES ('00500504-0000-0000-0000-000000000002','RESET-GOODS','reset material','00500504-0000-0000-0000-000000000001',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))");
            statement.execute("INSERT INTO warehouses(id,code,name) VALUES ('00500504-0000-0000-0000-000000000003','RESET-WAREHOUSE','reset warehouse')");
            statement.execute("INSERT INTO stock_balances(id,warehouse_id,goods_id,qty,amount_local) VALUES ('00500504-0000-0000-0000-000000000004','00500504-0000-0000-0000-000000000003','00500504-0000-0000-0000-000000000002',7,999)");
            statement.execute("INSERT INTO stock_value_pools(id,warehouse_id,goods_id,state,legacy_balance_id,legacy_qty,legacy_amount_local) VALUES ('00500504-0000-0000-0000-000000000005','00500504-0000-0000-0000-000000000003','00500504-0000-0000-0000-000000000002','LEGACY_UNVERIFIED','00500504-0000-0000-0000-000000000004',7,999)");
        }
    }

    private void assertLegacyValueAndQuantityClearedButMasterPreserved(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection(); Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT (SELECT count(*) FROM stock_balances),(SELECT count(*) FROM stock_value_pools),(SELECT count(*) FROM goods WHERE id='00500504-0000-0000-0000-000000000002'),(SELECT count(*) FROM warehouses WHERE id='00500504-0000-0000-0000-000000000003')")) {
            rows.next();
            assertThat(rows.getInt(1)).isZero();
            assertThat(rows.getInt(2)).isZero();
            assertThat(rows.getInt(3)).isEqualTo(1);
            assertThat(rows.getInt(4)).isEqualTo(1);
        }
    }

    private long countBusinessOutbox(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM business_outbox")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long nextPostingSeqValue(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(
                     "SELECT nextval('finance_reconciliations_posting_seq_seq')")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countUsers(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM users")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countAccounts(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM accounts")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countFullyZeroedAccounts(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(
                     "SELECT count(*) FROM accounts WHERE init_balance = 0 AND receipts_total = 0 AND payments_total = 0 AND balance_adjustments_total = 0 AND balance_current = 0")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countRefreshTokens(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM refresh_tokens")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long queryZeroedPaymentStyle(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(
                     "SELECT count(*) FROM payment_styles WHERE code = '999' AND COALESCE(init_balance, 0) = 0")) {
            rows.next();
            return rows.getLong(1);
        }
    }

    private long countAuditLog(SimpleDriverDataSource dataSource) throws SQLException {
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery("SELECT count(*) FROM audit_log")) {
            rows.next();
            return rows.getLong(1);
        }
    }
}
