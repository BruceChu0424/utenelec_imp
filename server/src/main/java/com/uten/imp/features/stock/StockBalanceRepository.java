package com.uten.imp.features.stock;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.Optional;
import java.util.UUID;

/**
 * 库存余额仓库。
 *
 * <p>upsertBalance 用原生 SQL（pg 16 NULLS NOT DISTINCT 唯一约束，无色 color_id=null 正确合并），
 * 单据审核同事务调用，O(1) 维护余额。
 */
public interface StockBalanceRepository
        extends JpaRepository<StockBalance, UUID>, JpaSpecificationExecutor<StockBalance> {

    Optional<StockBalance> findByWarehouseIdAndGoodsIdAndColorId(UUID warehouseId, UUID goodsId, UUID colorId);

    interface PhysicalSnapshot {
        BigDecimal getQty();
        BigDecimal getWeight();
    }

    /** Native scalar projection deliberately bypasses cached entities after same-transaction upserts. */
    @Query(value="""
            SELECT qty,weight FROM stock_balances WHERE warehouse_id=:warehouse AND goods_id=:goods
                AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
            """,nativeQuery=true)
    java.util.List<PhysicalSnapshot> readPhysicalSnapshot(@Param("warehouse") UUID warehouseId,
            @Param("goods") UUID goodsId,@Param("color") UUID colorId);

    /**
     * Operationally movable quantity in one warehouse, in base units.
     *
     * <p>Global reservations are conservatively protected in every warehouse;
     * warehouse-bound reservations are protected only in their warehouse.
     * Safety stock is a goods-level policy and is therefore applied to each
     * warehouse, matching the existing ATP/readiness convention.
     */
    @Query(value = """
            SELECT GREATEST(
                COALESCE((
                    SELECT b.qty
                    FROM stock_balances b
                    WHERE b.warehouse_id = :wid
                      AND b.goods_id = :gid
                      AND b.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
                ), 0)
                - COALESCE((
                    SELECT SUM(r.qty - r.consumed_qty - r.released_qty)
                    FROM stock_reservations r
                    WHERE r.is_deleted = FALSE
                      AND r.status = 0
                      AND r.goods_id = :gid
                      AND r.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
                      AND (r.warehouse_id IS NULL OR r.warehouse_id = :wid)
                ), 0)
                - COALESCE((
                    SELECT GREATEST(COALESCE(CAST(g.min_qty AS NUMERIC), 0), 0)
                    FROM goods g
                    WHERE g.id = :gid
                ), 0),
                0)
            """, nativeQuery = true)
    BigDecimal warehouseAvailableBase(@Param("wid") UUID warehouseId,
                                      @Param("gid") UUID goodsId,
                                      @Param("cid") UUID colorId);

    /** A fresh ISSUE posting consumes an existing allocation before its physical movement. */
    @Query(value = """
            SELECT CASE WHEN COUNT(*) > 0 AND BOOL_AND(
                    posting.posting_type = 'ISSUE'
                    AND posting.xmin = pg_current_xact_id()::xid
                    AND reservation.xmin = pg_current_xact_id()::xid
                    AND reservation.is_deleted = FALSE
                    AND reservation.owner_type = 'PRODUCTION_MATERIAL_DEMAND'
                    AND reservation.demand_id = posting.demand_id
                    AND reservation.warehouse_id = :wid
                    AND reservation.goods_id = :gid
                    AND reservation.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
                    AND reservation.consumed_qty >= posting.qty_base
                    AND reservation.consumed_qty = (
                        SELECT COALESCE(SUM(CASE WHEN history.posting_type IN ('ISSUE', 'GOOD_RETURN_REVERSE')
                            THEN history.qty_base ELSE -history.qty_base END), 0)
                        FROM production_material_stock_postings history
                        WHERE history.reservation_id = reservation.id)
                    AND NOT EXISTS (SELECT 1 FROM production_material_stock_postings reverse
                        WHERE reverse.source_posting_id = posting.id))
                THEN SUM(posting.qty_base) ELSE 0 END
            FROM production_material_stock_events event
            JOIN production_material_stock_postings posting ON posting.event_id = event.id
            JOIN stock_reservations reservation ON reservation.id = posting.reservation_id
            JOIN stock_documents document ON document.id = event.stock_document_id
            JOIN stock_document_items item ON item.doc_id = document.id AND item.id = posting.stock_document_item_id
            WHERE event.id = :eventId AND event.event_type = 'ISSUE'
              AND event.xmin = pg_current_xact_id()::xid
              AND document.id = :documentId AND document.doc_type = 'DRAW'
              AND document.status = 1 AND document.is_deleted = FALSE
              AND document.warehouse_id = :wid
              AND item.id = :itemId AND item.is_deleted = FALSE
              AND item.goods_id = :gid AND item.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
              AND item.unit_id = :unitId AND COALESCE(item.unit_rate, 1) = :unitRate
              AND NOT EXISTS (SELECT 1 FROM production_material_movement_links bound
                  WHERE bound.event_id = event.id AND bound.document_item_id = item.id)
            """, nativeQuery = true)
    BigDecimal unboundProductionIssueQuantity(@Param("eventId") UUID eventId,
            @Param("documentId") UUID documentId, @Param("itemId") UUID itemId,
            @Param("wid") UUID warehouseId, @Param("gid") UUID goodsId, @Param("cid") UUID colorId,
            @Param("unitId") UUID unitId, @Param("unitRate") BigDecimal unitRate);

    /** A proven allocation already kept its main-warehouse buffer; remaining hard claims still apply. */
    @Query(value = """
            SELECT GREATEST(COALESCE((SELECT balance.qty FROM stock_balances balance
                WHERE balance.warehouse_id = :wid AND balance.goods_id = :gid
                  AND balance.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)), 0)
                - COALESCE((SELECT SUM(reservation.qty - reservation.consumed_qty - reservation.released_qty)
                    FROM stock_reservations reservation
                    WHERE reservation.is_deleted = FALSE AND reservation.status = 0
                      AND reservation.goods_id = :gid
                      AND reservation.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)
                      AND (reservation.warehouse_id IS NULL OR reservation.warehouse_id = :wid)), 0), 0)
            """, nativeQuery = true)
    BigDecimal warehouseUnreservedBase(@Param("wid") UUID warehouseId,
            @Param("gid") UUID goodsId, @Param("cid") UUID colorId);

    /**
     * 增量 upsert 余额：不存在则插入，存在则 qty/amount_local/weight 累加已带方向符号的增量。
     *
     * @param delta 已乘 direction(+1/-1) 的数量增量
     * @param amt   已乘 direction 的金额增量
     * @param wgt   行实际总重量乘 direction 后的增量（null 不改动既有重量）
     */
    @Modifying
    @Query(value = """
            INSERT INTO stock_balances (id, warehouse_id, goods_id, color_id, qty, amount_local, weight, last_movement_date, created_at, updated_at)
            VALUES (gen_random_uuid(), :wid, :gid, :cid, :delta, :amt, :wgt, :ts, now(), now())
            ON CONFLICT (warehouse_id, goods_id, color_id) DO UPDATE
            SET qty = stock_balances.qty + :delta,
                amount_local = COALESCE(stock_balances.amount_local, 0) + :amt,
                weight = CASE
                    WHEN :wgt IS NULL THEN stock_balances.weight
                    WHEN stock_balances.weight IS NOT NULL
                        THEN stock_balances.weight + :wgt
                    WHEN stock_balances.qty = 0 AND :wgt >= 0 THEN :wgt
                    ELSE NULL
                END,
                last_movement_date = :ts,
                updated_at = now()
            """, nativeQuery = true)
    void upsertBalance(@Param("wid") UUID warehouseId,
                       @Param("gid") UUID goodsId,
                       @Param("cid") UUID colorId,
                       @Param("delta") BigDecimal delta,
                       @Param("amt") BigDecimal amt,
                       @Param("wgt") BigDecimal wgt,
                       @Param("ts") OffsetDateTime ts);
}
