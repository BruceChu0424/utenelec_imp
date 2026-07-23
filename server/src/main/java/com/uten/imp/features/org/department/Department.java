package com.uten.imp.features.org.department;

import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.features.org.employee.Employee;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/**
 * 部门（组织架构树）。邻接表 parent + 语义 level + 物化路径 path（path 由 DB 触发器维护）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "departments")
public class Department extends SoftDeletableEntity {

    @Column(nullable = false, unique = true)
    private String code;

    @Column(nullable = false)
    private String name;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "parent_id")
    private Department parent;

    @Column(nullable = false)
    private String level;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "manager_id")
    private Employee manager;

    @Column(name = "sort_order")
    private Integer sortOrder = 0;

    @Column(nullable = false)
    private String path = "/";

    @Column(nullable = false)
    private Integer headcount = 0;
}
