package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.sales.intake.IntakeReferenceData.CurrencyRow;
import com.uten.imp.features.sales.intake.IntakeReferenceData.LearnedLayout;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 识别流程销售侧 SQL 在真库上可证(全部迁移跑到最新): 币种查询、学习版式的写入(客户一行; 全局一行按不同客户的证据重算,
 * 同一客户保存再多次也只算 1; 只刷新使用时间不加次数)与查询顺序、同一文件被哪些单据用过(排除当前任务)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SalesIntakeStorePostgresTest {

    private static final PostgreSQLContainer<?> DB = new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate jdbc;
    private static SalesIntakeStore store;

    @BeforeAll
    static void start() {
        DB.start();
        Flyway.configure().dataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword())
                .locations("classpath:db/migration").load().migrate();
        DriverManagerDataSource ds = new DriverManagerDataSource(DB.getJdbcUrl(), DB.getUsername(), DB.getPassword());
        jdbc = new JdbcTemplate(ds);
        store = new SalesIntakeStore(new NamedParameterJdbcTemplate(ds), new ObjectMapper());
    }

    @AfterAll
    static void stop() {
        DB.stop();
    }

    private static UUID client(String code) {
        return jdbc.queryForObject("INSERT INTO clients(code, name, status, code_sequence) VALUES (?, ?, '使用', ?) RETURNING id",
                UUID.class, code, "识别测试客户" + code, (long) Math.abs(code.hashCode()));
    }

    private static Map<String, Object> layoutRow(String fingerprint, UUID clientId) {
        return jdbc.queryForMap("""
                SELECT confirm_count, header_row_offset, header_texts, column_roles::text AS roles
                FROM sales_intake_layouts
                WHERE fingerprint = ? AND client_id IS NOT DISTINCT FROM ?
                """, fingerprint, clientId);
    }

    @Test
    void currenciesAreActiveAndNotDeletedWithTheBaseCurrencyFirst() {
        jdbc.update("INSERT INTO currencies(code, name, exchange_rate, status) VALUES ('T-USD', '识别测试美元', 7.1, '使用')");
        jdbc.update("INSERT INTO currencies(code, name, exchange_rate, status) VALUES ('T-OFF', '识别测试停用', 2, '禁用')");
        jdbc.update("INSERT INTO currencies(code, name, exchange_rate, status, is_deleted) VALUES ('T-DEL', '识别测试删除', 3, '使用', true)");
        List<CurrencyRow> rows = store.currencies();
        assertThat(rows).extracting(CurrencyRow::code).contains("T-USD").doesNotContain("T-OFF", "T-DEL");
        CurrencyRow usd = rows.stream().filter(r -> "T-USD".equals(r.code())).findFirst().orElseThrow();
        assertThat(usd.exchangeRate()).isEqualByComparingTo(new BigDecimal("7.1"));
        assertThat(usd.base()).isFalse();
        boolean seenNonBase = false;
        for (CurrencyRow r : rows) {
            assertThat(r.base() && seenNonBase).as("base currency listed first").isFalse();
            seenNonBase |= !r.base();
        }
    }

    @Test
    void layoutsAreUpsertedPerScopeAndReadClientFirst() {
        UUID client = client("INTAKE-L1");
        UUID other = client("INTAKE-L2");
        String fp = "c".repeat(64);
        String fp2 = "e".repeat(64);
        store.upsertLayout(fp, client, "A=s/n|B=part no.|C=qty",
                Map.of("A", "LINE_NO", "B", "PART_NO", "C", "QTY", "Z", "IGNORED", "bad!", "QTY"), 0);
        Map<String, Object> first = layoutRow(fp, client);
        assertThat(first.get("confirm_count")).isEqualTo(1);
        assertThat((String) first.get("roles")).contains("\"A\"").contains("\"C\"").doesNotContain("\"Z\"")
                .doesNotContain("bad!");
        assertThat(layoutRow(fp, null).get("confirm_count")).isEqualTo(1);

        // 同一客户同样的列角色再保存: 客户一行加 1, 全局一行仍只算 1 个客户(一个客户的反复保存不会变成全局可信)。
        store.upsertLayout(fp, client, "A=s/n|B=part no.|C=qty",
                Map.of("A", "LINE_NO", "B", "PART_NO", "C", "QTY"), 0);
        assertThat(layoutRow(fp, client).get("confirm_count")).isEqualTo(2);
        assertThat(layoutRow(fp, null).get("confirm_count")).isEqualTo(1);

        // 列角色变了: 客户一行从 1 重新数并换成新角色(偏移夹到 5), 全局一行跟着换成最新的那种。
        store.upsertLayout(fp, client, "A=s/n|B=part no.|C=qty|D=price",
                Map.of("A", "LINE_NO", "B", "PART_NO", "C", "QTY", "D", "UNIT_PRICE"), 7);
        Map<String, Object> second = layoutRow(fp, client);
        assertThat(second.get("confirm_count")).isEqualTo(1);
        assertThat(second.get("header_row_offset")).as("clamped").isEqualTo(5);
        assertThat((String) second.get("roles")).contains("UNIT_PRICE");
        assertThat(second.get("header_texts")).isEqualTo("A=s/n|B=part no.|C=qty|D=price");
        assertThat((String) layoutRow(fp, null).get("roles")).contains("UNIT_PRICE");
        assertThat(layoutRow(fp, null).get("confirm_count")).isEqualTo(1);

        // 另一个客户确认了同样的列角色: 全局一行 = 2 个客户。
        store.upsertLayout(fp, other, "A=s/n|B=part no.|C=qty|D=price",
                Map.of("A", "LINE_NO", "B", "PART_NO", "C", "QTY", "D", "UNIT_PRICE"), 5);
        assertThat(layoutRow(fp, null).get("confirm_count")).isEqualTo(2);
        assertThat(layoutRow(fp, other).get("confirm_count")).isEqualTo(1);

        // 第三个客户认成了别的列角色: 全局仍是两个客户确认的那种。
        UUID third = client("INTAKE-L3");
        store.upsertLayout(fp, third, "A=s/n|B=part no.|C=qty|D=price", Map.of("A", "PART_NO", "C", "QTY"), 5);
        assertThat((String) layoutRow(fp, null).get("roles")).contains("UNIT_PRICE");
        assertThat(layoutRow(fp, null).get("confirm_count")).isEqualTo(2);

        // 没有客户不写; 只刷新使用时间不加次数。
        store.upsertLayout(fp2, null, "A=item", Map.of("A", "PART_NO", "B", "QTY"), 0);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_intake_layouts WHERE fingerprint = ?", Integer.class,
                fp2)).isZero();
        jdbc.update("UPDATE sales_intake_layouts SET last_used_at = now() - interval '3 days' WHERE fingerprint = ?", fp);
        store.touchLayout(fp, client);
        assertThat(layoutRow(fp, client).get("confirm_count")).isEqualTo(1);
        assertThat(layoutRow(fp, null).get("confirm_count")).isEqualTo(2);
        assertThat(jdbc.queryForObject("""
                SELECT count(*) FROM sales_intake_layouts
                WHERE fingerprint = ? AND last_used_at > now() - interval '1 hour'
                """, Integer.class, fp)).as("the client row and the global row are touched, other clients are not")
                .isEqualTo(2);
        store.upsertLayout(fp2, client, "A=item", Map.of("A", "PART_NO", "B", "QTY"), 0);

        // 已选客户: 自己的在前, 全局的在后, 别的客户的不返回。
        List<LearnedLayout> forClient = store.layouts(List.of(fp, fp2, "not-a-fingerprint"), client);
        assertThat(forClient).extracting(LearnedLayout::clientId).containsExactly(client, client, null, null);
        LearnedLayout own = forClient.stream().filter(l -> fp.equals(l.fingerprint()) && client.equals(l.clientId()))
                .findFirst().orElseThrow();
        assertThat(own.columnRoles()).containsEntry("D", "UNIT_PRICE").containsEntry("A", "LINE_NO");
        assertThat(own.headerRowOffset()).isEqualTo(5);
        // 没选客户: 全局的在前(按确认客户数), 各客户的排在最后(流水线只在规则认不出时拿它们兜底)。
        List<LearnedLayout> unselected = store.layouts(List.of(fp), null);
        assertThat(unselected.getFirst().clientId()).isNull();
        assertThat(unselected).extracting(LearnedLayout::clientId).hasSize(4).containsOnlyOnce((UUID) null);
        assertThat(store.layouts(List.of(fp2), other)).extracting(LearnedLayout::clientId).containsExactly((UUID) null);
        assertThat(store.layouts(List.of("xyz"), client)).isEmpty();

        // 非法输入什么都不写。
        store.upsertLayout("short", client, "x", Map.of("A", "QTY"), 0);
        store.upsertLayout("f".repeat(64), client, "x", Map.of("A", "IGNORED"), 0);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_intake_layouts WHERE fingerprint IN ('short', ?)",
                Integer.class, "f".repeat(64))).isZero();
    }

    private static UUID job(String sha, String docType, UUID docId) {
        return jdbc.queryForObject("""
                INSERT INTO ai_jobs(kind, status, input_name, input_content_type, input_kind, input_size, input_sha256,
                                    submitted_by_user, submitted_auth_version, used_at, used_doc_type, used_doc_id)
                VALUES ('SALES_DOCUMENT_INTAKE', 'SUCCEEDED', 'a.xlsx', 'application/octet-stream', 'XLSX', 10, ?,
                        gen_random_uuid(), 1, CASE WHEN CAST(? AS text) IS NULL THEN NULL ELSE now() END, ?, ?)
                RETURNING id
                """, UUID.class, sha, docType, docType, docId);
    }

    @Test
    void sameFileLookupReturnsUsedDocumentsExceptTheCurrentJob() {
        String sha = "d".repeat(64);
        UUID orderDoc = UUID.randomUUID();
        UUID quoteDoc = UUID.randomUUID();
        UUID current = job(sha, "order", orderDoc);
        job(sha, "quote", quoteDoc);
        job(sha, null, null);
        job("a".repeat(64), "order", UUID.randomUUID());
        assertThat(store.docsUsingSameFile(sha, current)).containsExactly(Map.entry(quoteDoc, "quote"));
        assertThat(store.docsUsingSameFile(sha, null)).containsOnly(Map.entry(orderDoc, "order"), Map.entry(quoteDoc, "quote"));
        assertThat(store.docsUsingSameFile("not-a-sha", null)).isEmpty();
        assertThat(store.docsUsingSameFile(null, current)).isEmpty();
    }
}
