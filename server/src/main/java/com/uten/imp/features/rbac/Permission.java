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

    /** 一级功能模块（如「基础资料」「销售管理」）；V228 引入，驱动权限目录一级分组。 */
    @Column(name = "module")
    private String module;

    /** 权限目录组内展示排序（V27 新增列，默认 0）。 */
    @Column(name = "sort_order", nullable = false)
    private Integer sortOrder = 0;
}
