package com.uten.imp.features.stock.weight;

import com.uten.imp.features.stock.weight.GoodsWeightFacts.EstimateRow;
import com.uten.imp.features.stock.weight.GoodsWeightFacts.Profile;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 单重解析的只读查询 (货品事实、学习结果行)。每批货品一条 SQL, 不在循环里逐个查。
 */
@Component
@RequiredArgsConstructor
public class GoodsWeightFactsStore {

    /** 一次 IN 列表的上限, 超过分批查。 */
    private static final int CHUNK = 500;

    static final String ESTIMATE_COLUMNS = """
            e.supplier_id, e.evidence, e.log_mean, e.unit_weight_kg, e.log_se, e.tau_lot, e.tau_between,
            e.shrink_weight, e.raw_log_mean, e.n_obs, e.n_ref, e.n_inliers, e.n_eff, e.rel_half_width, e.tier,
            e.draw_bias_log, e.draw_bias_se, e.n_draw, e.label_bias_log, e.label_bias_se, e.regime_started_at,
            e.regime_changed_at, e.last_observed_at, e.as_of, e.outliers::text AS outliers_json,
            e.suggested_sample_size, e.algorithm_version, e.computed_at""";

    private final NamedParameterJdbcTemplate db;

    /** 一个货品的事实; 货品不存在时 exists=false。 */
    public GoodsWeightFacts load(UUID goodsId) {
        return loadAll(List.of(goodsId)).getOrDefault(goodsId, GoodsWeightFacts.missing(goodsId));
    }

    /** 多个货品的事实 (不存在的货品不在结果里)。 */
    public Map<UUID, GoodsWeightFacts> loadAll(Collection<UUID> goodsIds) {
        Map<UUID, GoodsWeightFacts> result = new HashMap<>();
        for (List<UUID> chunk : chunks(goodsIds)) {
            db.query("""
                    SELECT g.id AS goods_id, g.unit_id, gu.mass_unit_code AS goods_mass_code,
                           gu.measurement_dimension AS goods_dimension, g.m_weight,
                           mu.mass_unit_code AS m_weight_mass_code,
                           p.goods_id AS profile_goods_id, p.default_tare_kg, p.tolerance_pct, p.piece_cv_pct,
                           p.manual_unit_weight_kg, p.manual_unit_id, p.manual_reason, p.manual_set_by,
                           p.manual_set_at, p.learning_enabled, p.regime_mode, p.manual_regime_start_at,
                           p.version, p.updated_by, p.updated_at,
                           e.goods_id AS estimate_goods_id,
                    """ + ESTIMATE_COLUMNS + """
                    ,
                           tare.tare_kg AS last_tare_kg
                    FROM goods g
                    LEFT JOIN unit_measurement_profiles gu ON gu.unit_id = g.unit_id
                    LEFT JOIN unit_measurement_profiles mu ON mu.unit_id = g.m_weight_unit_id
                    LEFT JOIN goods_weight_profiles p ON p.goods_id = g.id
                    LEFT JOIN goods_weight_estimates e ON e.goods_id = g.id AND e.supplier_id IS NULL
                    LEFT JOIN LATERAL (
                        SELECT recent.tare_kg
                        FROM (
                            SELECT o.tare_kg, o.observed_at, o.id
                            FROM goods_weight_observations o
                            WHERE o.goods_id = g.id
                            ORDER BY o.observed_at DESC, o.id DESC
                            LIMIT 50
                        ) recent
                        WHERE recent.tare_kg IS NOT NULL
                        ORDER BY recent.observed_at DESC, recent.id DESC
                        LIMIT 1
                    ) tare ON true
                    WHERE g.id IN (:goods) AND NOT g.is_deleted
                    """, new MapSqlParameterSource("goods", chunk), rs -> {
                UUID goodsId = rs.getObject("goods_id", UUID.class);
                Profile profile = rs.getObject("profile_goods_id", UUID.class) == null ? Profile.missing()
                        : new Profile(true,
                        rs.getBigDecimal("default_tare_kg"),
                        rs.getBigDecimal("tolerance_pct"),
                        rs.getBigDecimal("piece_cv_pct"),
                        rs.getBigDecimal("manual_unit_weight_kg"),
                        rs.getObject("manual_unit_id", UUID.class),
                        rs.getString("manual_reason"),
                        rs.getObject("manual_set_by", UUID.class),
                        rs.getObject("manual_set_at", OffsetDateTime.class),
                        rs.getBoolean("learning_enabled"),
                        rs.getString("regime_mode"),
                        rs.getObject("manual_regime_start_at", OffsetDateTime.class),
                        rs.getLong("version"),
                        rs.getObject("updated_by", UUID.class),
                        rs.getObject("updated_at", OffsetDateTime.class));
                EstimateRow pool = rs.getObject("estimate_goods_id", UUID.class) == null ? null : estimateRow(rs);
                result.put(goodsId, new GoodsWeightFacts(goodsId, true,
                        rs.getObject("unit_id", UUID.class),
                        rs.getString("goods_mass_code"),
                        rs.getString("goods_dimension"),
                        rs.getBigDecimal("m_weight"),
                        rs.getString("m_weight_mass_code"),
                        profile, pool,
                        rs.getBigDecimal("last_tare_kg")));
            });
        }
        return result;
    }

