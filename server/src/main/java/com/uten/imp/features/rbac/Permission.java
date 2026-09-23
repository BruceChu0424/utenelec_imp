package com.uten.imp.features.rbac;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.util.Set;

/**
 * 权限点（如 employee:view / payroll:generate）。
 *
 * <p>目录里的每一行都是活码：停用即删除(V677 起没有「软停用」)。怎么授只看
 * {@link #grantPolicy}(ADR-109 授权策略唯一事实源)，谁都有只看 {@link #baseline}。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "permissions")
public class Permission extends BaseEntity {

    @Column(nullable = false, unique = true)
    private String code;

    @Column(nullable = false)
    private String name;

    /** 二级子类（如「货品资料」「销售订货」）；驱动权限目录二级分组。 */
    private String category;

    /** 一级功能模块(如「基础资料」「销售管理」)；驱动权限目录一级分组。 */
    @Column(name = "module")
    private String module;

    /** 数据库维护的显式动作分类；运行时绝不再由 code 后缀推断。 */
    @Column(name = "action_type")
    private String actionType;

    /** 面向管理员的权限范围/业务副作用说明。 */
    private String description;

    /** 授权策略(text[]，取值见 {@link GrantPolicy}；NORMAL 只能单独出现)。 */
    @JdbcTypeCode(SqlTypes.ARRAY)
    @Column(name = "grant_policy", nullable = false, columnDefinition = "text[]")
    private String[] grantPolicy = {GrantPolicy.NORMAL.name()};

    /** 全员基础包：每个在职员工隐式持有(管理页可编辑，个人收回仍优先)。 */
    @Column(nullable = false)
    private boolean baseline;

    /** 管理端风险标签(仅展示用，不参与授权判定)；商业敏感权限提示可见字段。 */
    @Column(nullable = false)
    private String sensitivity = "NORMAL";

    /** 权限目录组内展示排序。 */
    @Column(name = "sort_order", nullable = false)
    private Integer sortOrder = 0;

    /** 解析后的授权策略集合。 */
    public Set<GrantPolicy> grantPolicies() {
        return GrantPolicy.parse(grantPolicy);
    }
}
