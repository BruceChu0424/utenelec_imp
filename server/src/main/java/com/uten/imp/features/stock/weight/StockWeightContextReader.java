package com.uten.imp.features.stock.weight;

import com.uten.imp.common.measure.WeightUnit;
import com.uten.imp.features.stock.StockService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.util.function.Supplier;

/**
 * 库存锁下为一笔流水读重量上下文(ADR-135 §2.2): 货品基本单位与本行单位的重量系数、同一来源键上既往流水的
 * 数量/重量合计(红冲镜像)、调拨入对应的调出重量, 一条 SQL 读完; 货品单重只在纯计算真要用时才查。
 *
 * <p>余额快照(数量/重量/是否估算)由 StockService 在同一把锁下先读好传进来。SQL 按有无颜色/来源拼常量片段,
 * 不用「:x IS NULL OR」写法(Hibernate 空参数取不到类型)。
 */
@Component
@RequiredArgsConstructor
public class StockWeightContextReader {

    private static final String GOODS_MASS_SQL = """
            SELECT profile.mass_unit_code
            FROM goods goods_row
            JOIN unit_measurement_profiles profile ON profile.unit_id = goods_row.unit_id
            WHERE goods_row.id = :goods
            """;

    private final EntityManager em;
    private final ObjectProvider<UnitWeightLookup> unitWeights;

