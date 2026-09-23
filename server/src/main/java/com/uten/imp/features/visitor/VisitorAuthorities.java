package com.uten.imp.features.visitor;

import java.util.Set;

/**
 * 外部访客主体的专用权限(ADR-109)：只发在访客令牌里，不属于员工权限目录，
 * 不能被任何员工授权入口授出。命名空间 {@code visitor_portal:} 与员工目录码严格隔离，
 * 契约测试 PreAuthorizeCodesAreActiveContractTest 只对这一前缀放行。
 */
public final class VisitorAuthorities {

    /** 访客门户：提交/查看本人访客申请、搜索接待人。 */
    public static final String APPLY = "visitor_portal:apply";

    /** 访客令牌携带的全部权限。 */
    public static final Set<String> ALL = Set.of(APPLY);

    /** 访客专用权限的命名空间前缀。 */
    public static final String NAMESPACE = "visitor_portal:";

    private VisitorAuthorities() {
    }
}
