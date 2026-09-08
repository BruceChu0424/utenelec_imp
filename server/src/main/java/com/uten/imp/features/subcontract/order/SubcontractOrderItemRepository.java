package com.uten.imp.features.subcontract.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

/** 委外订货明细仓库。明细独立管理（不走主表 @OneToMany，规避软删+cascade 坑）。 */
public interface SubcontractOrderItemRepository extends JpaRepository<SubcontractOrderItem, UUID> {

    @Query("SELECT i FROM SubcontractOrderItem i WHERE i.orderId=:orderId AND i.deleted=FALSE ORDER BY i.lineNo,i.id")
    List<SubcontractOrderItem> findByOrderIdOrderByLineNoAsc(@Param("orderId") UUID orderId);

    @Modifying
    @Query("DELETE FROM SubcontractOrderItem i WHERE i.orderId = :oid")
    void deleteByOrderId(@Param("oid") UUID orderId);

    /**
     * 货品 → 最近一次委外订货供应商（订货编辑页行级委外商「学习预填」用）。
     * 明细不落供应商（拆单后归集到单头 supplier_id），故取每个货品最新一张未删订货单的
     * 单头供应商；distinct on 按货品取一行，created_at 新者优先。
     */
    @Query(value = """
            select distinct on (i.goods_id) i.goods_id, o.supplier_id
            from subcontract_order_items i
            join subcontract_orders o on o.id = i.order_id
            join suppliers s on s.id = o.supplier_id
            where i.goods_id in (:goodsIds)
              and o.supplier_id is not null
              and o.is_deleted = false
              and s.is_deleted = false
              and (s.status is null or s.status = '使用')
              and s.is_internal_workshop = false
            order by i.goods_id, o.created_at desc, o.id desc, i.id desc
            """, nativeQuery = true)
    List<Object[]> findLastSupplierPerGoods(@Param("goodsIds") Collection<UUID> goodsIds);

    /**
     * 货品 → 最近一次委外订货商业条款（行级条款「学习预填」用）：取每个货品最新一张
     * 未删订货单的头条款（委外商/结算方式/币种/汇率/税率）。与 findLastSupplierPerGoods
     * 的差异：不过滤供应商停用状态——条款对停用商仍可参考，委外商是否可回填由前端判断。
     */
    @Query(value = """
            select distinct on (i.goods_id)
                   i.goods_id, o.supplier_id, o.settlement_method_id,
                   o.currency_id, o.exchange_rate, o.tax_rate
            from subcontract_order_items i
            join subcontract_orders o on o.id = i.order_id
            join suppliers s on s.id = o.supplier_id
            where i.goods_id in (:goodsIds)
              and o.supplier_id is not null
              and o.is_deleted = false
              and s.is_deleted = false
              and s.is_internal_workshop = false
            order by i.goods_id, o.created_at desc, o.id desc, i.id desc
            """, nativeQuery = true)
    List<Object[]> findLastTermsPerGoods(@Param("goodsIds") Collection<UUID> goodsIds);
}
