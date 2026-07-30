package com.uten.imp.features.stock;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 库存软预留仓库（V90）。
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
     * 全局可用量（基本单位）= 全仓账面合计 − 全部生效预留（含全局与各仓绑定）。
     *
     * <p>下单审核时的占用判定口径：货够不够用看全局；具体从哪个仓出，出货开单时再定。
     */
    @Query(value = """
            SELECT (SELECT COALESCE(SUM(b.qty), 0) FROM stock_balances b
                     WHERE b.goods_id = :gid
                       AND (b.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)))
                 - (SELECT COALESCE(SUM(r.qty - r.consumed_qty - r.released_qty), 0)
                     FROM stock_reservations r
                     WHERE r.is_deleted = FALSE AND r.status = 0
                       AND r.goods_id = :gid
                       AND (r.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)))
            """, nativeQuery = true)
    BigDecimal globalAvailableBase(@Param("gid") UUID goodsId, @Param("cid") UUID colorId);
}
