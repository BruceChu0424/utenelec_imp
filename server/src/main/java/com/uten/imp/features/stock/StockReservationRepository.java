package com.uten.imp.features.stock;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 库存软预留仓库。
 *
 * <p>可用量计算走原生 SQL（颜色 nullable，需 IS NOT DISTINCT FROM 对齐
 * stock_balances 的 NULLS NOT DISTINCT 语义）。
 */
public interface StockReservationRepository extends JpaRepository<StockReservation, UUID> {

    /** Same effective claims as the warehouse issue gate, before its zero clamp or safety buffer. */
    @Query(value = """
            SELECT COALESCE(SUM(r.qty - r.consumed_qty - r.released_qty), 0)
            FROM stock_reservations r
            WHERE r.is_deleted = FALSE AND r.status = 0
              AND r.goods_id = :goods
              AND r.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
              AND (r.warehouse_id IS NULL OR r.warehouse_id = :warehouse)
            """, nativeQuery = true)
    BigDecimal warehouseEffectiveReservedBase(@Param("warehouse") UUID warehouseId,
            @Param("goods") UUID goodsId, @Param("color") UUID colorId);

    /** 订单若干明细行的全部生效预留（审核释放/出货消耗用）。 */
    @Query("SELECT r FROM StockReservation r WHERE r.orderItemId IN :ids AND r.deleted = false AND r.status = 0")
    List<StockReservation> findEffectiveByOrderItemIds(@Param("ids") List<UUID> orderItemIds);

    /** 订单若干明细行的全部预留（含已完结行；净发货量判定用——部分消耗+红冲重挂的对冲口径）。 */
    @Query("SELECT r FROM StockReservation r WHERE r.orderItemId IN :ids AND r.deleted = false")
    List<StockReservation> findAllByOrderItemIds(@Param("ids") List<UUID> orderItemIds);

    /**
     * 销售可预留的全局可用量(基本单位) = 数据库 fn_stock_global_usable(ADR-146 可用量单一口径):
     * 计入可用量的仓(未删、记账、非不良品仓、非车间内料仓、作业叶仓)各扣安全库存后的可动量合计
     * - 全部生效预留(全局预留只扣一次), 最小 0。下单审核占用、退货重预留都读它。
     */
    @Query(value = "SELECT fn_stock_global_usable(:gid, CAST(:cid AS uuid))", nativeQuery = true)
    BigDecimal globalAvailableBase(@Param("gid") UUID goodsId, @Param("cid") UUID colorId);
}
