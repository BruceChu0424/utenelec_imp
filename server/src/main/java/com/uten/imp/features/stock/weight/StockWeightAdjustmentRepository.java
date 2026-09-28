package com.uten.imp.features.stock.weight;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 只改重量的调整流水 stock_weight_adjustments(ADR-135 §2.1): 起算 / 尾差 / 盘点定重 / 人工核重 / 撤销盘点重量。
 * 只增不改(审计类别 NONE, 业务数据重置时清空); 永远不动数量与金额。
 *
 * <p>每次写入前先 flush 当前持久化上下文, 让本事务里先记的出入库流水先拿到 ledger_seq, 账链顺序与过账顺序一致。
 * 可空参数一律在 SQL 里 CAST 成列类型(Hibernate 空参数取不到类型)。
 */
@Repository
@RequiredArgsConstructor
public class StockWeightAdjustmentRepository {

    private static final String INSERT_SQL = """
            INSERT INTO stock_weight_adjustments(
                id, transaction_date, warehouse_id, goods_id, color_id, kind,
                weight_before, weight_after, delta_kg, movement_id, reverses_adjustment_id,
                source_doc_type, source_doc_id, source_item_id, reason, created_by, idempotency_key)
            VALUES (
                :id, :ts, :warehouse, :goods, CAST(:color AS uuid), :kind,
                CAST(:before AS numeric), CAST(:after AS numeric), CAST(:delta AS numeric),
                CAST(:movement AS uuid), CAST(:reverses AS uuid),
                CAST(:sourceType AS text), CAST(:sourceDoc AS uuid), CAST(:sourceItem AS uuid),
                CAST(:reason AS text),
                COALESCE(CAST(:actor AS uuid), CAST(NULLIF(current_setting('app.actor_id', true), '') AS uuid)),
                CAST(:idempotencyKey AS text))
            """;

    private final EntityManager em;

    /**
     * 一行调整。weightBefore = null 表示原来未知; weightAfter 只有撤销盘点重量且撤销后未知时才为 null。
     * createdBy 为空时取本事务绑定的操作人(app.actor_id)。
     */
    public record NewAdjustment(
            String kind,
            OffsetDateTime transactionDate,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            BigDecimal weightBefore,
            BigDecimal weightAfter,
            UUID movementId,
            UUID reversesAdjustmentId,
            String sourceDocType,
            UUID sourceDocId,
            UUID sourceItemId,
            String reason,
            UUID createdBy,
            String idempotencyKey) {
    }

    /** 已登记过的核重/盘点定重(幂等重放核对用)。 */
    public record ExistingAdjustment(UUID id, String kind, UUID warehouseId, UUID goodsId, UUID colorId,
                                     BigDecimal weightAfter) {
    }

    /** 还没被撤销的盘点定重行。 */
    public record OpenCount(UUID id, UUID warehouseId, UUID goodsId, UUID colorId,
                            BigDecimal weightBefore, BigDecimal weightAfter) {
    }

    /** 只写调整行(过账流水引起的起算/尾差; 余额由同一笔流水的 upsert 整值改写)。 */
    public UUID insert(NewAdjustment adjustment) {
        em.flush();
        UUID id = UUID.randomUUID();
        bind(em.createNativeQuery(INSERT_SQL), id, adjustment).executeUpdate();
        return id;
    }

    /**
     * 写调整行并在同一条语句里整值改写余额重量与估算标记; 不动数量、金额和最近出入库日期。
     * 余额行不存在(空维度定为 0)时只留调整行。
     */
    public UUID insertAndSetBalance(NewAdjustment adjustment, boolean estimatedAfter) {
        em.flush();
        UUID id = UUID.randomUUID();
        String sql = "WITH inserted AS (\n" + INSERT_SQL + "    RETURNING id)\n" + """
                UPDATE stock_balances balance
                SET weight = CAST(:after AS numeric),
                    weight_estimated = :estimated,
                    updated_at = now()
                WHERE balance.warehouse_id = :warehouse
                  AND balance.goods_id = :goods
                  AND balance.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                  AND EXISTS (SELECT 1 FROM inserted)
                """;
        bind(em.createNativeQuery(sql), id, adjustment)
                .setParameter("estimated", estimatedAfter)
                .executeUpdate();
        return id;
    }

    public Optional<ExistingAdjustment> findByIdempotencyKey(String idempotencyKey) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, kind, warehouse_id, goods_id, color_id, weight_after
                        FROM stock_weight_adjustments
                        WHERE idempotency_key = :key
                        """)
                .setParameter("key", idempotencyKey)
                .getResultList();
        return rows.stream().findFirst().map(row -> new ExistingAdjustment(
                (UUID) row[0], (String) row[1], (UUID) row[2], (UUID) row[3], (UUID) row[4], (BigDecimal) row[5]));
    }

    /** 某来源行上还没撤销的盘点定重/人工核重, 最新的在前(撤销按后进先出)。 */
    public List<OpenCount> openCounts(String sourceDocType, UUID sourceDocId, UUID sourceItemId) {
        String sql = """
                SELECT counted.id, counted.warehouse_id, counted.goods_id, counted.color_id,
                       counted.weight_before, counted.weight_after
                FROM stock_weight_adjustments counted
                WHERE counted.kind IN ('COUNT', 'MANUAL')
                  AND counted.source_doc_type = :sourceType
                  AND counted.source_doc_id = :sourceDoc
                """
                + (sourceItemId == null ? "  AND counted.source_item_id IS NULL\n"
                        : "  AND counted.source_item_id = :sourceItem\n")
                + """
                  AND NOT EXISTS (
                      SELECT 1 FROM stock_weight_adjustments reversal
                      WHERE reversal.reverses_adjustment_id = counted.id)
                ORDER BY counted.ledger_seq DESC
                """;
        Query query = em.createNativeQuery(sql)
                .setParameter("sourceType", sourceDocType)
                .setParameter("sourceDoc", sourceDocId);
        if (sourceItemId != null) query.setParameter("sourceItem", sourceItemId);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = query.getResultList();
        return rows.stream().map(row -> new OpenCount((UUID) row[0], (UUID) row[1], (UUID) row[2], (UUID) row[3],
                (BigDecimal) row[4], (BigDecimal) row[5])).toList();
    }

    private static Query bind(Query query, UUID id, NewAdjustment adjustment) {
        return query
                .setParameter("id", id)
                .setParameter("ts", adjustment.transactionDate())
                .setParameter("warehouse", adjustment.warehouseId())
                .setParameter("goods", adjustment.goodsId())
                .setParameter("color", adjustment.colorId())
                .setParameter("kind", adjustment.kind())
                .setParameter("before", adjustment.weightBefore())
                .setParameter("after", adjustment.weightAfter())
                .setParameter("delta", WeightMath.delta(adjustment.weightBefore(), adjustment.weightAfter()))
                .setParameter("movement", adjustment.movementId())
                .setParameter("reverses", adjustment.reversesAdjustmentId())
                .setParameter("sourceType", adjustment.sourceDocType())
                .setParameter("sourceDoc", adjustment.sourceDocId())
                .setParameter("sourceItem", adjustment.sourceItemId())
                .setParameter("reason", adjustment.reason())
                .setParameter("actor", adjustment.createdBy())
                .setParameter("idempotencyKey", adjustment.idempotencyKey());
    }
}
