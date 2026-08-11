package com.uten.imp.features.sales;

import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

/**
 * 销售单据行级访问策略（V91）。薄壳：固定 scope=sales / viewAll=sales:view:all，
 * 全部判定逻辑继承自平台级 {@link DocumentAccessPolicy}。
 *
 * <p>读语义保留迁移 legacy 行：归属 NULL 可读但普通用户不可写；非 NULL 归属限于
 * 当前员工 + 显式委托的销售数据范围。超管、{@code sales:view:all} 与调用方传入的
 * 操作级 authority 可旁路归属限制。
 */
@Component
public class SalesDocumentAccessPolicy extends DocumentAccessPolicy {

    public static final String SCOPE = "sales";
    public static final String VIEW_ALL = "sales:view:all";

    public SalesDocumentAccessPolicy(OwnerVisibility ownerVisibility,
                                     SecurityContextCurrentUser currentUser) {
        super(SCOPE, VIEW_ALL, ownerVisibility, currentUser);
    }
}
