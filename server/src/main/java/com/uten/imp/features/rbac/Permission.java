package com.uten.imp.features.rbac;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/** 权限点（如 employee:view / payroll:generate）。 */
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

    /** 一级功能模块（如「基础资料」「销售管理」）；引入，驱动权限目录一级分组。 */
    @Column(name = "module")
    private String module;

    /** 数据库维护的显式动作分类；运行时绝不再由 code 后缀推断。 */
    @Column(name = "action_type")
    private String actionType;

    /** 面向管理员的权限范围/业务副作用说明。 */
    private String description;

    /** FALSE 保留历史审计行，但目录和有效权限解析均排除。 */
    @Column(nullable = false)
    private boolean active = true;

    /** FALSE 禁止任何管理端写入新的授权配置。 */
    @Column(nullable = false)
    private boolean assignable = true;

    /** 权限目录组内展示排序（新增列，默认 0）。 */
    @Column(name = "sort_order", nullable = false)
    private Integer sortOrder = 0;
}
