package com.uten.imp.features.production;

import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

/**
 * 生产单据行级访问策略：按制单人(maker_id)隔离。薄壳固定 scope=production_plan /
 * viewAll=production_plan:view:all，判定逻辑继承自 {@link DocumentAccessPolicy}。
 *
 * <p>覆盖生产计划与生产日报（归属列均为 maker_id）。MRP 自审核(autoApproveForOrchestrator)
 * 等系统内部路径豁免本隔离。
 */
@Component
public class ProductionDocumentAccessPolicy extends DocumentAccessPolicy {

    public static final String SCOPE = "production_plan";
    public static final String VIEW_ALL = "production_plan:view:all";

    public ProductionDocumentAccessPolicy(OwnerVisibility ownerVisibility,
                                          SecurityContextCurrentUser currentUser) {
        super(SCOPE, VIEW_ALL, ownerVisibility, currentUser);
    }
}
