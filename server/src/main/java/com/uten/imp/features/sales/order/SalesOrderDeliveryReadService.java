package com.uten.imp.features.sales.order;

import com.uten.imp.common.delivery.DeliveryBom;
import com.uten.imp.common.delivery.DeliveryPlan;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.UUID;

/** A document's frozen evidence is read through that document's real admission path, never arbitrary goods. */
@Service
@RequiredArgsConstructor
public class SalesOrderDeliveryReadService {
    private final SalesOrderService orders;
    private final SalesOrderFinanceConfirmService reviews;
    private final SalesOrderItemRepository items;
    public enum Context { SALES, MANAGER, FINANCE }
    public record Frozen(int version,UUID orderId,UUID orderItemId,UUID goodsId,
            DeliveryPlan deliveryPlan,String bomFingerprint,DeliveryBom.Node root,boolean missing,String missingReason) {}

    @Transactional(readOnly=true)
    public Frozen read(UUID orderId,UUID itemId,Context context) {
        // Calls cross the existing proxied services, preserving their authorities, object scope and history fences.
        switch(context) {
            case SALES -> orders.detail(orderId);
            case MANAGER -> reviews.managerReview(orderId);
            case FINANCE -> reviews.review(orderId);
        }
        SalesOrderItem item=items.findById(itemId)
                .filter(row -> orderId.equals(row.getOrderId()))
                .orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"本单不存在该交付明细"));
        DeliveryBom.Snapshot snapshot=item.getDeliveryBomSnapshot();
        if(snapshot==null) return new Frozen(1,orderId,itemId,item.getGoodsId(),
                SalesOrderDeliveryService.effective(item.getDeliveryPlan()),null,null,true,
                "该历史明细没有冻结的交付BOM，不能用今天的BOM代替原始记录");
        return new Frozen(1,orderId,itemId,item.getGoodsId(),SalesOrderDeliveryService.effective(item.getDeliveryPlan()),
                snapshot.bomFingerprint(),snapshot.root(),false,null);
    }
}
