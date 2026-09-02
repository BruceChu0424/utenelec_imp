package com.uten.imp.features.org.employee;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDate;

/**
 * 兼职部门归属（V459）：员工在主部门之外兼任的部门。
 *
 * <p>权限合成把每个兼职部门（含其全部上级递归）的配置并入有效权限并集；
 * 待审弹卡/收件台的定向资格按「主部门或兼职部门 ∈ 部门子树 且 持有职责权限码」
 * 判定。行级变更由触发器即时 bump 该员工的 users.auth_version（V135 机制）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "employee_secondary_departments")
public class EmployeeSecondaryDepartment extends BaseEntity {

    @Column(name = "employee_id", nullable = false, updatable = false)
    private java.util.UUID employeeId;

    @Column(name = "department_id", nullable = false)
    private java.util.UUID departmentId;

    /** 兼职开始日期（仅展示/审计用，不参与权限时效判定）。 */
    @Column(name = "started_on")
    private LocalDate startedOn;

    @Column(name = "note")
    private String note;
}
