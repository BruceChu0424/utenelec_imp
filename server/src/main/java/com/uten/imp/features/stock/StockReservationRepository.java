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
     * 销售可预留的全局可用量（基本单位）= 全仓账面合计 − 全部生效预留 − 货品安全库存，最小 0。
     *
     * <p>下单审核时的占用判定口径：货够不够用看全局；具体从哪个仓出，出货开单时再定。
     *
     * <p>V178 缺口 C：扣减 {@code goods.min_qty}（安全库存），对齐生产侧
     * {@code MrpService}「当前可用 = 账面 − 生效销售预留 − 货品安全库存，最小 0」。
     * 安全库存仅货品级字段（无颜色维度），对每个颜色分别应用是保守口径（与生产侧一致）。
     * min_qty 为 NULL/负（脏数据）时按 0 处理；整体结果 GREATEST(...,0) 防负数预留。
     * 仅销售下单校验走此口径；生产排产读 {@code v_stock_available} 自行另扣（见 doc04 §5.3），
     * 两侧互不干扰、不重复扣减。
     */
    @Query(value = """
            SELECT GREATEST(
              (SELECT COALESCE(SUM(b.qty), 0) FROM stock_balances b
                 WHERE b.goods_id = :gid
                   AND (b.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)))
              - (SELECT COALESCE(SUM(r.qty - r.consumed_qty - r.released_qty), 0)
                   FROM stock_reservations r
                   WHERE r.is_deleted = FALSE AND r.status = 0
                     AND r.goods_id = :gid
                     AND (r.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid)))
              - (SELECT GREATEST(COALESCE(CAST(g.min_qty AS NUMERIC), 0), 0)
                   FROM goods g WHERE g.id = :gid)
            , 0)
            """, nativeQuery = true)
    BigDecimal globalAvailableBase(@Param("gid") UUID goodsId, @Param("cid") UUID colorId);
}