    /** 指定货品 × 供应商的学习行, key = goodsId + ':' + supplierId。 */
    public Map<String, EstimateRow> supplierRows(Collection<UUID> goodsIds, Collection<UUID> supplierIds) {
        Map<String, EstimateRow> result = new HashMap<>();
        Set<UUID> suppliers = new LinkedHashSet<>(supplierIds);
        suppliers.remove(null);
        if (suppliers.isEmpty() || goodsIds.isEmpty()) {
            return result;
        }
        for (List<UUID> goodsChunk : chunks(goodsIds)) {
            for (List<UUID> supplierChunk : chunks(suppliers)) {
                db.query("SELECT e.goods_id, " + ESTIMATE_COLUMNS + """

                        FROM goods_weight_estimates e
                        WHERE e.goods_id IN (:goods) AND e.supplier_id IN (:suppliers)
                        """, new MapSqlParameterSource("goods", goodsChunk).addValue("suppliers", supplierChunk),
                        rs -> {
                            EstimateRow row = estimateRow(rs);
                            result.put(supplierKey(rs.getObject("goods_id", UUID.class), row.supplierId()), row);
                        });
            }
        }
        return result;
    }

    /** 一个货品的全部供应商学习行 (按单重从轻到重)。 */
    public List<EstimateRow> supplierRowsOf(UUID goodsId) {
        return db.query("SELECT " + ESTIMATE_COLUMNS + """

                FROM goods_weight_estimates e
                WHERE e.goods_id = :goods AND e.supplier_id IS NOT NULL
                ORDER BY e.log_mean NULLS LAST, e.supplier_id
                """, new MapSqlParameterSource("goods", goodsId), (rs, i) -> estimateRow(rs));
    }

    /** 单位登记的重量单位代码 (不是重量单位或未登记时 null)。 */
    public String massCodeOfUnit(UUID unitId) {
        if (unitId == null) {
            return null;
        }
        List<String> codes = db.queryForList(
                "SELECT mass_unit_code FROM unit_measurement_profiles WHERE unit_id = :unit",
                new MapSqlParameterSource("unit", unitId), String.class);
        return codes.isEmpty() ? null : codes.get(0);
    }

    static String supplierKey(UUID goodsId, UUID supplierId) {
        return goodsId + ":" + supplierId;
    }

    static EstimateRow estimateRow(ResultSet rs) throws SQLException {
        return new EstimateRow(
                rs.getObject("supplier_id", UUID.class),
                rs.getString("evidence"),
                dbl(rs, "log_mean"),
                rs.getBigDecimal("unit_weight_kg"),
                dbl(rs, "log_se"),
                dbl(rs, "tau_lot"),
                dbl(rs, "tau_between"),
                dbl(rs, "shrink_weight"),
                dbl(rs, "raw_log_mean"),
                integer(rs, "n_obs"),
                integer(rs, "n_ref"),
                integer(rs, "n_inliers"),
                dbl(rs, "n_eff"),
                dbl(rs, "rel_half_width"),
                rs.getString("tier"),
                dbl(rs, "draw_bias_log"),
                dbl(rs, "draw_bias_se"),
                integer(rs, "n_draw"),
                dbl(rs, "label_bias_log"),
                dbl(rs, "label_bias_se"),
                rs.getObject("regime_started_at", OffsetDateTime.class),
                rs.getObject("regime_changed_at", OffsetDateTime.class),
                rs.getObject("last_observed_at", OffsetDateTime.class),
                rs.getObject("as_of", OffsetDateTime.class),
                rs.getString("outliers_json"),
                integer(rs, "suggested_sample_size"),
                shortValue(rs, "algorithm_version"),
                rs.getObject("computed_at", OffsetDateTime.class));
    }

    static Double dbl(ResultSet rs, String column) throws SQLException {
        double value = rs.getDouble(column);
        return rs.wasNull() ? null : value;
    }

    static Integer integer(ResultSet rs, String column) throws SQLException {
        int value = rs.getInt(column);
        return rs.wasNull() ? null : value;
    }

    private static Short shortValue(ResultSet rs, String column) throws SQLException {
        short value = rs.getShort(column);
        return rs.wasNull() ? null : value;
    }

    private static List<List<UUID>> chunks(Collection<UUID> ids) {
        List<UUID> distinct = new ArrayList<>(new LinkedHashSet<>(ids));
        distinct.remove(null);
        List<List<UUID>> chunks = new ArrayList<>();
        for (int i = 0; i < distinct.size(); i += CHUNK) {
            chunks.add(distinct.subList(i, Math.min(distinct.size(), i + CHUNK)));
        }
        return chunks;
    }
}
