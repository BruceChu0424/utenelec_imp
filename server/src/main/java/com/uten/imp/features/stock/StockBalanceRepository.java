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

    /**
     * 增量 upsert 余额：不存在则插入，存在则 qty/amount_local/weight 累加已带方向符号的增量。
     *
     * @param delta 已乘 direction(+1/-1) 的数量增量
     * @param amt   已乘 direction 的金额增量
     * @param wgt   已乘 direction 的重量增量（V80 即时库存；null 视为 0，不改动既有重量）
     */
    @Modifying
    @Query(value = """
            INSERT INTO stock_balances (id, warehouse_id, goods_id, color_id, qty, amount_local, weight, last_movement_date, created_at, updated_at)
            VALUES (gen_random_uuid(), :wid, :gid, :cid, :delta, :amt, COALESCE(:wgt, 0), :ts, now(), now())
            ON CONFLICT (warehouse_id, goods_id, color_id) DO UPDATE
            SET qty = stock_balances.qty + :delta,
                amount_local = COALESCE(stock_balances.amount_local, 0) + :amt,
                weight = CASE WHEN :wgt IS NULL THEN stock_balances.weight
                              ELSE COALESCE(stock_balances.weight, 0) + :wgt END,
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