    /** 读本笔流水的完整重量上下文; 余额快照由调用方(同一把库存锁下)传入。 */
    public StockWeightResolver.WeightContext read(StockService.MovementRequest req, BigDecimal balanceQty,
                                                  BigDecimal balanceWeight, boolean balanceEstimated,
                                                  boolean balanceExists) {
        boolean pooled = req.sourceDocId() != null;
        boolean counterpart = pooled && req.direction() == StockService.DIR_IN
                && req.movementType() == StockWeightResolver.TYPE_TRANSFER_IN;
        String sql = "SELECT head.goods_mass, head.line_mass,\n"
                + "       pool.in_qty, pool.out_qty, pool.in_kg, pool.out_kg, pool.pool_rows, pool.unknown_rows,"
                + " pool.worst_rank,\n"
                + "       counterpart.weight, counterpart.weight_source\n"
                + "FROM (SELECT (" + GOODS_MASS_SQL + ") AS goods_mass,\n"
                + (req.unitId() == null ? "       CAST(NULL AS varchar) AS line_mass) head\n"
                        : "       (SELECT profile.mass_unit_code FROM unit_measurement_profiles profile\n"
                        + "        WHERE profile.unit_id = :unit) AS line_mass) head\n")
                + "CROSS JOIN (" + (pooled ? poolSql(req) : EMPTY_POOL_SQL) + ") pool\n"
                + "LEFT JOIN LATERAL (" + (counterpart ? counterpartSql(req) : EMPTY_COUNTERPART_SQL)
                + ") counterpart ON TRUE";
        Query query = em.createNativeQuery(sql).setParameter("goods", req.goodsId());
        if (req.unitId() != null) query.setParameter("unit", req.unitId());
        if (pooled) {
            query.setParameter("sourceType", req.sourceDocType())
                    .setParameter("sourceDoc", req.sourceDocId())
                    .setParameter("movementType", req.movementType())
                    .setParameter("warehouse", req.warehouseId());
            if (req.sourceItemId() != null) query.setParameter("sourceItem", req.sourceItemId());
            if (req.colorId() != null) query.setParameter("color", req.colorId());
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        Object[] row = rows.getFirst();
        BigDecimal goodsFactor = factorOf((String) row[0]);
        BigDecimal lineFactor = factorOf((String) row[1]);
        StockWeightResolver.Pool pool = null;
        if (pooled && count(row[6]) > 0) {
            Integer worst = row[8] == null ? null : ((Number) row[8]).intValue();
            pool = new StockWeightResolver.Pool(decimal(row[2]), decimal(row[3]), decimal(row[4]), decimal(row[5]),
                    count(row[7]) == 0, worst == null ? null : WeightSource.ofDistrustRank(worst));
        }
        StockWeightResolver.Counterpart pair = null;
        if (counterpart && row[9] != null) {
            pair = new StockWeightResolver.Counterpart(decimal(row[9]), WeightSource.fromColumn((String) row[10]));
        }
        return new StockWeightResolver.WeightContext(balanceQty, balanceWeight, balanceEstimated, balanceExists,
                goodsFactor, lineFactor, pool, pair,
                goodsFactor == null ? lazyUnitWeight(req.goodsId()) : null);
    }

    /** 货品基本单位本身是重量单位时每单位千克数(精确货品), 否则 null。 */
    public BigDecimal goodsMassFactor(UUID goodsId) {
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery(GOODS_MASS_SQL).setParameter("goods", goodsId).getResultList();
        return rows.isEmpty() ? null : factorOf((String) rows.getFirst());
    }

    private static final String EMPTY_POOL_SQL = """
            SELECT CAST(0 AS numeric) AS in_qty, CAST(0 AS numeric) AS out_qty,
                   CAST(0 AS numeric) AS in_kg, CAST(0 AS numeric) AS out_kg,
                   CAST(0 AS bigint) AS pool_rows, CAST(0 AS bigint) AS unknown_rows,
                   CAST(NULL AS integer) AS worst_rank""";

    private static final String EMPTY_COUNTERPART_SQL = """
            SELECT CAST(NULL AS numeric) AS weight, CAST(NULL AS varchar) AS weight_source""";

    /** 同一来源键 K = (来源类型, 来源单, 来源行, 流水类型, 仓库, 货品, 颜色) 上的既往流水合计。 */
    private static String poolSql(StockService.MovementRequest req) {
        return """
                SELECT COALESCE(SUM(movement.qty) FILTER (WHERE movement.direction = 1), 0) AS in_qty,
                       COALESCE(SUM(movement.qty) FILTER (WHERE movement.direction = -1), 0) AS out_qty,
                       COALESCE(SUM(movement.weight) FILTER (WHERE movement.direction = 1), 0) AS in_kg,
                       COALESCE(SUM(movement.weight) FILTER (WHERE movement.direction = -1), 0) AS out_kg,
                       COUNT(*) AS pool_rows,
                       COUNT(*) FILTER (WHERE movement.weight IS NULL) AS unknown_rows,
                       MAX(CASE COALESCE(movement.weight_source, 'MEASURED')
                               WHEN 'MEASURED' THEN 0 WHEN 'SLICE' THEN 1 WHEN 'EXACT' THEN 2
                               WHEN 'AVERAGE' THEN 3 ELSE 4 END)
                           FILTER (WHERE movement.weight IS NOT NULL) AS worst_rank
                FROM stock_movements movement
                WHERE movement.source_doc_type = :sourceType
                  AND movement.source_doc_id = :sourceDoc
                """
                + (req.sourceItemId() == null ? "  AND movement.source_item_id IS NULL\n"
                        : "  AND movement.source_item_id = :sourceItem\n")
                + """
                  AND movement.movement_type = :movementType
                  AND movement.warehouse_id = :warehouse
                  AND movement.goods_id = :goods
                """
                + (req.colorId() == null ? "  AND movement.color_id IS NULL" : "  AND movement.color_id = :color");
    }

    /** 调拨入对应的调出: 同一来源行最近一笔类型 8、方向 -1 的流水。 */
    private static String counterpartSql(StockService.MovementRequest req) {
        return """
                SELECT movement.weight, movement.weight_source
                FROM stock_movements movement
                WHERE movement.source_doc_type = :sourceType
                  AND movement.source_doc_id = :sourceDoc
                """
                + (req.sourceItemId() == null ? "  AND movement.source_item_id IS NULL\n"
                        : "  AND movement.source_item_id = :sourceItem\n")
                + """
                  AND movement.movement_type = 8
                  AND movement.direction = -1
                ORDER BY movement.ledger_seq DESC
                LIMIT 1""";
    }

    /** 单重按需查一次并记住(同一笔流水里纯计算可能问好几次)。 */
    private Supplier<UnitWeightLookup.UnitWeightRef> lazyUnitWeight(UUID goodsId) {
        return new Supplier<>() {
            private boolean loaded;
            private UnitWeightLookup.UnitWeightRef value;

            @Override
            public UnitWeightLookup.UnitWeightRef get() {
                if (!loaded) {
                    loaded = true;
                    UnitWeightLookup lookup = unitWeights.getIfAvailable();
                    value = lookup == null ? null : lookup.goodsLevel(goodsId).orElse(null);
                }
                return value;
            }
        };
    }

    /** 重量单位代码 -> 每单位千克数; 空或认不出返回 null(不按精确处理)。 */
    static BigDecimal factorOf(String massUnitCode) {
        if (massUnitCode == null || massUnitCode.isBlank()) return null;
        try {
            WeightUnit unit = WeightUnit.parse(massUnitCode);
            return unit == null ? null : unit.kgPerUnit();
        } catch (IllegalArgumentException unknown) {
            return null;
        }
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        return value instanceof BigDecimal decimal ? decimal : new BigDecimal(value.toString());
    }

    private static long count(Object value) {
        return value == null ? 0L : ((Number) value).longValue();
    }
}
