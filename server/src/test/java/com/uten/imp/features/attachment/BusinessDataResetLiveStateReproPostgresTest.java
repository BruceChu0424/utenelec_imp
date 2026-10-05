package com.uten.imp.features.attachment;

import com.uten.imp.application.port.BusinessTestResetFilesPort.Check;
import com.uten.imp.application.port.BusinessTestResetFilesPort.KindCount;
import com.uten.imp.features.admin.systemtest.BusinessDataResetService;
import com.uten.imp.features.attachment.ResetEndToEndFixture.Intake;
import com.uten.imp.features.attachment.ResetEndToEndFixture.Stored;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Path;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;

/**
 * Acceptance gate of the live-state "清空业务数据" 409 (ADR-155). On beb072114 the direct reset
 * refused with "无业务来源的旧对象任务需要先对账"; with the single object rule every scenario below
 * clears through the real path.
 *
 * <p>Everything below the controller is real: Flyway-migrated PG, JPA transaction manager and audit
 * writer (as in production), {@link BusinessDataResetService}, the real file port
 * {@link BusinessTestResetFiles}, internal (version-pinned, enveloped) storage, the real
 * {@code AiInputOriginalStore#capture} and the real ordinary {@link AttachmentObjectOutboxProcessor}
 * that turns the AI DELETE_STAGING ticket into status SUCCEEDED, exactly as observed on the test server.</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessDataResetLiveStateReproPostgresTest {
    @TempDir Path files;
    ResetEndToEndFixture fixture;
    BusinessDataResetService resetService;

    @BeforeEach
    void start() throws Exception {
        fixture = ResetEndToEndFixture.open("reset_live_repro", files);
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE success AND version='783'", Long.class)).isEqualTo(1);
        resetService = fixture.service();
    }

    @AfterEach
    void stop() throws Exception {
        if (fixture != null) fixture.close();
    }

    // ------------------------------------------------------------------ scenarios

    /** (a) Exact live state of 2026-10-05 13:37, then two more resets (ratchet check). */
    @Test
    void liveStateDirectResetThenRatchet() throws Exception {
        UUID survivor = seedProtectedLegacyLocalStagingTicket();
        Intake first = fixture.aiIntake("客户询价单.pdf");
        assertLiveSourceShape(first);
        long generation = fixture.generation();

        Throwable firstReset = outcome("a#1 direct reset (live state)", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(firstReset).as("a#1 direct reset must succeed").isNull();
        assertResetCleared(first, survivor, generation + 1);
        assertThat(lastDeletedFiles()).as("only the FINAL AI original physically existed").isEqualTo(1);

        Intake second = fixture.aiIntake("第二次询价单.pdf");
        assertLiveSourceShape(second);
        Throwable secondReset = outcome("a#2 direct reset after new AI intake", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(secondReset).as("a#2 direct reset must succeed").isNull();
        assertResetCleared(second, survivor, generation + 2);

        Throwable thirdReset = outcome("a#3 direct reset with nothing new", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(thirdReset).as("a#3 direct reset must succeed").isNull();
        assertThat(lastDeletedFiles()).isZero();
        assertThat(fixture.objectCount()).isZero();
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox", Long.class)).isEqualTo(1);
        assertThat(fixture.generation()).isEqualTo(generation + 3);
    }

    /** The dialog preview reads the same rule as the reset; then reset, then a new AI intake and a direct reset. */
    @Test
    void previewThenResetThenNewIntake() throws Exception {
        UUID survivor = seedProtectedLegacyLocalStagingTicket();
        Intake first = fixture.aiIntake("客户询价单.pdf");
        assertLiveSourceShape(first);
        long generation = fixture.generation();
        Check preview = resetService.preview(fixture.admin, fixture.adminAccount);
        System.out.println("REPRO> preview " + preview);
        assertThat(preview.locations()).isEqualTo(2);
        assertThat(preview.presentFiles()).isEqualTo(1);
        assertThat(preview.absentFiles()).isEqualTo(1);
        assertThat(preview.inspectionComplete()).isTrue();
        assertThat(preview.allListedMissing()).isFalse();
        assertThat(preview.kinds()).containsExactly(new KindCount("AI识别原件", 1));
        assertThat(preview.refusals()).isEmpty();
        assertThat(fixture.internal.inspectObject(com.uten.imp.common.storage.StorageService.ObjectLocation.FINAL, first.key()).exists())
                .as("the preview deletes nothing").isTrue();

        Throwable reset = outcome("w#2 reset after preview", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(reset).isNull();
        assertResetCleared(first, survivor, generation + 1);

        Intake second = fixture.aiIntake("第二次询价单.pdf");
        Throwable direct = outcome("w#3 direct reset after next AI intake", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(direct).as("w#3 direct reset after a new AI intake").isNull();
        assertResetCleared(second, survivor, generation + 2);
    }

    /** (b) AI intake whose ordinary DELETE_STAGING ticket is still PENDING, or FAILED at the alert threshold. */
    @Test
    void aiIntakeWithPendingOrFailedStagingTicket() throws Exception {
        Intake pending = fixture.aiIntakeWithoutWorker("未处理暂存.pdf");
        Intake failed = fixture.aiIntakeWithoutWorker("暂存删除失败.pdf");
        fixture.jdbc.update("UPDATE attachment_object_outbox SET status='FAILED',attempts=6,last_error='IllegalStateException',available_at=now()+interval '1 hour' WHERE storage_key=?", failed.key());
        assertThat(fixture.internal.describe(pending.key()).exists()).isTrue();
        assertThat(fixture.internal.describe(failed.key()).exists()).isTrue();
        dumpObjects("b");
        Throwable reset = outcome("b direct reset", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(reset).as("b direct reset must succeed").isNull();
        for (Intake intake : List.of(pending, failed)) {
            assertThat(fixture.internal.describe(intake.key()).exists()).as("staging gone").isFalse();
            assertFinalAbsent(intake.key(), intake.version());
        }
        assertThat(lastDeletedFiles()).isEqualTo(4);
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox", Long.class)).isZero();
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM ai_input_originals", Long.class)).isZero();
    }

    /** (c) soft-deleted business attachments with DELETE_FINAL tickets: SUCCEEDED/object gone, RETAINED_HISTORY/object kept, FAILED/object gone. */
    @Test
    void softDeletedBusinessAttachmentsWithDeleteFinalTickets() throws Exception {
        Stored gone = fixture.storeFinal("SALES_QUOTE", "已删合同.pdf");
        fixture.internal.delete(gone.key(), gone.version());
        UUID deleted = fixture.attachment("SALES_QUOTE", gone, "DELETED");
        fixture.outbox(deleted, "DELETE_FINAL", gone, "SUCCEEDED", 1);
        Stored kept = fixture.storeFinal("SALES_QUOTE", "保留历史.pdf");
        UUID retained = fixture.attachment("SALES_QUOTE", kept, "RETAINED_HISTORY");
        fixture.outbox(retained, "DELETE_FINAL", kept, "RETAINED_HISTORY", 1);
        Stored lost = fixture.storeFinal("SALES_ORDER", "删除失败.pdf");
        fixture.internal.delete(lost.key(), lost.version());
        UUID failed = fixture.attachment("SALES_QUOTE", lost, "DELETE_FAILED");
        fixture.outbox(failed, "DELETE_FINAL", lost, "FAILED", 6);
        dumpObjects("c");
        Throwable reset = outcome("c direct reset", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(reset).as("c direct reset must succeed").isNull();
        assertFinalAbsent(kept.key(), kept.version());
        assertThat(lastDeletedFiles()).isEqualTo(1);
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachments", Long.class)).isZero();
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox", Long.class)).isZero();
    }

    /** (d) abandoned upload session: PENDING, grant expired, staging object present, no final; plus an EXPIRED one with nothing left. */
    @Test
    void abandonedUploadSessionsWithExpiredGrant() throws Exception {
        Stored staged = fixture.storeStaging("SALES_QUOTE", "未确认上传.xlsx");
        UUID pending = fixture.session("SALES_QUOTE", staged, "PENDING", Instant.now().minusSeconds(120), null);
        Stored vanished = fixture.storeStaging("SALES_QUOTE", "过期上传.xlsx");
        fixture.internal.deleteStaging(vanished.key(), vanished.version());
        UUID expired = fixture.session("SALES_QUOTE", vanished, "EXPIRED", Instant.now().minusSeconds(3600), vanished.version());
        dumpObjects("d");
        Throwable reset = outcome("d direct reset", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(reset).as("d direct reset must succeed").isNull();
        assertThat(fixture.internal.describe(staged.key()).exists()).isFalse();
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachment_upload_sessions WHERE id IN (?,?)", Long.class, pending, expired)).isZero();
    }

    /** (d2) an upload grant that has not expired no longer blocks: the reset drains /api first, then deletes the staging copy. */
    @Test
    void unexpiredUploadGrantNoLongerBlocks() throws Exception {
        Stored staged = fixture.storeStaging("SALES_QUOTE", "上传中的报价单.xlsx");
        UUID live = fixture.session("SALES_QUOTE", staged, "PENDING", Instant.now().plusSeconds(3600), null);
        assertThat(resetService.preview(fixture.admin, fixture.adminAccount).refusals()).isEmpty();
        Throwable reset = outcome("d2 direct reset with a live upload grant", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(reset).as("d2 direct reset must succeed").isNull();
        assertThat(fixture.internal.describe(staged.key()).exists()).as("staging copy physically deleted").isFalse();
        assertThat(lastDeletedFiles()).isEqualTo(1);
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachment_upload_sessions WHERE id=?", Long.class, live)).isZero();
    }

    /** (e) AI intake that also produced a quote-template candidate which was re-staged once (history row): real stage SQL. */
    @Test
    void quoteTemplateCandidateWithHistoryRow() throws Exception {
        Intake intake = fixture.aiIntake("带模板的询价单.xlsx");
        Stored v1 = stageCandidate(intake.job(), "模板第一版.xlsx", "candidate-one");
        Stored v2 = stageCandidate(intake.job(), "模板第二版.xlsx", "candidate-two");
        while (fixture.outboxWorker.processNext()) { }
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_candidate_history WHERE job_id=?", Long.class, intake.job())).isEqualTo(1);
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE status='SUCCEEDED' AND attachment_id IS NULL AND upload_session_id IS NULL", Long.class)).isEqualTo(3);
        dumpObjects("e");
        Throwable reset = outcome("e direct reset", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(reset).as("e direct reset must succeed").isNull();
        assertFinalAbsent(v1.key(), v1.version());
        assertFinalAbsent(v2.key(), v2.version());
        assertFinalAbsent(intake.key(), intake.version());
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_candidates", Long.class)).isZero();
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM sales_quote_template_candidate_history", Long.class)).isZero();
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox", Long.class)).isZero();
    }

    /** (f) if the 3d353800-style legacy local ticket ever loses its master protection (local dir configured, staging gone). */
    @Test
    void unprotectedLegacyLocalStagingTicket() throws Exception {
        Path local = files.resolve("local");
        Files.createDirectories(local.resolve("staging"));
        Files.createDirectories(local.resolve("final"));
        fixture.properties.setLocalDir(local.toRealPath().toString());
        String key = UUID.randomUUID().toString().replace("-", "") + ".xlsx";
        fixture.jdbc.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key,status,attempts,completed_at)
                VALUES('DELETE_STAGING','local',?,NULL,?,'SUCCEEDED',1,now())
                """, key, "local|DELETE_STAGING|" + key + "|<local>");
        dumpObjects("f");
        Throwable reset = outcome("f direct reset", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(reset).as("f direct reset must succeed").isNull();
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox", Long.class)).isZero();
    }

    /** (f2) the same ticket on a server without a local directory: it is recorded as deleted, so it is skipped, not refused. */
    @Test
    void recordedDeletedLocalTicketWithoutLocalDirectory() throws Exception {
        StorageProperties properties = fixture.properties;
        assertThat(Path.of(properties.getLocalDir()).isAbsolute()).as("no local directory configured").isFalse();
        String key = UUID.randomUUID().toString().replace("-", "") + ".xlsx";
        fixture.jdbc.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key,status,attempts,completed_at)
                VALUES('DELETE_STAGING','local',?,NULL,?,'SUCCEEDED',1,now())
                """, key, "local|DELETE_STAGING|" + key + "|<local>");
        Check preview = resetService.preview(fixture.admin, fixture.adminAccount);
        assertThat(preview.refusals()).isEmpty();
        assertThat(preview.absentFiles()).isEqualTo(1);
        Throwable reset = outcome("f2 direct reset", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(reset).as("f2 direct reset must succeed").isNull();
        assertThat(lastDeletedFiles()).isZero();
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox", Long.class)).isZero();
    }

    /** (g) AI original whose FINAL object is already physically missing (absent counts as success). */
    @Test
    void aiOriginalWhoseFinalObjectIsAlreadyMissing() throws Exception {
        Intake intake = fixture.aiIntake("文件已丢失.pdf");
        fixture.internal.delete(intake.key(), intake.version());
        Throwable reset = outcome("g direct reset", () -> resetService.reset(fixture.admin, fixture.adminAccount, UUID.randomUUID()));
        assertThat(reset).as("g direct reset must succeed").isNull();
        assertThat(lastDeletedFiles()).isZero();
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM ai_input_originals", Long.class)).isZero();
    }

    // ------------------------------------------------------------------ seeding (mimics production writers)

    /** Analogue of live row 3d353800: local, self-contained DELETE_STAGING SUCCEEDED, protected by a goods_cost_imports reference. */
    private UUID seedProtectedLegacyLocalStagingTicket() {
        UUID goods = UUID.randomUUID();
        fixture.jdbc.update("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'成本导入主档',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))", goods, "RST-COST-" + goods);
        String key = UUID.randomUUID().toString().replace("-", "") + ".xlsx";
        fixture.jdbc.update("""
                INSERT INTO goods_cost_imports(id,goods_id,actor_id,source_name,storage_provider,storage_key,storage_version,storage_size,storage_sha256,preview)
                VALUES(?,?,?,'old-cost.xlsx','local',?,NULL,12,repeat('a',64),'{}'::jsonb)
                """, UUID.randomUUID(), goods, fixture.admin, key);
        UUID id = UUID.randomUUID();
        fixture.jdbc.update("""
                INSERT INTO attachment_object_outbox(id,operation,storage_provider,storage_key,storage_version,dedupe_key,status,attempts,completed_at,created_at)
                VALUES(?,'DELETE_STAGING','local',?,NULL,?,'SUCCEEDED',1,now()-interval '4 days',now()-interval '4 days')
                """, id, key, "local|DELETE_STAGING|" + key + "|<local>");
        return id;
    }

    /** Mirrors SalesQuoteTemplateStore.stage: private object + upsert candidate + self-contained DELETE_STAGING ticket. */
    private Stored stageCandidate(UUID job, String name, String fingerprintSeed) {
        byte[] bytes = ("PK template " + name + " " + UUID.randomUUID()).getBytes(StandardCharsets.UTF_8);
        Stored[] out = new Stored[1];
        fixture.tx.executeWithoutResult(status -> {
            fixture.bindAdmin();
            var ref = fixture.documents.save("SALES_QUOTE_TEMPLATE", "template.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", bytes);
            var named = new NamedParameterJdbcTemplate(fixture.jdbc);
            var args = new MapSqlParameterSource().addValue("job", job).addValue("actor", fixture.aiUser).addValue("name", name)
                    .addValue("fingerprint", com.uten.imp.common.storage.ImmutableDocumentStore.digest(fingerprintSeed.getBytes(StandardCharsets.UTF_8)))
                    .addValue("provider", ref.provider()).addValue("key", ref.key()).addValue("objectVersion", ref.version())
                    .addValue("size", ref.size()).addValue("sha", ref.sha256());
            named.update("""
                    INSERT INTO sales_quote_template_candidates(job_id,actor_user_id,source_name,fingerprint,mapping,features,
                        storage_provider,storage_key,storage_version,storage_size,storage_sha256)
                    VALUES(:job,:actor,:name,:fingerprint,CAST('{}' AS jsonb),CAST('{}' AS jsonb),
                        :provider,:key,:objectVersion,:size,:sha)
                    ON CONFLICT(job_id) DO UPDATE SET workbook_bytes=NULL,mapping=EXCLUDED.mapping,
                        features=EXCLUDED.features,fingerprint=EXCLUDED.fingerprint,source_name=EXCLUDED.source_name,
                        storage_provider=EXCLUDED.storage_provider,storage_key=EXCLUDED.storage_key,
                        storage_version=EXCLUDED.storage_version,storage_size=EXCLUDED.storage_size,
                        storage_sha256=EXCLUDED.storage_sha256,expires_at=now()+interval '7 days'
                    """, args);
            named.update("""
                    INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
                    VALUES('DELETE_STAGING',:provider,:key,:objectVersion,
                        :provider || '|DELETE_STAGING|' || :key || '|' || COALESCE(CAST(:objectVersion AS text),'<local>'))
                    ON CONFLICT(dedupe_key) DO NOTHING
                    """, args);
            out[0] = new Stored(ref.key(), ref.version(), ref.size(), ref.sha256(), 0, null, name);
        });
        return out[0];
    }

    // ------------------------------------------------------------------ observation helpers

    private Throwable outcome(String label, Supplier<?> action) {
        Throwable failure = catchThrowable(action::get);
        System.out.println("REPRO> " + label + " -> " + (failure == null ? "OK" : failure.getClass().getSimpleName() + ": " + failure.getMessage()));
        if (failure != null) {
            Throwable root = failure;
            while (root.getCause() != null && root.getCause() != root) root = root.getCause();
            if (root != failure) System.out.println("REPRO>   root cause " + root.getClass().getName() + ": " + root.getMessage());
            dumpObjects(label + " (after failure)");
        }
        return failure;
    }

    private void dumpObjects(String label) {
        System.out.println("REPRO> objects[" + label + "]:");
        fixture.jdbc.queryForList("SELECT object_provider,object_location,object_key,identity_version,registered_versions::text,source_label,location_label,recorded_absent FROM fn_business_test_reset_objects() ORDER BY object_identity")
                .forEach(row -> System.out.println("REPRO>   " + row));
    }

    private void assertLiveSourceShape(Intake intake) {
        var rows = fixture.jdbc.queryForList("SELECT object_provider,object_location,object_key,identity_version,registered_versions::text AS versions,source_label,location_label FROM fn_business_test_reset_objects() ORDER BY object_identity");
        assertThat(rows).hasSize(2);
        assertThat(rows.get(0)).containsEntry("object_provider", "internal").containsEntry("object_location", "FINAL")
                .containsEntry("object_key", intake.key()).containsEntry("identity_version", null)
                .containsEntry("versions", "{" + intake.version() + "}")
                .containsEntry("source_label", "AI识别原件").containsEntry("location_label", "正式文件");
        assertThat(rows.get(1)).containsEntry("object_provider", "internal").containsEntry("object_location", "STAGING")
                .containsEntry("object_key", intake.key()).containsEntry("identity_version", null)
                .containsEntry("versions", null)
                .containsEntry("source_label", "AI识别原件").containsEntry("location_label", "暂存副本");
    }

    private void assertResetCleared(Intake intake, UUID survivor, long expectedGeneration) {
        assertThat(fixture.jdbc.queryForObject("SELECT count(*) FROM ai_input_originals", Long.class)).isZero();
        assertThat(fixture.jdbc.queryForList("SELECT id FROM attachment_object_outbox", UUID.class)).containsExactly(survivor);
        assertThat(fixture.generation()).isEqualTo(expectedGeneration);
        assertFinalAbsent(intake.key(), intake.version());
        assertThat(fixture.internal.describe(intake.key()).exists()).isFalse();
    }

    private void assertFinalAbsent(String key, String version) {
        Throwable read = catchThrowable(() -> fixture.internal.openFinal(key, version).close());
        assertThat(read).as("FINAL %s must be physically gone", key).isNotNull();
        Throwable root = read;
        while (root.getCause() != null) root = root.getCause();
        assertThat(root).isInstanceOf(NoSuchFileException.class);
    }

    private long lastDeletedFiles() { return resetService.lastResult().deletedAttachmentFiles(); }
}
