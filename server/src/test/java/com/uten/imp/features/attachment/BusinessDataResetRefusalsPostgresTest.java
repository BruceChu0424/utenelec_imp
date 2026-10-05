package com.uten.imp.features.attachment;

import com.uten.imp.application.port.BusinessTestResetFilesPort;
import com.uten.imp.application.port.BusinessTestResetFilesPort.Check;
import com.uten.imp.application.port.BusinessTestResetFilesPort.DeadEvents;
import com.uten.imp.application.port.BusinessTestResetFilesPort.KindCount;
import com.uten.imp.application.port.BusinessTestResetFilesPort.Purge;
import com.uten.imp.application.port.BusinessTestResetFilesPort.Refusal;
import com.uten.imp.common.storage.InternalStorageService;
import com.uten.imp.common.storage.LocalDiskStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.admin.systemtest.BusinessDataResetService;
import com.uten.imp.features.admin.systemtest.BusinessDataResetTimings;
import com.uten.imp.features.admin.systemtest.SystemTestController;
import com.uten.imp.features.attachment.ResetEndToEndFixture.Intake;
import com.uten.imp.features.attachment.ResetEndToEndFixture.Stored;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.test.util.ReflectionTestUtils;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Every refusal and every failure path of "clear business data" through the real reset (ADR-155):
 * real internal/local storage, real database rules, real service. Unless a case says otherwise, a
 * refusal must name the problem exactly, delete nothing, leave the data and generation unchanged and
 * release the drain gate; removing the cause then lets the same reset succeed.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessDataResetRefusalsPostgresTest {
    private static final String HEADING = BusinessTestResetFilesPort.STORAGE_CHECK_HEADING;
    private static final Pattern INTERNAL_KEY = Pattern.compile("i1_([A-Z][A-Z0-9_]{0,63})_([0-9]{6})_(.+)");

    @TempDir Path files;
    ResetEndToEndFixture f;
    BusinessDataResetService service;

    @BeforeEach
    void start() throws Exception {
        f = ResetEndToEndFixture.open("reset_refusals", files);
        service = f.service();
    }

    @AfterEach
    void stop() throws Exception {
        if (f != null) f.close();
    }

    // ------------------------------------------------------------------ database refusals (A)

    @Test
    void queuedBackgroundEventRefusesBeforeDrainingThenTheSameResetSucceeds() throws Exception {
        Stored file = present("排队时的报价.pdf");
        long generation = f.generation();
        f.jdbc.update("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status,available_at) VALUES(gen_random_uuid(),'SALES_ORDER_CONFIRMED','SALES_ORDER','refusal-'||gen_random_uuid(),0,now()+interval '150 seconds')");
        String a1 = "后台还有 1 条事件正在排队处理(消息通知、单据联动等)，预计 3 分钟内处理完。现在清空会丢掉这些处理结果，请 3 分钟后点「重新检查」再清空；"
                + "如果多次重新检查仍在排队，请联系开发人员检查后台事件处理。";
        Check preview = service.preview(f.admin, f.adminAccount);
        assertThat(preview.refusals()).containsExactly(new Refusal("BACKGROUND_EVENTS_PENDING", 1, a1));
        assertThat(preview.presentFiles()).as("the storage check still runs").isEqualTo(1);
        UUID attempt = UUID.randomUUID();
        assertRefused(service, attempt, ErrorCode.CONFLICT, a1);
        assertUnchanged(generation, file);
        assertThat(service.lastResult(f.admin, attempt).attemptFailureMessage()).isEqualTo(
                "失败原因：后台事件排队中 1 条。没有删除文件，也没有清空数据。完整原因(含文件名)请在清空弹窗点「重新检查」查看。");
        f.jdbc.update("UPDATE business_outbox SET status=1, processed_at=now()");
        assertThat(service.reset(f.admin, f.adminAccount, UUID.randomUUID()).deletedAttachmentFiles()).isEqualTo(1);
        assertThat(f.finalExists(file.key())).isFalse();
    }

    @Test
    void fileOnStorageTheSystemCannotDeleteRefusesUntilItIsRecordedAsDeleted() {
        String key = key(".pdf");
        UUID id = rawAttachment("SALES_QUOTE", "oss", key, "oss-v1", "阿里云旧附件.pdf", "CLEAN");
        String a2 = "有 1 个测试文件存放在系统无法删除的位置，清空不能把它们一并删除：「阿里云旧附件.pdf」(业务附件, 正式文件, 旧阿里云存储)。"
                + "系统里没有删除这类文件的功能，需要开发人员处理：确认这些文件在原存储上已经删除(或已迁移到内部存储)后，在数据库里把它们登记为已删除，然后回到这里点「重新检查」。";
        long generation = f.generation();
        assertRefused(service, UUID.randomUUID(), ErrorCode.CONFLICT, a2);
        assertUnchanged(generation);
        // What a developer does after confirming the original is gone: record the completed deletion.
        f.jdbc.update("UPDATE attachments SET lifecycle_state='DELETED' WHERE id=?", id);
        f.jdbc.update("""
                INSERT INTO attachment_object_outbox(attachment_id,operation,storage_provider,storage_key,storage_version,dedupe_key,status,attempts,completed_at)
                VALUES(?,'DELETE_FINAL','oss',?,'oss-v1',?,'SUCCEEDED',1,now())
                """, id, key, "oss|DELETE_FINAL|" + key + "|oss-v1");
        assertThat(service.preview(f.admin, f.adminAccount).refusals()).isEmpty();
        assertThat(service.reset(f.admin, f.adminAccount, UUID.randomUUID()).deletedAttachmentFiles()).isZero();
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM attachments", Long.class)).isZero();
    }

    @Test
    void unclassifiedTableIsAProgramVersionProblemAndSkipsTheStorageCheck() {
        Stored file = present("未分类时的附件.pdf");
        f.jdbc.execute("CREATE TABLE public.reset_probe_unclassified(id integer)");
        String a4 = "数据库里有 1 张数据表没有登记清空时要清除还是保留(数据表：reset_probe_unclassified)。这是程序版本问题(新增数据表时漏了登记)，请联系开发人员修复后再清空。";
        Check preview = service.preview(f.admin, f.adminAccount);
        assertThat(preview.refusals()).containsExactly(new Refusal("CATALOG_UNCLASSIFIED", 1, a4));
        assertThat(preview.inspectionComplete()).isFalse();
        assertThat(preview.inspectionSkipped()).as("not checked at all, which is not \"too many files\"").isTrue();
        assertThat(preview.inspectedObjects()).isZero();
        long generation = f.generation();
        assertRefused(service, UUID.randomUUID(), ErrorCode.CONFLICT, a4);
        assertUnchanged(generation, file);
        f.jdbc.execute("DROP TABLE public.reset_probe_unclassified");
        Check fixed = service.preview(f.admin, f.adminAccount);
        assertThat(fixed.inspectionSkipped()).isFalse();
        assertThat(fixed.inspectionComplete()).isTrue();
        assertThat(service.reset(f.admin, f.adminAccount, UUID.randomUUID()).deletedAttachmentFiles()).isEqualTo(1);
    }

    @Test
    void underTheLocksAKnownReasonIsReportedInsteadOfRunningOutOfTime() {
        Stored file = present("锁内核对时的附件.pdf");
        // A catalog problem skips the storage check: the reason is the catalog, not the time limit.
        f.jdbc.execute("CREATE TABLE public.reset_probe_unclassified(id integer)");
        String a4 = "数据库里有 1 张数据表没有登记清空时要清除还是保留(数据表：reset_probe_unclassified)。这是程序版本问题(新增数据表时漏了登记)，请联系开发人员修复后再清空。";
        ApiException catalog = purgeWithExpiredDeadline();
        assertThat(catalog.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(catalog.getMessage()).isEqualTo(a4);
        f.jdbc.execute("DROP TABLE public.reset_probe_unclassified");
        // A database refusal that appears after the check before draining is not hidden by the time limit.
        f.jdbc.update("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status,available_at) VALUES(gen_random_uuid(),'SALES_ORDER_CONFIRMED','SALES_ORDER','late-'||gen_random_uuid(),0,now())");
        ApiException queued = purgeWithExpiredDeadline();
        assertThat(queued.getMessage()).startsWith("后台还有 1 条事件正在排队处理");
        f.jdbc.update("UPDATE business_outbox SET status=1, processed_at=now()");
        // Without any reason the time limit is reported as such; nothing was deleted in any case.
        assertThat(purgeWithExpiredDeadline().getMessage()).startsWith("核对测试文件用完了这次的时间(已核对 0 / 1 个)");
        assertThat(f.finalExists(file.key())).isTrue();
    }

    @Test
    void persistentTableWithTheResetTempTableNameStopsTheCallerCheck() {
        f.jdbc.execute("CREATE TABLE public.reset_business_table_policy(id integer)");
        String f4 = "数据库里出现了与清空程序内部临时表同名的数据表(reset_business_ 开头)，清空程序不能安全运行。这是数据库被人为改动或程序缺陷，请联系开发人员处理。本次没有删除任何文件，也没有清空数据。";
        assertThat(api(() -> service.preview(f.admin, f.adminAccount))).satisfies(error -> {
            assertThat(error.getCode()).isEqualTo(ErrorCode.RESET_SERVER_MISCONFIGURED);
            assertThat(error.getCode().getHttpStatus()).isEqualTo(500);
            assertThat(error.getMessage()).isEqualTo(f4);
        });
        long generation = f.generation();
        UUID attempt = UUID.randomUUID();
        assertRefused(service, attempt, ErrorCode.RESET_SERVER_MISCONFIGURED, f4);
        assertUnchanged(generation);
        // This reason is never visible through "check again": the receipt keeps the server text.
        assertThat(service.lastResult(f.admin, attempt).attemptFailureMessage()).isEqualTo(
                "失败原因：数据库里出现了与清空程序内部临时表同名的数据表(reset_business_ 开头)，清空程序不能安全运行。这是数据库被人为改动或程序缺陷。"
                        + "没有删除文件，也没有清空数据。再次提交也会失败，请联系开发人员处理后再清空。");
        f.jdbc.execute("DROP TABLE public.reset_business_table_policy");
        assertThat(service.preview(f.admin, f.adminAccount).refusals()).isEmpty();
    }

    // ------------------------------------------------------------------ server configuration and storage check (J, B)

    @Test
    void storageNotConfiguredOnThisServerIsNamedPerProvider() throws Exception {
        String localKey = key(".xlsx");
        f.jdbc.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key,status)
                VALUES('DELETE_STAGING','local',?,NULL,?,'PENDING')
                """, localKey, "local|DELETE_STAGING|" + localKey + "|<local>");
        String b2 = "1 个文件登记在本地文件目录，但这台服务器没有配置本地文件目录，无法确认它们还在不在：「未登记文件名, 存储编号 " + localKey + "」(删除任务, 暂存副本)。"
                + "请让维护人员在服务器配置里填写本地文件目录(UTEN_STORAGE_LOCAL_DIR，下面要有 staging 和 final 两个子目录)后点「重新检查」。";
        assertThat(service.preview(f.admin, f.adminAccount).refusals()).containsExactly(new Refusal("LOCAL_NOT_CONFIGURED", 1, b2));
        assertRefused(service, UUID.randomUUID(), ErrorCode.CONFLICT, HEADING + "\n" + b2);
        f.jdbc.update("DELETE FROM attachment_object_outbox WHERE storage_key=?", localKey);

        // A server whose active storage is local, with no internal root, cannot confirm internal files.
        Stored internalFile = present("内部存储上的附件.pdf");
        Path localRoot = Files.createDirectories(files.resolve("active-local"));
        Files.createDirectories(localRoot.resolve("staging"));
        Files.createDirectories(localRoot.resolve("final"));
        var properties = new StorageProperties();
        properties.setProvider("local");
        properties.setLocalDir(localRoot.toRealPath().toString());
        var local = new LocalDiskStorageService(properties);
        ReflectionTestUtils.invokeMethod(local, "init");
        @SuppressWarnings("unchecked")
        ObjectProvider<InternalStorageService> none = mock(ObjectProvider.class);
        var localServer = f.service(new BusinessTestResetFiles(f.jdbc, new StorageProviderRegistry(local, properties), properties,
                f.transactions, none), BusinessDataResetTimings.DEFAULT);
        String b2b = "1 个文件登记在内部存储，但这台服务器没有配置可用的内部存储目录，无法确认它们还在不在：「内部存储上的附件.pdf」(业务附件, 正式文件)。"
                + "请让维护人员在服务器配置里填写内部存储目录(UTEN_INTERNAL_STORAGE_ROOT)后点「重新检查」。";
        long generation = f.generation();
        assertRefused(localServer, UUID.randomUUID(), ErrorCode.CONFLICT, HEADING + "\n" + b2b);
        assertUnchanged(generation, internalFile);
    }

    @Test
    void directUploadToOssIsRefusedBecauseUploadsBypassThisSystem() {
        Stored file = present("阿里云直传期间的附件.pdf");
        f.properties.setProvider("oss");
        String j1 = "这台服务器的附件直接上传到阿里云，上传过程不经过本系统，清空时无法确认没有正在上传的测试文件。"
                + "测试服务器应使用内部存储：请让维护人员把附件存储改为内部存储(UTEN_STORAGE_PROVIDER=internal)后再清空。";
        assertThat(service.preview(f.admin, f.adminAccount).refusals()).containsExactly(new Refusal("ACTIVE_STORAGE_OSS", 0, j1));
        long generation = f.generation();
        assertRefused(service, UUID.randomUUID(), ErrorCode.CONFLICT, j1);
        assertUnchanged(generation, file);
    }

    @Test
    void replacedFileContentIsNeverDeleted() {
        Stored stored = f.storeFinal("SALES_QUOTE", "被替换的合同.pdf");
        insertAttachment(stored, "internal-v1:" + "0".repeat(64), "被替换的合同.pdf");
        String b3 = "1 个文件在存储里的内容和登记的不是同一份(文件被替换过)，系统不会删除它们：「被替换的合同.pdf」(业务附件, 正式文件)。需要开发人员核对哪一份是对的并处理，然后点「重新检查」。";
        long generation = f.generation();
        assertRefused(service, UUID.randomUUID(), ErrorCode.CONFLICT, HEADING + "\n" + b3);
        assertUnchanged(generation, stored);
    }

    @Test
    void offlineStorageDirectoryIsNeverTakenAsAbsentAndTheResetSucceedsOnceItIsBack() throws Exception {
        Stored file = present("存储盘离线时的附件.pdf");
        Path finals = f.root.resolve("final"), parked = f.root.resolve("final-offline");
        Files.move(finals, parked);
        String b1 = "服务器上的附件存储目录现在无法访问(存储报告：内部存储目录缺失或身份异常，请核验后重试)，涉及 1 个文件：「存储盘离线时的附件.pdf」(业务附件, 正式文件)。"
                + "请让维护人员检查服务器的附件存储盘(是否挂载、目录是否被改动)后点「重新检查」。";
        long generation = f.generation();
        try {
            assertRefused(service, UUID.randomUUID(), ErrorCode.CONFLICT, HEADING + "\n" + b1);
            assertUnchanged(generation);
        } finally {
            Files.move(parked, finals);
        }
        assertThat(f.finalExists(file.key())).isTrue();
        assertThat(service.reset(f.admin, f.adminAccount, UUID.randomUUID()).deletedAttachmentFiles()).isEqualTo(1);
    }

    @Test
    void somethingThatIsNotASystemFileAtTheLocationIsLeftAlone() throws Exception {
        Stored directory = present("目录占位.pdf");
        Path directoryPath = finalPath(directory.key());
        Files.delete(directoryPath);
        Files.createDirectory(directoryPath);
        Stored foreign = present("外来文件.pdf");
        Files.write(finalPath(foreign.key()), "a file someone copied here by hand".getBytes(StandardCharsets.UTF_8));
        long generation = f.generation();
        ApiException refused = refusedReset(service, UUID.randomUUID());
        assertThat(refused.getMessage()).startsWith(HEADING + "\n2 个文件的存储位置上放的不是系统写入的文件(")
                .contains("是目录或其它特殊文件", "文件头不是系统写入的格式", "「目录占位.pdf」(业务附件, 正式文件)", "「外来文件.pdf」(业务附件, 正式文件)")
                .endsWith("请让维护人员检查服务器上的这些位置(可能被人手工放入或改动过)，移走后点「重新检查」。");
        assertUnchanged(generation);
        assertThat(Files.isDirectory(directoryPath)).isTrue();
        assertThat(Files.readString(finalPath(foreign.key()))).isEqualTo("a file someone copied here by hand");
    }

    @Test
    void flatHistoricalLocalFileIsNotGuessed() throws Exception {
        Path local = files.resolve("local");
        Files.createDirectories(local.resolve("staging"));
        Files.createDirectories(local.resolve("final"));
        f.properties.setLocalDir(local.toRealPath().toString());
        String key = key(".pdf");
        rawAttachment("SALES_QUOTE", "local", key, null, "旧版平铺文件.pdf", "CLEAN");
        Files.writeString(local.resolve(key), "flat historical bytes");
        String b5 = "1 个文件在本地文件目录里还按旧版方式直接放在根目录下，系统无法确认是哪一份：「旧版平铺文件.pdf」(业务附件, 正式文件)。"
                + "需要开发人员在服务器上核对后把它们移到 final 子目录或删除，然后点「重新检查」。";
        long generation = f.generation();
        assertRefused(service, UUID.randomUUID(), ErrorCode.CONFLICT, HEADING + "\n" + b5);
        assertUnchanged(generation);
        assertThat(Files.readString(local.resolve(key))).isEqualTo("flat historical bytes");
    }

    // ------------------------------------------------------------------ dead background events (D7)

    @Test
    void deadBackgroundEventsAreClearedAndReportedByCategory() {
        f.jdbc.update("INSERT INTO business_outbox(id,event_type,aggregate_type,dedupe_key,status,attempts) VALUES(gen_random_uuid(),'STOCK_WEIGHT_OBSERVATION_CHANGED','GOODS','dead-'||gen_random_uuid(),2,8),(gen_random_uuid(),'SALES_ORDER_CONFIRMED','SALES_ORDER','dead-'||gen_random_uuid(),2,8)");
        Check preview = service.preview(f.admin, f.adminAccount);
        assertThat(preview.refusals()).isEmpty();
        assertThat(preview.deadBackgroundEvents()).containsExactly(new DeadEvents("货品单重重算", 1), new DeadEvents("销售相关", 1));
        var result = service.reset(f.admin, f.adminAccount, UUID.randomUUID());
        assertThat(result.deadBackgroundEventsCleared()).isEqualTo(2);
        assertThat(service.lastResult().deadBackgroundEventsCleared()).isEqualTo(2);
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM business_outbox", Long.class)).isZero();
    }

    // ------------------------------------------------------------------ time limits and failures after deletion (C, D, W)

    @Test
    void checkThatRunsOutOfTimeDeletesNothing() {
        Stored file = present("核对超时的附件.pdf");
        var hurried = f.service(f.files(), new BusinessDataResetTimings(Duration.ofMillis(1), Duration.ofSeconds(60),
                Duration.ofSeconds(20), Duration.ofSeconds(45), Duration.ofSeconds(15)));
        long generation = f.generation();
        assertRefused(hurried, UUID.randomUUID(), ErrorCode.CONFLICT,
                "核对测试文件用完了这次的时间(已核对 0 / 1 个)，没有删除任何文件，也没有清空数据。如果服务器存储正忙，请稍后重新点「确认清空」；"
                        + "如果多次出现，说明测试文件太多(1 个)，一次清空处理不完，请联系开发人员。");
        assertUnchanged(generation, file);
    }

    @Test
    void deleteBudgetLeavesAnHonestPartialResultAndTheRetryConverges() {
        List<Stored> stored = new ArrayList<>();
        for (int i = 0; i < 6; i++) stored.add(present("慢速存储附件" + i + ".pdf"));
        var slow = new DelegatingTestStorage(f.internal, number -> sleep(1000));
        var limited = f.service(f.files(new StorageProviderRegistry(slow, f.properties)), new BusinessDataResetTimings(
                Duration.ofMillis(3000), Duration.ofSeconds(60), Duration.ofSeconds(20), Duration.ofSeconds(45), Duration.ofSeconds(15)));
        long generation = f.generation();
        UUID attempt = UUID.randomUUID();
        ApiException partial = refusedReset(limited, attempt);
        long deleted = stored.stream().filter(s -> !f.finalExists(s.key())).count();
        assertThat(deleted).isBetween(1L, 5L);
        assertThat(partial.getMessage()).isEqualTo("本次已经物理删除了 " + deleted + " 个测试文件(无法恢复)，但业务数据没有清空，所以这些测试单据上的附件现在打不开。"
                + "原因：删除测试文件用完了这次清空的时间，还有 " + (6 - deleted) + " 个没有删除。请重新点「确认清空」继续删除剩下的。已删除的文件下次不会重复处理。");
        assertThat(f.generation()).isEqualTo(generation);
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM attachments", Long.class)).isEqualTo(6);
        var receipt = service.lastResult(f.admin, attempt);
        assertThat(receipt.attemptDeletedAttachmentFiles()).isEqualTo(deleted);
        assertThat(receipt.attemptFailureMessage()).isEqualTo("失败原因：删除用完时间。本次已物理删除 " + deleted
                + " 个测试文件，数据没有清空。完整原因(含文件名)请在清空弹窗点「重新检查」查看。");
        assertThat(f.drain.blockingNewRequests()).isFalse();
        var retry = service.reset(f.admin, f.adminAccount, UUID.randomUUID());
        assertThat(retry.deletedAttachmentFiles() + deleted).isEqualTo(6);
        assertThat(stored).noneMatch(s -> f.finalExists(s.key()));
    }

    @Test
    void storageErrorWhileDeletingIsReportedWithTheDeletedCount() {
        for (int i = 0; i < 3; i++) present("删除报错附件" + i + ".pdf");
        String second = f.jdbc.queryForObject("SELECT display_label FROM fn_business_test_reset_objects() ORDER BY object_identity OFFSET 1 LIMIT 1", String.class);
        var failing = new DelegatingTestStorage(f.internal, number -> {
            if (number == 2) throw new IllegalStateException("simulated storage failure");
        });
        var broken = f.service(f.files(new StorageProviderRegistry(failing, f.properties)), BusinessDataResetTimings.DEFAULT);
        long generation = f.generation();
        UUID attempt = UUID.randomUUID();
        assertRefused(broken, attempt, ErrorCode.CONFLICT, "本次已经物理删除了 1 个测试文件(无法恢复)，但业务数据没有清空，所以这些测试单据上的附件现在打不开。"
                + "原因：删除" + second + "时存储报错(读写出错)。请让维护人员检查服务器存储后重新点「确认清空」。已删除的文件下次不会重复处理。");
        assertThat(f.generation()).isEqualTo(generation);
        assertThat(service.lastResult(f.admin, attempt).attemptDeletedAttachmentFiles()).isEqualTo(1);
        assertThat(service.reset(f.admin, f.adminAccount, UUID.randomUUID()).deletedAttachmentFiles()).isEqualTo(2);
    }

    @Test
    void lockedFileSourcesStopTheResetBeforeAnyDelete() throws Exception {
        Stored file = present("被占用时的附件.pdf");
        var patient = f.service(f.files(), new BusinessDataResetTimings(Duration.ofMinutes(5), Duration.ofSeconds(60),
                Duration.ofSeconds(20), Duration.ofSeconds(45), Duration.ofSeconds(1)));
        long generation = f.generation();
        try (Connection writer = f.dataSource.getConnection()) {
            writer.setAutoCommit(false);
            writer.createStatement().execute("LOCK TABLE public.attachments IN ROW EXCLUSIVE MODE");
            assertRefused(patient, UUID.randomUUID(), ErrorCode.CONFLICT,
                    "有其他程序正在使用附件相关数据(可能是后台任务或另一台服务器)，等了 1 秒仍没有结束；本次没有删除任何文件，也没有清空数据。请稍后重新点「确认清空」。");
            writer.rollback();
        }
        assertUnchanged(generation, file);
    }

    @Test
    void failuresInsideTheResetFunctionAfterDeletionStartWithTheDeletedCount() throws Exception {
        Stored first = present("指纹不一致时的附件.pdf");
        BusinessTestResetFilesPort real = f.files();
        BusinessTestResetFilesPort wrongFingerprint = new BusinessTestResetFilesPort() {
            @Override public Check check(Actor actor, Duration budget) { return real.check(actor, budget); }
            @Override public Purge purge(Instant deadline, AtomicLong deleted) {
                Purge purge = real.purge(deadline, deleted);
                return new Purge("999:" + "f".repeat(64), purge.deletedFiles(), purge.deadBackgroundEvents());
            }
            @Override public int cleanupAbandonedScratch() { return 0; }
        };
        long generation = f.generation();
        UUID changedSet = UUID.randomUUID();
        assertRefused(f.service(wrongFingerprint, BusinessDataResetTimings.DEFAULT), changedSet, ErrorCode.CONFLICT,
                "本次已经物理删除了 1 个测试文件(无法恢复)，但业务数据没有清空，所以这些测试单据上的附件现在打不开。"
                        + "原因：清空前核对的测试文件清单(999 个)和清空时数据库里的清单(1 个)不一致，这是程序缺陷。本次没有清空任何数据，请联系开发人员。"
                        + "已删除的文件下次不会重复处理。");
        assertThat(f.finalExists(first.key())).isFalse();
        assertThat(f.generation()).isEqualTo(generation);
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM attachments", Long.class)).isEqualTo(1);
        // Not visible through "check again": the receipt keeps the cause and ends with the next step.
        assertThat(service.lastResult(f.admin, changedSet).attemptFailureMessage()).isEqualTo(
                "失败原因：清空前核对的测试文件清单(999 个)和清空时数据库里的清单(1 个)不一致，这是程序缺陷。"
                        + "本次已物理删除 1 个测试文件，数据没有清空。请联系开发人员。");

        // Any other database error inside the reset function is a definite failure (rolled back), not
        // "outcome uncertain", and still starts with the number of files already deleted.
        Stored third = present("清空函数出错时的附件.pdf");
        f.jdbc.execute("CREATE FUNCTION public.reset_probe_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'reset probe failure'; END $$");
        f.jdbc.execute("CREATE TRIGGER zz_reset_probe_failure BEFORE DELETE ON public.attachments FOR EACH ROW EXECUTE FUNCTION public.reset_probe_failure()");
        UUID failedInside = UUID.randomUUID();
        try {
            assertRefused(service, failedInside, ErrorCode.INTERNAL,
                    "本次已经物理删除了 1 个测试文件(无法恢复)，但业务数据没有清空，所以这些测试单据上的附件现在打不开。"
                            + "原因：业务数据清空执行失败，已整体回滚：reset probe failure。请重新点「确认清空」；如果再次出现，请联系开发人员。"
                            + "已删除的文件下次不会重复处理。");
        } finally {
            f.jdbc.execute("DROP TRIGGER zz_reset_probe_failure ON public.attachments");
            f.jdbc.execute("DROP FUNCTION public.reset_probe_failure()");
        }
        assertThat(f.finalExists(third.key())).isFalse();
        assertThat(f.generation()).isEqualTo(generation);
        var receipt = service.lastResult(f.admin, failedInside);
        assertThat(receipt.attemptDeletedAttachmentFiles()).isEqualTo(1);
        assertThat(receipt.attemptFailureMessage()).isEqualTo(
                "失败原因：业务数据清空执行失败，已整体回滚：reset probe failure。"
                        + "本次已物理删除 1 个测试文件，数据没有清空。请稍后重新点「确认清空」；如果再次出现，请联系开发人员。");

        Stored second = present("清空函数等锁时的附件.pdf");
        var patient = f.service(f.files(), new BusinessDataResetTimings(Duration.ofMinutes(5), Duration.ofSeconds(60),
                Duration.ofSeconds(20), Duration.ofSeconds(45), Duration.ofSeconds(1)));
        try (Connection reader = f.dataSource.getConnection()) {
            reader.setAutoCommit(false);
            reader.createStatement().executeQuery("SELECT count(*) FROM public.sales_orders").close();
            assertRefused(patient, UUID.randomUUID(), ErrorCode.CONFLICT,
                    "本次已经物理删除了 1 个测试文件(无法恢复)，但业务数据没有清空，所以这些测试单据上的附件现在打不开。"
                            + "原因：清空数据时有其他程序占用了数据表，等了 1 秒仍没有结束。请稍后重新点「确认清空」；如果再次出现，请联系开发人员。"
                            + "已删除的文件下次不会重复处理。");
            reader.rollback();
        }
        assertThat(f.finalExists(second.key())).isFalse();
        assertThat(f.generation()).isEqualTo(generation);
        // Already deleted files are absent now: the retry converges without deleting anything again.
        assertThat(service.reset(f.admin, f.adminAccount, UUID.randomUUID()).deletedAttachmentFiles()).isZero();
        assertThat(f.generation()).isEqualTo(generation + 1);
    }

    // ------------------------------------------------------------------ concurrency (E1a, adoption races)

    @Test
    void secondResetIsRefusedImmediatelyWithoutAReceipt() throws Exception {
        Stored file = present("并发清空时的附件.pdf");
        CountDownLatch reached = new CountDownLatch(1), release = new CountDownLatch(1);
        var pausing = new DelegatingTestStorage(f.internal, number -> { reached.countDown(); await(release); });
        var first = f.service(f.files(new StorageProviderRegistry(pausing, f.properties)), BusinessDataResetTimings.DEFAULT);
        String e1a = "另一位超级管理员正在清空业务数据，请等它完成后再操作(完成后所有人都需要重新登录)。本次没有删除任何文件，也没有清空数据。";
        try (var executor = Executors.newSingleThreadExecutor()) {
            Future<BusinessDataResetService.Result> running = executor.submit(() -> first.reset(f.admin, f.adminAccount, UUID.randomUUID()));
            try {
                assertThat(reached.await(60, TimeUnit.SECONDS)).isTrue();
                UUID secondAttempt = UUID.randomUUID();
                ApiException second = api(() -> service.reset(f.admin, f.adminAccount, secondAttempt));
                assertThat(second.getCode()).isEqualTo(ErrorCode.CONFLICT);
                assertThat(second.getMessage()).isEqualTo(e1a);
                assertThat(f.drain.blockingNewRequests()).as("the refused second reset leaves the first one's gate alone").isTrue();
                assertThat(service.lastResult(f.admin, secondAttempt).attemptReceived()).as("refused before the receipt").isFalse();
                assertThat(api(() -> service.preview(f.admin, f.adminAccount)).getMessage()).isEqualTo(e1a);
            } finally {
                release.countDown();
            }
            assertThat(running.get(60, TimeUnit.SECONDS).deletedAttachmentFiles()).isEqualTo(1);
        }
        assertThat(f.finalExists(file.key())).isFalse();
    }

    @Test
    void adoptionCommittedWhileTheResetWaitsForTheLockKeepsTheAdoptedFile() throws Exception {
        Intake intake = f.aiIntake("带模板的询价单.xlsx");
        Stored candidate = f.stageCandidate(intake.job(), "模板.xlsx", "adopt-before");
        while (f.outboxWorker.processNext()) { }
        UUID template = customerTemplate();
        try (Connection adopt = f.dataSource.getConnection(); var executor = Executors.newSingleThreadExecutor()) {
            adopt.setAutoCommit(false);
            try (var select = adopt.prepareStatement("SELECT c.storage_key FROM sales_quote_template_candidates c WHERE c.job_id=? FOR UPDATE OF c")) {
                select.setObject(1, intake.job());
                try (var rows = select.executeQuery()) { assertThat(rows.next()).isTrue(); }
            }
            Future<BusinessDataResetService.Result> running = executor.submit(() -> service.reset(f.admin, f.adminAccount, UUID.randomUUID()));
            awaitLockWait("sales_quote_template_candidates");
            insertVersion(adopt, template, candidate);
            adopt.commit();
            running.get(60, TimeUnit.SECONDS);
        }
        assertThat(f.finalExists(candidate.key())).as("the adopted version protects its file").isTrue();
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_versions WHERE storage_key=?", Long.class, candidate.key())).isEqualTo(1);
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_candidates", Long.class)).isZero();
        assertThat(f.finalExists(intake.key())).isFalse();
    }

    @Test
    void adoptionThatStartsWhileTheResetHoldsTheLocksFindsNoCandidate() throws Exception {
        Intake intake = f.aiIntake("带模板的询价单.xlsx");
        Stored candidate = f.stageCandidate(intake.job(), "模板.xlsx", "adopt-after");
        while (f.outboxWorker.processNext()) { }
        UUID template = customerTemplate();
        CountDownLatch reached = new CountDownLatch(1), release = new CountDownLatch(1);
        var pausing = new DelegatingTestStorage(f.internal, number -> { if (number == 1) { reached.countDown(); await(release); } });
        var holding = f.service(f.files(new StorageProviderRegistry(pausing, f.properties)), BusinessDataResetTimings.DEFAULT);
        try (var executor = Executors.newFixedThreadPool(2); Connection adopt = f.dataSource.getConnection()) {
            Future<BusinessDataResetService.Result> running = executor.submit(() -> holding.reset(f.admin, f.adminAccount, UUID.randomUUID()));
            Future<Integer> adoption;
            try {
                assertThat(reached.await(60, TimeUnit.SECONDS)).isTrue();
                adopt.setAutoCommit(false);
                adopt.createStatement().execute("SET LOCAL lock_timeout = '60s'");
                adoption = executor.submit(() -> {
                    try (var select = adopt.prepareStatement("SELECT c.storage_key FROM sales_quote_template_candidates c WHERE c.job_id=? FOR UPDATE OF c")) {
                        select.setObject(1, intake.job());
                        try (var rows = select.executeQuery()) {
                            if (!rows.next()) return 0;
                        }
                    }
                    insertVersion(adopt, template, candidate);
                    return 1;
                });
                awaitLockWait("sales_quote_template_candidates");
            } finally {
                release.countDown();
            }
            running.get(60, TimeUnit.SECONDS);
            assertThat(adoption.get(60, TimeUnit.SECONDS)).as("the adoption reads no candidate after the reset").isZero();
            adopt.commit();
        }
        assertThat(f.finalExists(candidate.key())).isFalse();
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_versions", Long.class)).isZero();
    }

    // ------------------------------------------------------------------ protected files and counting

    @Test
    void protectedMasterFilesAreNeverDeletedAndTheirStagingTicketsStayForTheOrdinaryQueue() throws Exception {
        List<Stored> masters = new ArrayList<>();
        for (String owner : List.of("GOODS", "EMPLOYEE", "EMPLOYEE_CONTRACT")) {
            Stored master = f.storeFinal(owner, owner + " 主档文件.pdf");
            f.attachment(owner, master, "CLEAN");
            masters.add(master);
        }
        // A business upload session on a GOODS key (different version) and on a key known only to a legacy GOODS row.
        Stored shared = f.storeFinal("GOODS", "共用的货品图.png");
        rawAttachment("GOODS", "internal", shared.key(), null, "共用的货品图.png", "LEGACY_UNVERIFIED");
        f.session("SALES_QUOTE", shared, "EXPIRED", Instant.now().minusSeconds(60), null);
        Stored legacy = f.storeFinal("SALES_QUOTE", "旧货品图.png");
        rawAttachment("GOODS", "legacy_unknown", legacy.key(), null, "旧货品图.png", "LEGACY_UNVERIFIED");
        f.session("SALES_ORDER", legacy, "EXPIRED", Instant.now().minusSeconds(60), null);
        // Cost import and adopted template originals, each with a self-contained staging ticket (PENDING / FAILED).
        Stored cost = stagedAndFinal("GOODS_COST_IMPORT", "成本导入.xlsx");
        UUID goods = UUID.randomUUID();
        f.jdbc.update("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'成本主档',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))", goods, "RFS-" + goods);
        f.jdbc.update("""
                INSERT INTO goods_cost_imports(goods_id,actor_id,source_name,storage_provider,storage_key,storage_version,storage_size,storage_sha256,preview)
                VALUES(?,?,'成本导入.xlsx','internal',?,?,?,?,'{}'::jsonb)
                """, goods, f.admin, cost.key(), cost.version(), cost.size(), cost.sha());
        stagingTicket(cost, "PENDING");
        Stored adopted = stagedAndFinal("SALES_QUOTE_TEMPLATE", "已采用模板.xlsx");
        try (Connection connection = f.dataSource.getConnection()) {
            insertVersion(connection, customerTemplate(), adopted);
        }
        stagingTicket(adopted, "FAILED");
        // Master upload sessions with staging objects.
        Stored employeeUpload = f.storeStaging("EMPLOYEE", "员工上传.pdf");
        f.session("EMPLOYEE", employeeUpload, "PENDING", Instant.now().plusSeconds(600), null);
        Stored goodsUpload = f.storeStaging("GOODS", "货品上传.png");
        f.session("GOODS", goodsUpload, "EXPIRED", Instant.now().minusSeconds(60), null);
        Stored business = present("会被清空的业务附件.pdf");

        assertThat(f.objectCount()).as("only the business attachment is listed").isEqualTo(1);
        // The reset keeps the two unfinished staging tickets of kept files, so it waits for them (D9).
        String d9 = "有 2 个删除任务还没有完成，它们处理的是清空时要保留的文件(货品成本导入原件、已采用的报价模板、货品或员工档案附件)："
                + "「已采用模板.xlsx」(已采用的报价模板, 暂存副本)、「成本导入.xlsx」(货品成本导入, 暂存副本)。"
                + "清空会保留这些任务，要等它们完成后才能清空。后台正在自动处理它们(排队中、处理中或等待重试)，预计约 60 分钟内处理完，"
                + "请 60 分钟后点「重新检查」；如果到时仍没有完成，请联系开发人员。";
        Check preview = service.preview(f.admin, f.adminAccount);
        assertThat(preview.refusals()).containsExactly(new Refusal("PROTECTED_DELETE_TASKS_PENDING", 2, d9));
        assertThat(preview.inspectionSkipped()).isFalse();
        long generation = f.generation();
        UUID refusedAttempt = UUID.randomUUID();
        assertRefused(service, refusedAttempt, ErrorCode.CONFLICT, d9);
        assertUnchanged(generation, business);
        assertThat(service.lastResult(f.admin, refusedAttempt).attemptFailureMessage()).isEqualTo(
                "失败原因：保留文件的删除任务未完成 2 个。没有删除文件，也没有清空数据。完整原因(含文件名)请在清空弹窗点「重新检查」查看。");

        // The ordinary queue finishes them: the staging copies go, the kept final originals stay.
        f.jdbc.update("UPDATE attachment_object_outbox SET available_at=now() WHERE storage_key IN (?,?)", cost.key(), adopted.key());
        while (f.outboxWorker.processNext()) { }
        assertThat(f.stagingExists(cost.key())).isFalse();
        assertThat(f.stagingExists(adopted.key())).isFalse();
        assertThat(service.preview(f.admin, f.adminAccount).refusals()).isEmpty();

        var result = service.reset(f.admin, f.adminAccount, UUID.randomUUID());
        assertThat(result.deletedAttachmentFiles()).isEqualTo(1);
        assertThat(f.finalExists(business.key())).isFalse();
        for (Stored master : masters) assertThat(f.finalExists(master.key())).isTrue();
        for (Stored kept : List.of(shared, legacy, cost, adopted)) assertThat(f.finalExists(kept.key())).as(kept.name()).isTrue();
        assertThat(f.stagingExists(employeeUpload.key())).isTrue();
        assertThat(f.stagingExists(goodsUpload.key())).isTrue();
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM attachments WHERE upper(owner_type) IN ('GOODS','EMPLOYEE','EMPLOYEE_CONTRACT')", Long.class)).isEqualTo(5);
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM attachments WHERE owner_type='SALES_QUOTE'", Long.class)).isZero();
        assertThat(f.jdbc.queryForObject("SELECT count(*) FROM attachment_upload_sessions", Long.class)).isEqualTo(2);
        assertThat(f.jdbc.queryForList("SELECT status FROM attachment_object_outbox WHERE storage_key IN (?,?)", String.class, cost.key(), adopted.key()))
                .as("the finished tasks of kept files stay").containsExactly("SUCCEEDED", "SUCCEEDED");
    }

    @Test
    void protectedDeleteTasksThatCannotFinishOnTheirOwnNeedADeveloper() throws Exception {
        Stored cost = stagedAndFinal("GOODS_COST_IMPORT", "卡住的成本导入.xlsx");
        UUID goods = UUID.randomUUID();
        f.jdbc.update("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'成本主档',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))", goods, "RFS-" + goods);
        f.jdbc.update("""
                INSERT INTO goods_cost_imports(goods_id,actor_id,source_name,storage_provider,storage_key,storage_version,storage_size,storage_sha256,preview)
                VALUES(?,?,'卡住的成本导入.xlsx','internal',?,?,?,?,'{}'::jsonb)
                """, goods, f.admin, cost.key(), cost.version(), cost.size(), cost.sha());
        stagingTicket(cost, "FAILED");
        f.jdbc.update("UPDATE attachment_object_outbox SET attempts=6, last_error='IllegalStateException' WHERE storage_key=?", cost.key());
        Stored employee = f.storeFinal("EMPLOYEE", "张三身份证.pdf");
        f.attachment("EMPLOYEE", employee, "CLEAN");
        f.jdbc.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key,status,attempts,locked_at)
                VALUES('DELETE_STAGING','internal',?,NULL,?,'PROCESSING',1,NULL)
                """, employee.key(), "internal|DELETE_STAGING|" + employee.key() + "|<local>");
        Stored business = present("卡住时的业务附件.pdf");
        String d9 = "有 2 个删除任务卡住了，它们处理的是清空时要保留的文件(货品成本导入原件、已采用的报价模板、货品或员工档案附件)："
                + "「卡住的成本导入.xlsx」(货品成本导入, 暂存副本)、「员工档案文件, 存储编号 " + employee.key() + "」(员工档案附件, 暂存副本)。"
                + "其中 1 个已经连续失败至少 5 次，后台虽然还会每隔一段时间(最长约 17 分钟)自动重试，但连续失败说明不会自己恢复。"
                + "其中 1 个的处理记录不完整(状态和时间对不上)，后台不会再处理它们。"
                + "清空会保留这些任务，要等它们完成后才能清空。请联系开发人员查明这些删除任务为什么没有完成(服务器日志里有失败原因)并处理，处理完后点「重新检查」。";
        assertThat(service.preview(f.admin, f.adminAccount).refusals()).containsExactly(new Refusal("PROTECTED_DELETE_TASKS_STUCK", 2, d9));
        long generation = f.generation();
        assertRefused(service, UUID.randomUUID(), ErrorCode.CONFLICT, d9);
        assertUnchanged(generation, business);
        assertThat(d9).as("employee file names are never shown").doesNotContain("张三");
        // What a developer does after finding the cause: finish the tasks; then the reset runs.
        f.jdbc.update("UPDATE attachment_object_outbox SET status='SUCCEEDED', completed_at=now(), locked_at=NULL WHERE storage_key IN (?,?)",
                cost.key(), employee.key());
        assertThat(service.reset(f.admin, f.adminAccount, UUID.randomUUID()).deletedAttachmentFiles()).isEqualTo(1);
        assertThat(f.finalExists(employee.key())).isTrue();
        assertThat(f.finalExists(cost.key())).isTrue();
    }

    @Test
    void oneFileWithTwoSourcesIsCountedAndDeletedOnce() {
        Stored stored = stagedAndFinal("SALES_QUOTE", "附件与上传会话.pdf");
        f.attachment("SALES_QUOTE", stored, "CLEAN");
        f.session("SALES_QUOTE", stored, "EXPIRED", Instant.now().minusSeconds(60), stored.version());
        Check preview = service.preview(f.admin, f.adminAccount);
        assertThat(preview.locations()).isEqualTo(2);
        assertThat(preview.presentFiles()).as("the final file once, plus the session's staging copy").isEqualTo(2);
        assertThat(preview.kinds()).containsExactly(new KindCount("业务附件", 1));
        assertThat(service.reset(f.admin, f.adminAccount, UUID.randomUUID()).deletedAttachmentFiles()).isEqualTo(2);
        assertThat(f.finalExists(stored.key())).isFalse();
        assertThat(f.stagingExists(stored.key())).isFalse();
    }

    @Test
    void listedFilesThatAreAllMissingRaiseAWarningButDoNotBlock() {
        for (int i = 0; i < 3; i++) {
            Stored stored = present("已经不在的附件" + i + ".pdf");
            f.internal.delete(stored.key(), stored.version());
        }
        Check preview = service.preview(f.admin, f.adminAccount);
        assertThat(preview.allListedMissing()).isTrue();
        assertThat(preview.refusals()).isEmpty();
        assertThat(preview.absentFiles()).isEqualTo(3);
        assertThat(service.reset(f.admin, f.adminAccount, UUID.randomUUID()).deletedAttachmentFiles()).isZero();
    }

    // ------------------------------------------------------------------ identity (F1, F2) and long texts

    @Test
    void impersonationAndAnUnconfirmedSuperAdminAreRefusedForPreviewAndReset() {
        Stored file = present("身份不符时的附件.pdf");
        String f2 = "只有在职的超级管理员本人可以清空业务数据。请用自己的超级管理员账号重新登录后再试。";
        assertThat(api(() -> service.preview(UUID.randomUUID(), "not-a-super-admin"))).satisfies(error -> {
            assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
            assertThat(error.getMessage()).isEqualTo(f2);
        });
        long generation = f.generation();
        UUID stranger = UUID.randomUUID();
        assertThat(api(() -> service.reset(stranger, "not-a-super-admin", UUID.randomUUID()))).satisfies(error -> {
            assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
            assertThat(error.getMessage()).isEqualTo(f2);
        });
        assertUnchanged(generation, file);

        SecurityContextCurrentUser impersonating = mock(SecurityContextCurrentUser.class);
        when(impersonating.get()).thenReturn(Optional.of(new AuthUser(f.admin, f.adminEmployee, f.adminAccount, Set.of(),
                false, true, true, false, UUID.randomUUID())));
        var controller = new SystemTestController(service, impersonating);
        String f1 = "模拟他人身份时不能清空业务数据，请先退出模拟再操作。";
        assertThat(api(controller::previewBusinessDataReset)).satisfies(error -> {
            assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN);
            assertThat(error.getMessage()).isEqualTo(f1);
        });
        assertThat(api(() -> controller.resetBusinessData(new SystemTestController.ResetBusinessDataRequest("清空业务数据", UUID.randomUUID()))))
                .satisfies(error -> assertThat(error.getMessage()).isEqualTo(f1));
        assertUnchanged(generation, file);
    }

    @Test
    void longRefusalTextReachesTheResponseWhileTheReceiptKeepsOnlyCodesAndCounts() {
        List<String> names = new ArrayList<>();
        for (int i = 0; i < 7; i++) {
            String name = "第" + i + "个存在旧阿里云上的很长很长的客户合同扫描件文件名称_2026年度采购框架协议附件.pdf";
            names.add(name);
            rawAttachment("SALES_QUOTE", "oss", key(".pdf"), "oss-v" + i, name, "CLEAN");
        }
        for (int i = 0; i < 2; i++) {
            String name = "版本对不上的附件" + i + ".pdf";
            names.add(name);
            insertAttachment(f.storeFinal("SALES_QUOTE", name), "internal-v1:" + Integer.toString(i).repeat(64), name);
        }
        UUID attempt = UUID.randomUUID();
        ApiException refused = refusedReset(service, attempt);
        assertThat(refused.getMessage()).contains("有 7 个测试文件存放在系统无法删除的位置", " 等 7 个", names.getFirst(),
                HEADING, "2 个文件在存储里的内容和登记的不是同一份", names.get(7), names.get(8));
        var receipt = service.lastResult(f.admin, attempt);
        assertThat(receipt.attemptFailureMessage()).isEqualTo(
                "失败原因：7 个文件在系统删不了的存储；文件版本对不上 2 个。没有删除文件，也没有清空数据。完整原因(含文件名)请在清空弹窗点「重新检查」查看。");
        String stored = f.jdbc.queryForObject("SELECT result FROM audit_log WHERE action='business_data_reset_failed' AND target_id=?", String.class, attempt.toString());
        assertThat(stored).hasSizeLessThanOrEqualTo(500)
                .startsWith("failed,code=CONFLICT,deleted_attachment_files=0,reasons=UNSUPPORTED_STORAGE:7;VERSION_MISMATCH:2,message=");
        for (String name : names) assertThat(stored).doesNotContain(name);
    }

    @Test
    void inFlightRequestsThatDoNotFinishStopTheResetBeforeAnyDelete() {
        Stored file = present("排水超时时的附件.pdf");
        var impatient = f.service(f.files(), new BusinessDataResetTimings(Duration.ofMinutes(5), Duration.ofSeconds(60),
                Duration.ofSeconds(20), Duration.ofMillis(200), Duration.ofSeconds(15)));
        assertThat(f.drain.tryEnter()).isTrue();
        long generation = f.generation();
        UUID attempt = UUID.randomUUID();
        try {
            assertRefused(impatient, attempt, ErrorCode.CONFLICT,
                    "还有其他人的操作在进行中，等了 1 秒仍未结束；本次没有删除任何文件，也没有清空数据。请稍后重新点「确认清空」。");
        } finally {
            f.drain.leave();
        }
        assertUnchanged(generation, file);
        assertThat(service.lastResult(f.admin, attempt).attemptFailureMessage()).isEqualTo(
                "失败原因：其他操作未结束。没有删除文件，也没有清空数据。完整原因(含文件名)请在清空弹窗点「重新检查」查看。");
    }

    // ------------------------------------------------------------------ helpers

    /** The locked check of purge() in a reset-like transaction whose time is already used up. */
    private ApiException purgeWithExpiredDeadline() {
        Throwable failure = catchThrowable(() -> f.tx.executeWithoutResult(status -> {
            f.bindAdmin();
            f.files().purge(Instant.now().minusSeconds(1), new AtomicLong());
        }));
        assertThat(failure).isInstanceOf(ApiException.class);
        return (ApiException) failure;
    }

    private Stored present(String name) {
        Stored stored = f.storeFinal("SALES_QUOTE", name);
        f.attachment("SALES_QUOTE", stored, "CLEAN");
        return stored;
    }

    /** A promoted final whose staging copy is kept (as before the ordinary staging delete ran). */
    private Stored stagedAndFinal(String category, String name) {
        Stored staged = f.storeStaging(category, name);
        var promoted = f.internal.promoteToFinal(staged.key(), f.internal.describe(staged.key()));
        return new Stored(staged.key(), promoted.versionId(), staged.size(), staged.sha(), promoted.storedSize(), promoted.encoding(), name);
    }

    private void stagingTicket(Stored stored, String status) {
        f.jdbc.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key,status,attempts,available_at)
                VALUES('DELETE_STAGING','internal',?,?,?,?,CASE WHEN ?='FAILED' THEN 1 ELSE 0 END,now()+interval '1 hour')
                """, stored.key(), stored.version(), "internal|DELETE_STAGING|" + stored.key() + "|" + stored.version(), status, status);
    }

    private void insertAttachment(Stored stored, String registeredVersion, String name) {
        f.jdbc.update("""
                INSERT INTO attachments(id,owner_type,owner_id,storage_key,storage_version,original_name,content_type,size_bytes,sha256,
                    storage_provider,stored_size_bytes,storage_encoding,lifecycle_state,scan_engine,scanned_at,promoted_at)
                VALUES(gen_random_uuid(),'SALES_QUOTE',gen_random_uuid(),?,?,?,'application/pdf',?,?,'internal',?,?,'CLEAN','private-test-clean',now(),now())
                """, stored.key(), registeredVersion, name, stored.size(), stored.sha(), stored.storedSize(), stored.encoding());
    }

    private UUID rawAttachment(String owner, String provider, String key, String version, String name, String state) {
        UUID id = UUID.randomUUID();
        f.jdbc.update("""
                INSERT INTO attachments(id,owner_type,owner_id,storage_key,storage_version,original_name,content_type,size_bytes,sha256,
                    storage_provider,stored_size_bytes,storage_encoding,lifecycle_state,scan_engine,scanned_at,promoted_at,delete_requested_at)
                VALUES(?,?,gen_random_uuid(),?,?,?,'application/pdf',10,repeat('a',64),?,10,'IDENTITY',?,'private-test-clean',now(),now(),now())
                """, id, owner, key, version, name, provider, state);
        return id;
    }

    private UUID customerTemplate() {
        UUID client = UUID.randomUUID(), template = UUID.randomUUID();
        f.jdbc.update("INSERT INTO clients(id,code,name,status,code_sequence) VALUES(?,?,'模板客户','使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients))", client, "RFS-C-" + client);
        f.jdbc.update("INSERT INTO sales_quote_customer_templates(id,client_id,name,fingerprint,features) VALUES(?,?,'客户模板',?,'{}'::jsonb)",
                template, client, "e".repeat(32) + UUID.randomUUID().toString().replace("-", ""));
        return template;
    }

    /** SalesQuoteTemplateStore adoption: the immutable version row that references the candidate's object. */
    private void insertVersion(Connection connection, UUID template, Stored object) throws Exception {
        try (var insert = connection.prepareStatement("""
                INSERT INTO sales_quote_template_versions(template_id,version,source_name,mapping,payload_sha256,captured_by,
                    storage_provider,storage_key,storage_version,storage_size,storage_sha256)
                VALUES(?,1,?,'{}'::jsonb,?,?,'internal',?,?,?,?)
                """)) {
            insert.setObject(1, template);
            insert.setString(2, object.name());
            insert.setString(3, object.sha());
            insert.setObject(4, f.admin);
            insert.setString(5, object.key());
            insert.setString(6, object.version());
            insert.setLong(7, object.size());
            insert.setString(8, object.sha());
            insert.executeUpdate();
        }
    }

    private void awaitLockWait(String table) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60);
        while (System.nanoTime() < deadline) {
            Long waiting = f.jdbc.queryForObject("SELECT count(*) FROM pg_locks WHERE NOT granted AND relation = to_regclass(?)", Long.class, "public." + table);
            if (waiting != null && waiting > 0) return;
            Thread.sleep(50);
        }
        throw new AssertionError("no session started waiting for " + table);
    }

    private Path finalPath(String key) {
        Matcher matcher = INTERNAL_KEY.matcher(key);
        assertThat(matcher.matches()).isTrue();
        return f.root.resolve("final").resolve(matcher.group(1)).resolve(matcher.group(2)).resolve(key);
    }

    private void assertRefused(BusinessDataResetService target, UUID attempt, ErrorCode code, String message) {
        ApiException refused = refusedReset(target, attempt);
        assertThat(refused.getMessage()).isEqualTo(message);
        assertThat(refused.getCode()).isEqualTo(code);
    }

    private ApiException refusedReset(BusinessDataResetService target, UUID attempt) {
        ApiException refused = api(() -> target.reset(f.admin, f.adminAccount, attempt));
        assertThat(f.drain.blockingNewRequests()).as("the drain gate is released").isFalse();
        return refused;
    }

    private void assertUnchanged(long generation, Stored... stillPresent) {
        assertThat(f.generation()).isEqualTo(generation);
        for (Stored stored : stillPresent) assertThat(f.finalExists(stored.key())).as(stored.name() + " must not be deleted").isTrue();
    }

    private static ApiException api(Runnable action) {
        Throwable failure = catchThrowable(action::run);
        assertThat(failure).isInstanceOf(ApiException.class);
        return (ApiException) failure;
    }

    private static String key(String extension) {
        return UUID.randomUUID().toString().replace("-", "") + extension;
    }

    private static void sleep(long millis) {
        try { Thread.sleep(millis); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
    }

    private static void await(CountDownLatch latch) {
        try { assertThat(latch.await(120, TimeUnit.SECONDS)).isTrue(); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
    }
}
