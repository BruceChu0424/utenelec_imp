package com.uten.imp.features.documents;

import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;

/**
 * 草稿计数用的归属范围适配器：只依赖平台安全基座，不依赖任何业务 feature。
 *
 * <p>与 {@code ProductionChainSalesAccessPolicy}/{@code ProductionChainStockAccessPolicy}
 * 同一范式——scope 字符串与 {@code *:view:all} 权限码在构造时写死，判定逻辑全部继承自
 * {@link DocumentAccessPolicy}。这样跨模块的草稿汇总可以复用各模块既有的对象级范围
 * （{@code user_data_scopes.scope} + 交接继承 + {@code *:view:all} 旁路），而不引入
 * documents → sales/purchase/... 的跨 feature 依赖边（ADR-017）。
 *
 * <p>非 Spring bean：由 {@link DocumentDraftCountQueryService} 按单据类型实例化。
 */
final class DraftScopeAccessPolicy extends DocumentAccessPolicy {

    DraftScopeAccessPolicy(String scope,
                           String viewAllAuthority,
                           OwnerVisibility ownerVisibility,
                           SecurityContextCurrentUser currentUser) {
        super(scope, viewAllAuthority, ownerVisibility, currentUser);
    }
}
