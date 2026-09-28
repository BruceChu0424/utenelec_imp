package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Types;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * 识别流程的销售侧数据读写(原生 SQL, 每个方法一个短事务, 从不在事务里调用 AI)。
 *
 * <ul>
 *   <li>币种资料(本位币、财务参考汇率);</li>
 *   <li>客户文件版式 sales_intake_layouts(本模块自有表): 查询与保存后学习;</li>
 *   <li>同一文件是否已被保存进单据: 读 ai_jobs 的 used_* 列(只取单据 id, 调用方再与可见单据求交)。</li>
 * </ul>
 */
@Component
class SalesIntakeStore implements IntakeReferenceData {

    private static final Pattern FINGERPRINT = Pattern.compile("^[0-9a-f]{64}$");
    private static final Pattern LETTER = Pattern.compile("^[A-Z]{1,3}$");

    private final NamedParameterJdbcTemplate jdbc;
    private final ObjectMapper json;

    SalesIntakeStore(NamedParameterJdbcTemplate jdbc, ObjectMapper json) {
        this.jdbc = jdbc;
        this.json = json;
    }

    @Override
    @Transactional(readOnly = true)
    public List<CurrencyRow> currencies() {
        return jdbc.query("""
                SELECT currency.id, currency.code, currency.name, currency.exchange_rate, currency.is_base_currency
                FROM currencies currency
                WHERE COALESCE(currency.is_deleted, false) = false
                  AND currency.status = '使用'
                ORDER BY currency.is_base_currency DESC, currency.code
                """, Map.of(), (rs, i) -> new CurrencyRow(
                rs.getObject(1, UUID.class), rs.getString(2), rs.getString(3), rs.getBigDecimal(4), rs.getBoolean(5)));
    }

    @Override
    @Transactional(readOnly = true)
    public List<LearnedLayout> layouts(Collection<String> fingerprints, UUID clientIdOrNull) {
        List<String> valid = fingerprints.stream().filter(f -> f != null && FINGERPRINT.matcher(f).matches())
                .distinct().limit(1000).toList();
        if (valid.isEmpty()) {
            return List.of();
        }
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("fingerprints", valid)
                .addValue("clientId", clientIdOrNull, Types.OTHER);
        return jdbc.query("""
                SELECT layout.fingerprint, layout.client_id, layout.column_roles::text, layout.header_row_offset,
                       layout.confirm_count
                FROM sales_intake_layouts layout
                WHERE layout.fingerprint IN (:fingerprints)
                  AND (layout.client_id IS NULL OR layout.client_id = CAST(:clientId AS uuid))
                ORDER BY layout.client_id NULLS LAST, layout.confirm_count DESC
                """, params, (rs, i) -> new LearnedLayout(rs.getString(1), rs.getObject(2, UUID.class),
                parseRoles(rs.getString(3)), rs.getInt(4), rs.getInt(5)));
    }

    @Override
    @Transactional(readOnly = true)
    public Map<UUID, String> docsUsingSameFile(String sha256, UUID excludeJobId) {
        if (sha256 == null || !FINGERPRINT.matcher(sha256).matches()) {
            return Map.of();
        }
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("sha", sha256)
                .addValue("jobId", excludeJobId, Types.OTHER);
        Map<UUID, String> out = new LinkedHashMap<>();
        jdbc.query("""
                SELECT DISTINCT job.used_doc_id, job.used_doc_type
                FROM ai_jobs job
                WHERE job.input_sha256 = :sha
                  AND job.used_doc_id IS NOT NULL
                  AND (CAST(:jobId AS uuid) IS NULL OR job.id <> CAST(:jobId AS uuid))
                """, params, rs -> {
            out.put(rs.getObject(1, UUID.class), rs.getString(2));
        });
        return out;
    }

    @Override
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void upsertLayout(String fingerprint, UUID clientId, String headerTexts, Map<String, String> columnRoles,
                             int headerRowOffset) {
        if (fingerprint == null || !FINGERPRINT.matcher(fingerprint).matches() || headerTexts == null
                || columnRoles == null || columnRoles.isEmpty()) {
            return;
        }
        Map<String, String> clean = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : columnRoles.entrySet()) {
            ColumnRole role = ColumnRole.parse(e.getValue());
            if (e.getKey() != null && LETTER.matcher(e.getKey()).matches() && role != null && role != ColumnRole.IGNORED) {
                clean.put(e.getKey(), role.name());
            }
        }
        if (clean.isEmpty()) {
            return;
        }
        String rolesJson;
        try {
            rolesJson = json.writeValueAsString(clean);
        } catch (Exception e) {
            return;
        }
        String texts = headerTexts.length() > 4000 ? headerTexts.substring(0, 4000) : headerTexts;
        int offset = Math.max(0, Math.min(headerRowOffset, 5));
        for (UUID scope : clientId == null ? new UUID[]{null} : new UUID[]{clientId, null}) {
            MapSqlParameterSource params = new MapSqlParameterSource()
                    .addValue("fingerprint", fingerprint)
                    .addValue("clientId", scope, Types.OTHER)
                    .addValue("texts", texts)
                    .addValue("roles", rolesJson)
                    .addValue("offset", offset);
            jdbc.update("""
                    INSERT INTO sales_intake_layouts (fingerprint, client_id, header_texts, column_roles, header_row_offset,
                                                      confirm_count, last_used_at, created_at, updated_at)
                    VALUES (:fingerprint, CAST(:clientId AS uuid), :texts, CAST(:roles AS jsonb), :offset, 1, now(), now(), now())
                    ON CONFLICT ON CONSTRAINT uq_sales_intake_layouts_key DO UPDATE
                        SET header_texts = EXCLUDED.header_texts,
                            column_roles = EXCLUDED.column_roles,
                            header_row_offset = EXCLUDED.header_row_offset,
                            confirm_count = sales_intake_layouts.confirm_count + 1,
                            last_used_at = now(),
                            updated_at = now()
                    """, params);
        }
    }

    private Map<String, String> parseRoles(String text) {
        if (text == null || text.isBlank()) {
            return Map.of();
        }
        try {
            Map<String, String> raw = json.readValue(text, new TypeReference<LinkedHashMap<String, String>>() {
            });
            return raw == null ? Map.of() : raw;
        } catch (Exception e) {
            return Map.of();
        }
    }
}
