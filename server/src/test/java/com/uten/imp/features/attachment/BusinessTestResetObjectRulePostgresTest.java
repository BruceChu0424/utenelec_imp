package com.uten.imp.features.attachment;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** The single object rule fn_business_test_reset_objects() (ADR-155), against a real migrated schema. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class BusinessTestResetObjectRulePostgresTest {
    private MigratedSchemaBaseline.ScopedDatabase database;
    private JdbcTemplate jdbc;
    private TransactionTemplate tx;
    private UUID user;

    @BeforeEach
    void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("reset_object_rule");
        var source = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(source);
        tx = new TransactionTemplate(new DataSourceTransactionManager(source));
        UUID employee = UUID.randomUUID();
        user = UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'规则测试人','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'", employee, "ORL-" + employee);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')", user, employee, "object-rule-" + user);
    }

    @AfterEach
    void close() throws Exception {
        if (database != null) database.close();
    }

    @Test
    void internalIdentityHasNoVersionAndOneFileIsListedOncePerLocation() {
        String key = key(".pdf");
        UUID attachment = attachment("SALES_QUOTE", "internal", key, "internal-v1:aa", "合同.pdf", "CLEAN");
        outbox(attachment, null, "DELETE_FINAL", "internal", key, "internal-v1:bb", "RETAINED_HISTORY");
        session("SALES_QUOTE", "internal", key, "internal-v1:aa", "合同上传.pdf");
        var rows = objects();
        assertThat(rows).hasSize(2);
        assertThat(rows.get(0)).containsEntry("object_location", "FINAL").containsEntry("identity_version", null)
                .containsEntry("versions", "{internal-v1:aa,internal-v1:bb}").containsEntry("source_label", "业务附件")
                .containsEntry("display_label", "「合同.pdf」(业务附件, 正式文件)")
                .containsEntry("object_identity", "internal|FINAL|" + key + "|*")
                .containsEntry("deletable_storage", true);
        assertThat(rows.get(1)).containsEntry("object_location", "STAGING").containsEntry("versions", null)
                .containsEntry("display_label", "「合同.pdf」(业务附件, 暂存副本)");
    }

    @Test
    void storageWithoutSingleFilePerKeyKeepsTheVersionedIdentity() {
        String key = key(".pdf");
        UUID attachment = attachment("SALES_ORDER", "oss", key, "oss-v1", "旧附件.pdf", "CLEAN");
        outbox(attachment, null, "DELETE_FINAL", "oss", key, "oss-v2", "FAILED");
        var rows = objects();
        assertThat(rows).extracting(row -> row.get("object_identity"))
                .containsExactly("oss|FINAL|" + key + "|oss-v1", "oss|FINAL|" + key + "|oss-v2");
        assertThat(rows).allSatisfy(row -> assertThat(row).containsEntry("versions", null)
                .as("the reset cannot delete from oss itself").containsEntry("deletable_storage", false));
    }

    @Test
    void aiStagingTicketIsShownAsTheAiOriginalAndANamelessTicketShowsItsKey() {
        String original = key(".pdf");
        UUID job = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO ai_input_originals(job_id,actor_user_id,original_name,input_kind,content_type,availability,
                  declared_size,declared_sha256,storage_provider,storage_key,storage_size,storage_sha256,captured_at)
                VALUES(?,?,'客户询价单.pdf','PDF','application/pdf','AVAILABLE',10,repeat('a',64),'local',?,10,repeat('a',64),now())
                """, job, user, original);
        outbox(null, null, "DELETE_STAGING", "local", original, null, "SUCCEEDED");
        String nameless = key(".xlsx");
        outbox(null, null, "DELETE_STAGING", "internal", nameless, "internal-v1:cc", "PENDING");
        Map<String, Map<String, Object>> byIdentity = new java.util.LinkedHashMap<>();
        objects().forEach(row -> byIdentity.put((String) row.get("object_identity"), row));
        assertThat(byIdentity.get("local|FINAL|" + original + "|*")).containsEntry("display_label", "「客户询价单.pdf」(AI识别原件, 正式文件)")
                .containsEntry("recorded_absent", false);
        assertThat(byIdentity.get("local|STAGING|" + original + "|*")).containsEntry("display_label", "「客户询价单.pdf」(AI识别原件, 暂存副本)")
                .containsEntry("source_label", "AI识别原件").containsEntry("recorded_absent", true);
        assertThat(byIdentity.get("internal|STAGING|" + nameless + "|*"))
                .containsEntry("display_label", "「未登记文件名, 存储编号 " + nameless + "」(删除任务, 暂存副本)")
                .containsEntry("source_label", "删除任务").containsEntry("recorded_absent", false);
    }

    @Test
    void everyMasterFamilyProtectsItsKeyWhateverTheRegisteredVersion() {
        // GOODS attachment without a version protects a business upload session on the same key.
        String goods = key(".png");
        attachment("GOODS", "internal", goods, null, "货品图纸.png", "LEGACY_UNVERIFIED");
        session("SALES_QUOTE", "internal", goods, "internal-v1:other", "同编号上传.png");
        // EMPLOYEE / EMPLOYEE_CONTRACT attachments protect delete tasks with a different version.
        String person = key(".pdf");
        attachment("EMPLOYEE", "internal", person, "internal-v1:person", "身份证.pdf", "CLEAN");
        outbox(null, null, "DELETE_FINAL", "internal", person, "internal-v1:other", "PENDING");
        outbox(null, null, "DELETE_STAGING", "internal", person, null, "FAILED");
        String contract = key(".pdf");
        attachment("EMPLOYEE_CONTRACT", "internal", contract, "internal-v1:contract", "劳动合同.pdf", "CLEAN");
        outbox(null, null, "DELETE_FINAL", "internal", contract, "internal-v1:other", "PENDING");
        // A master row whose storage is not determined protects the same key on internal storage.
        String legacy = key(".pdf");
        attachment("GOODS", "legacy_unknown", legacy, null, "旧货品图.pdf", "LEGACY_UNVERIFIED");
        outbox(null, null, "DELETE_FINAL", "internal", legacy, "internal-v1:legacy", "PENDING");
        // Goods cost import originals (final and staging).
        String cost = key(".xlsx");
        UUID goodsId = UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,'成本主档',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))", goodsId, "ORL-" + goodsId);
        jdbc.update("""
                INSERT INTO goods_cost_imports(goods_id,actor_id,source_name,storage_provider,storage_key,storage_version,storage_size,storage_sha256,preview)
                VALUES(?,?,'成本.xlsx','internal',?,'internal-v1:cost',12,repeat('b',64),'{}'::jsonb)
                """, goodsId, user, cost);
        outbox(null, null, "DELETE_STAGING", "internal", cost, "internal-v1:cost", "PENDING");
        outbox(null, null, "DELETE_FINAL", "internal", cost, "internal-v1:different", "FAILED");
        // Adopted quote template versions.
        String template = key(".xlsx");
        UUID client = UUID.randomUUID(), customerTemplate = UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name,status,code_sequence) VALUES(?,?,'模板客户','使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients))", client, "ORL-C-" + client);
        jdbc.update("INSERT INTO sales_quote_customer_templates(id,client_id,name,fingerprint,features) VALUES(?,?,'客户模板',repeat('c',64),'{}'::jsonb)", customerTemplate, client);
        jdbc.update("""
                INSERT INTO sales_quote_template_versions(template_id,version,source_name,mapping,payload_sha256,captured_by,
                  storage_provider,storage_key,storage_version,storage_size,storage_sha256)
                VALUES(?,1,'模板.xlsx','{}'::jsonb,repeat('d',64),?,'internal',?,'internal-v1:template',12,repeat('d',64))
                """, customerTemplate, user, template);
        outbox(null, null, "DELETE_STAGING", "internal", template, "internal-v1:template", "PENDING");
        outbox(null, null, "DELETE_FINAL", "internal", template, "internal-v1:candidate", "SUCCEEDED");
        // A GOODS upload session protects its key too.
        String goodsUpload = key(".png");
        session("GOODS", "internal", goodsUpload, null, "货品上传.png");
        outbox(null, null, "DELETE_STAGING", "internal", goodsUpload, null, "PENDING");
        // Control: an unprotected self-contained task is listed.
        String business = key(".pdf");
        outbox(null, null, "DELETE_STAGING", "internal", business, null, "PENDING");

        assertThat(objects()).extracting(row -> row.get("object_key")).containsExactly(business);

        // D9: the unfinished tasks the reset keeps (no business owner, protected with the task's own
        // version - the rows fn_clear_business_test_object_metadata() keeps) refuse the reset.
        // Tasks protected only by key but with another version are cleared by the reset and do not count.
        var refusals = jdbc.queryForList("SELECT reason_code, item_count, message FROM fn_business_data_reset_refusals()");
        assertThat(refusals).hasSize(1);
        assertThat(refusals.getFirst()).containsEntry("reason_code", "PROTECTED_DELETE_TASKS_PENDING").containsEntry("item_count", 5L);
        assertThat((String) refusals.getFirst().get("message"))
                .startsWith("有 5 个删除任务还没有完成，它们处理的是清空时要保留的文件(货品成本导入原件、已采用的报价模板、货品或员工档案附件)：")
                .contains("「员工档案文件, 存储编号 " + person + "」(员工档案附件, 暂存副本)",
                        "「旧货品图.pdf」(货品档案附件, 正式文件)",
                        "「成本.xlsx」(货品成本导入, 暂存副本)",
                        "「模板.xlsx」(已采用的报价模板, 暂存副本)",
                        "「货品上传.png」(货品档案附件, 暂存副本)",
                        "预计约 1 分钟内处理完，请 1 分钟后点「重新检查」")
                .doesNotContain("身份证", "劳动合同", "(员工档案附件, 正式文件)", "(货品成本导入, 正式文件)", "(已采用的报价模板, 正式文件)", business);
    }

    @Test
    void returnsMetadataOnly() {
        List<String> columns = new ArrayList<>();
        jdbc.query("SELECT * FROM fn_business_test_reset_objects() LIMIT 0", (java.sql.ResultSet rows) -> {
            var meta = rows.getMetaData();
            for (int i = 1; i <= meta.getColumnCount(); i++) columns.add(meta.getColumnName(i));
            return null;
        });
        assertThat(columns).containsExactly("object_provider", "object_location", "object_key", "identity_version",
                "registered_versions", "source_kind", "source_label", "location_label", "file_name", "display_label",
                "recorded_absent", "object_identity", "deletable_storage");
        assertThat(columns).doesNotContain("legacy_bytes", "workbook_bytes", "payload");
    }

    @Test
    void fingerprintIgnoresRowOrderAndTimeZoneButFollowsRegisteredVersions() throws Exception {
        String first = key(".pdf"), second = key(".pdf");
        UUID attachment = attachment("SALES_QUOTE", "internal", second, "internal-v1:one", "乙.pdf", "CLEAN");
        outbox(null, null, "DELETE_STAGING", "internal", first, null, "PENDING");
        String utc = fingerprintIn("UTC");
        String shanghai = fingerprintIn("Asia/Shanghai");
        assertThat(utc).isEqualTo(shanghai);
        List<String> lines = new ArrayList<>(List.of(
                "internal|FINAL|" + second + "|*|internal-v1:one", "internal|STAGING|" + first + "|*|"));
        lines.sort(null);
        assertThat(utc).isEqualTo("2:" + sha256(String.join("\n", lines)));
        outbox(attachment, null, "DELETE_FINAL", "internal", second, "internal-v1:two", "RETAINED_HISTORY");
        String changed = fingerprintIn("UTC");
        assertThat(changed).startsWith("2:").isNotEqualTo(utc);
    }

    // ------------------------------------------------------------------ helpers

    private List<Map<String, Object>> objects() {
        return jdbc.queryForList("""
                SELECT object_provider, object_location, object_key, identity_version, registered_versions::text AS versions,
                       source_kind, source_label, location_label, file_name, display_label, recorded_absent, object_identity,
                       deletable_storage
                FROM fn_business_test_reset_objects() ORDER BY object_identity
                """);
    }

    private String fingerprintIn(String zone) {
        return tx.execute(status -> {
            jdbc.execute("SET LOCAL TIME ZONE '" + zone + "'");
            return jdbc.queryForObject("SELECT fn_business_test_reset_object_fingerprint()", String.class);
        });
    }

    private static String sha256(String text) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));
    }

    private static String key(String extension) {
        return UUID.randomUUID().toString().replace("-", "") + extension;
    }

    private UUID attachment(String owner, String provider, String key, String version, String name, String state) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO attachments(id,owner_type,owner_id,storage_key,storage_version,original_name,content_type,size_bytes,sha256,
                    storage_provider,stored_size_bytes,storage_encoding,lifecycle_state,scan_engine,scanned_at,promoted_at)
                VALUES(?,?,?,?,?,?,'application/pdf',10,repeat('a',64),?,10,'IDENTITY',?,'private-test-clean',now(),now())
                """, id, owner, UUID.randomUUID(), key, version, name, provider, state);
        return id;
    }

    private UUID session(String owner, String provider, String key, String finalVersion, String name) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO attachment_upload_sessions(id,storage_key,owner_type,owner_id,user_id,original_name,content_type,expected_size_bytes,
                    expires_at,status,storage_provider,final_version)
                VALUES(?,?,?,?,?,?,'application/pdf',10,now()-interval '1 hour','EXPIRED',?,?)
                """, id, key, owner, UUID.randomUUID(), user, name, provider, finalVersion);
        return id;
    }

    private void outbox(UUID attachment, UUID session, String operation, String provider, String key, String version, String status) {
        jdbc.update("""
                INSERT INTO attachment_object_outbox(attachment_id,upload_session_id,operation,storage_provider,storage_key,storage_version,
                    dedupe_key,status,completed_at)
                VALUES(?,?,?,?,?,?,?,?,CASE WHEN ? IN ('SUCCEEDED','RETAINED_HISTORY') THEN now() END)
                """, attachment, session, operation, provider, key, version, UUID.randomUUID().toString(), status, status);
    }
}
