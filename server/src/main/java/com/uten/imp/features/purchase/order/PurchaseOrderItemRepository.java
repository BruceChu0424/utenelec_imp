package com.uten.imp.features.purchase.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface PurchaseOrderItemRepository extends JpaRepository<PurchaseOrderItem, UUID> {

    List<PurchaseOrderItem> findByOrderIdOrderByLineNoAsc(UUID orderId);

    @Modifying
    @Query("DELETE FROM PurchaseOrderItem i WHERE i.orderId = :oid")
    void deleteByOrderId(@Param("oid") UUID orderId);

    /**
     * 货品 → 最近一次订货供应商（订货编辑页行级供应商「学习预填」用）。
     * 明细不落供应商（拆单后归集到单头 supplier_id），故取每个货品最新一张未删订货单的
     * 单头供应商；distinct on 按货品取一行，created_at 新者优先。
     */
    @Query(value = """
            select distinct on (i.goods_id) i.goods_id, o.supplier_id
            from purchase_order_items i
            join purchase_orders o on o.id = i.order_id
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
}
