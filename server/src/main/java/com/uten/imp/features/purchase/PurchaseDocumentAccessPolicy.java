package com.uten.imp.features.purchase;

import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

/**
 * 采购单据行级访问策略：按制单人(maker_id)隔离。薄壳固定 scope=purchase /
 * viewAll=purchase:view:all，判定逻辑继承自 {@link DocumentAccessPolicy}。
 *
 * <p>采购订单/收货/退货的归属列为 maker_id（create 即填当前员工）。采购/委外「申请」
 * 是计划系统生成的只读需求单，不接入本隔离（持 :view 可见全部）。
 */
@Component
public class PurchaseDocumentAccessPolicy extends DocumentAccessPolicy {

    public static final String SCOPE = "purchase";
    public static final String VIEW_ALL = "purchase:view:all";

    public PurchaseDocumentAccessPolicy(OwnerVisibility ownerVisibility,
                                        SecurityContextCurrentUser currentUser) {
        super(SCOPE, VIEW_ALL, ownerVisibility, currentUser);
    }
}
