package com.uten.imp.features.measurement;

import com.uten.imp.features.measurement.MeasurementCaptureContracts.ProfileResolution;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class JdbcMeasurementCaptureStoreTest {

    private static final UUID FIRST_GOODS_ID =
            UUID.fromString("11111111-1111-1111-1111-111111111111");
    private static final UUID SECOND_GOODS_ID =
            UUID.fromString("22222222-2222-2222-2222-222222222222");
    private static final UUID THIRD_GOODS_ID =
            UUID.fromString("33333333-3333-3333-3333-333333333333");
    private static final UUID PROFILE_ID =
            UUID.fromString("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    private static final UUID BUSINESS_UNIT_ID =
            UUID.fromString("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
    private static final UUID WEIGHT_UNIT_ID =
            UUID.fromString("cccccccc-cccc-cccc-cccc-cccccccccccc");
    private static final UUID HIDDEN_PROFILE_ID =
            UUID.fromString("dddddddd-dddd-dddd-dddd-dddddddddddd");

    @Test
    void resolveBatchUsesOneSetBasedQueryAndMapsExistingAndFallbackRows()
            throws Exception {
        CapturingJdbcTemplate jdbc = new CapturingJdbcTemplate(List.of(
                fallbackRow(), existingProfileRow(), hiddenSecondaryRow()));
        JdbcMeasurementCaptureStore store = new JdbcMeasurementCaptureStore(jdbc);

        List<ProfileResolution> result = store.resolveBatch(
                MeasurementOperationFamily.PROCUREMENT,
                Set.of(THIRD_GOODS_ID, SECOND_GOODS_ID, FIRST_GOODS_ID));

        assertThat(jdbc.queryCount).isEqualTo(1);
        assertThat(jdbc.sql)
                .contains("LEFT JOIN v_measurement_capture_profile_resolution")
                .contains("SELECT resolution.id AS profile_id")
                .contains("goods.id AS goods_id")
                .contains("goods.id IN (")
                .contains("?,?,?")
                .contains("COALESCE(resolution.status, 'UNCLASSIFIED')")
                .contains("COALESCE(resolution.primary_input, 'BUSINESS_QUANTITY')")
                .contains("COALESCE(resolution.secondary_policy, 'OFFERED')")
                .contains("COALESCE(resolution.business_unit_id, goods.unit_id)");
        assertThat(jdbc.arguments).containsExactly(
                "PROCUREMENT",
                "PROCUREMENT",
                FIRST_GOODS_ID,
                SECOND_GOODS_ID,
                THIRD_GOODS_ID);

        assertThat(result).hasSize(3);
        assertThat(result.get(0))
                .extracting(
                        ProfileResolution::profileId,
                        ProfileResolution::goodsId,
                        ProfileResolution::operationFamily,
                        ProfileResolution::status,
                        ProfileResolution::primaryInput,
                        ProfileResolution::secondaryPolicy,
                        ProfileResolution::businessUnitId,
                        ProfileResolution::actualWeightUnitId,
                        ProfileResolution::confidence,
                        ProfileResolution::activeEvidenceCount,
                        ProfileResolution::version,
                        ProfileResolution::profilePresent)
                .containsExactly(
                        null,
                        FIRST_GOODS_ID,
                        "PROCUREMENT",
                        "UNCLASSIFIED",
                        "BUSINESS_QUANTITY",
                        "OFFERED",
                        BUSINESS_UNIT_ID,
                        null,
                        BigDecimal.ZERO,
                        0L,
                        0L,
                        false);
        assertThat(result.get(1))
                .extracting(
                        ProfileResolution::profileId,
                        ProfileResolution::goodsId,
                        ProfileResolution::actualWeightUnitId,
                        ProfileResolution::profilePresent)
                .containsExactly(
                        PROFILE_ID,
                        SECOND_GOODS_ID,
                        WEIGHT_UNIT_ID,
                        true);
        assertThat(result.get(2))
                .extracting(
                        ProfileResolution::profileId,
                        ProfileResolution::goodsId,
                        ProfileResolution::primaryInput,
                        ProfileResolution::secondaryPolicy,
                        ProfileResolution::actualWeightUnitId,
                        ProfileResolution::profilePresent)
                .containsExactly(
                        HIDDEN_PROFILE_ID,
                        THIRD_GOODS_ID,
                        "BUSINESS_QUANTITY",
                        "HIDDEN",
                        null,
                        true);
    }

    @Test
    void decisionStreamUsesAppendVersionInsteadOfWallClockOrdering() {
        CapturingJdbcTemplate jdbc = new CapturingJdbcTemplate(List.of());
        JdbcMeasurementCaptureStore store = new JdbcMeasurementCaptureStore(jdbc);

        assertThat(store.loadDecisions(PROFILE_ID)).isEmpty();
        assertThat(jdbc.sql)
                .contains("ORDER BY resulting_version, event_id")
                .doesNotContain("ORDER BY decided_at");
    }

    private static ResultSet fallbackRow() throws Exception {
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("profile_id", UUID.class)).thenReturn(null);
        when(row.getObject("goods_id", UUID.class)).thenReturn(FIRST_GOODS_ID);
        when(row.getString("operation_family")).thenReturn("PROCUREMENT");
        when(row.getString("status")).thenReturn("UNCLASSIFIED");
        when(row.getString("primary_input")).thenReturn("BUSINESS_QUANTITY");
        when(row.getString("secondary_policy")).thenReturn("OFFERED");
        when(row.getObject("business_unit_id", UUID.class))
                .thenReturn(BUSINESS_UNIT_ID);
        when(row.getString("business_unit_name")).thenReturn("个");
        when(row.getObject("actual_weight_unit_id", UUID.class)).thenReturn(null);
        when(row.getString("actual_weight_unit_name")).thenReturn(null);
        when(row.getBigDecimal("confidence")).thenReturn(BigDecimal.ZERO);
        when(row.getLong("active_evidence_count")).thenReturn(0L);
        when(row.getString("evidence_fingerprint")).thenReturn(null);
        when(row.getLong("version")).thenReturn(0L);
        when(row.getObject("last_evidence_at")).thenReturn(null);
        return row;
    }

    private static ResultSet existingProfileRow() throws Exception {
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("profile_id", UUID.class)).thenReturn(PROFILE_ID);
        when(row.getObject("goods_id", UUID.class)).thenReturn(SECOND_GOODS_ID);
        when(row.getString("operation_family")).thenReturn("PROCUREMENT");
        when(row.getString("status")).thenReturn("CONFIRMED");
        when(row.getString("primary_input"))
                .thenReturn("BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT");
        when(row.getString("secondary_policy")).thenReturn("VISIBLE");
        when(row.getObject("business_unit_id", UUID.class))
                .thenReturn(BUSINESS_UNIT_ID);
        when(row.getString("business_unit_name")).thenReturn("个");
        when(row.getObject("actual_weight_unit_id", UUID.class))
                .thenReturn(WEIGHT_UNIT_ID);
        when(row.getString("actual_weight_unit_name")).thenReturn("千克");
        when(row.getBigDecimal("confidence")).thenReturn(BigDecimal.ONE);
        when(row.getLong("active_evidence_count")).thenReturn(4L);
        when(row.getString("evidence_fingerprint")).thenReturn("fingerprint");
        when(row.getLong("version")).thenReturn(5L);
        when(row.getObject("last_evidence_at"))
                .thenReturn(OffsetDateTime.parse("2026-08-31T10:15:30Z"));
        return row;
    }

    private static ResultSet hiddenSecondaryRow() throws Exception {
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("profile_id", UUID.class))
                .thenReturn(HIDDEN_PROFILE_ID);
        when(row.getObject("goods_id", UUID.class)).thenReturn(THIRD_GOODS_ID);
        when(row.getString("operation_family")).thenReturn("PROCUREMENT");
        when(row.getString("status")).thenReturn("CONFIRMED");
        when(row.getString("primary_input")).thenReturn("BUSINESS_QUANTITY");
        when(row.getString("secondary_policy")).thenReturn("HIDDEN");
        when(row.getObject("business_unit_id", UUID.class))
                .thenReturn(BUSINESS_UNIT_ID);
        when(row.getString("business_unit_name")).thenReturn("个");
        when(row.getObject("actual_weight_unit_id", UUID.class)).thenReturn(null);
        when(row.getString("actual_weight_unit_name")).thenReturn(null);
        when(row.getBigDecimal("confidence")).thenReturn(BigDecimal.ONE);
        when(row.getLong("active_evidence_count")).thenReturn(3L);
        when(row.getString("evidence_fingerprint")).thenReturn("fingerprint-2");
        when(row.getLong("version")).thenReturn(3L);
        when(row.getObject("last_evidence_at")).thenReturn(null);
        return row;
    }

    private static final class CapturingJdbcTemplate extends JdbcTemplate {
        private final List<ResultSet> rows;
        private String sql;
        private Object[] arguments;
        private int queryCount;

        private CapturingJdbcTemplate(List<ResultSet> rows) {
            this.rows = rows;
        }

        @Override
        public <T> List<T> query(
                String sql, RowMapper<T> rowMapper, Object... args) {
            this.queryCount++;
            this.sql = sql;
            this.arguments = args;
            List<T> mapped = new ArrayList<>();
            for (int index = 0; index < rows.size(); index++) {
                try {
                    mapped.add(rowMapper.mapRow(rows.get(index), index));
                } catch (java.sql.SQLException exception) {
                    throw new IllegalStateException(exception);
                }
            }
            return mapped;
        }
    }
}
