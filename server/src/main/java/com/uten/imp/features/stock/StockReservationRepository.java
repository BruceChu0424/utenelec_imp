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

    /** 订单若干明细行的全部生效预留（审核释放/出货消耗用）。 */
    @Query("SELECT r FROM StockReservation r WHERE r.orderItemId IN :ids AND r.deleted = false AND r.status = 0")
    List<StockReservation> findEffectiveByOrderItemIds(@Param("ids") List<UUID> orderItemIds);

    /** 订单若干明细行的全部预留（含已完结行；净发货量判定用——部分消耗+红冲重挂的对冲口径）。 */
    @Query("SELECT r FROM StockReservation r WHERE r.orderItemId IN :ids AND r.deleted = false")
    List<StockReservation> findAllByOrderItemIds(@Param("ids") List<UUID> orderItemIds);

    /**
     * 销售可预留的全局可用量（基本单位）= 各有货仓扣安全库存后的可动量合计
     * − 全部生效预留，最小 0。
     *
     * <p>下单审核时的占用判定口径：货够不够用看全局；具体从哪个仓出，出货开单时再定。
     *
     * <p>当前主数据没有“仓库×货品”安全库存表，故将 {@code goods.min_qty}
     * 作为每个有该货品余额仓的保守下限，与实际仓库拣货闸门一致，避免全局承诺
     * 只扣一次、实际每仓都扣而形成无法履约的硬预留。
     * min_qty 为 NULL/负（脏数据）时按 0 处理；整体结果 GREATEST(...,0) 防负数预留。
     * 仅销售下单校验走此口径；生产排产读 {@code v_stock_available} 自行另扣（见 doc04 §5.3），
     * 两侧互不干扰、不重复扣减。
     */
    @Query(value = """
            SELECT GREATEST(
              (SELECT COALESCE(SUM(GREATEST(
                          COALESCE(b.qty, 0)
                          - GREATEST(
                              COALESCE(CAST(g.min_qty AS NUMERIC), 0), 0),
                          0)), 0)
                 FROM stock_balances b
                 JOIN goods g ON g.id = b.goods_id
                 WHERE b.goods_id = :gid
                   AND (b.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)))
              - (SELECT COALESCE(SUM(r.qty - r.consumed_qty - r.released_qty), 0)
                   FROM stock_reservations r
                   WHERE r.is_deleted = FALSE AND r.status = 0
                     AND r.goods_id = :gid
                     AND (r.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)))
            , 0)
            """, nativeQuery = true)
    BigDecimal globalAvailableBase(@Param("gid") UUID goodsId, @Param("cid") UUID colorId);
}
