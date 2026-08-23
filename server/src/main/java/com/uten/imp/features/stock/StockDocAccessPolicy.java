package com.uten.imp.features.stock;

import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

/**
 * 仓库单据行级访问策略：按制单人(maker_id)隔离。薄壳固定 scope=stock_doc /
 * viewAll=stock_doc:view:all，判定逻辑继承自 {@link DocumentAccessPolicy}。
 *
 * <p>库存单据(stock_documents)归属列为 maker_id。生产链自动生成的领料/成品入库单
 * (DRAW/FINISHED_IN)由 {@code rejectGenericMutationOfProductionDocument} 挡在通用 CRUD 外，
 * 其生命周期走“生产专用动作权限 ∩ 仓储组织对象范围”并可跨制单人处理；手工单
 * (OTHER_IN/OUT/TRANSFER/CHECK/WASTE)继续受 maker/data-scope 隔离。
 */
@Component
public class StockDocAccessPolicy extends DocumentAccessPolicy {

    public static final String SCOPE = "stock_doc";
    public static final String VIEW_ALL = "stock_doc:view:all";

    public StockDocAccessPolicy(OwnerVisibility ownerVisibility,
                                SecurityContextCurrentUser currentUser) {
        super(SCOPE, VIEW_ALL, ownerVisibility, currentUser);
    }
}
