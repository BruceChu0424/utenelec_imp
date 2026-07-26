package com.uten.imp.features.org.employee;

import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.features.org.department.Department;
import com.uten.imp.features.org.position.Position;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDate;

/**
 * 员工档案主表（核心身份 + 组织 + 用工）。不含加密 PII（见 {@link EmployeeSensitive}/{@link EmployeeCompensation}）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "employees")
public class Employee extends SoftDeletableEntity {

    @Column(nullable = false, unique = true)
    private String code;

    @Column(name = "full_name", nullable = false)
    private String fullName;

    private String gender;

    @Column(name = "id_type", nullable = false)
    private String idType;

    @Column(name = "birth_date")
    private LocalDate birthDate;

    private String ethnicity;

    private String politicalStatus;

    private String maritalStatus;

    private String hujiAddress;

    private String residenceAddress;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "department_id", nullable = false)
    private Department department;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "position_id")
    private Position position;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "supervisor_id")
    private Employee supervisor;

    @Column(name = "hire_date", nullable = false)
    private LocalDate hireDate;

    @Column(name = "confirmed_at")
    private LocalDate confirmedAt;

    @Column(nullable = false)
    private String status;

    @Column(name = "employment_type", nullable = false)
    private String employmentType;

    private String workLocation;

    private String seatNo;

    private String attendanceGroup;

    private String officePhone;

    private String email;

    private String paperArchiveNo;

    /**
     * 老库 B_Worker.ID 融合键。采购等模块保留 *_legacy_id 引用老库人员 ID，
     * 待员工档案回填 legacy_id 后自动对齐到本表（报表人名解析的最终一公里）。
     */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    /**
     * 老库 B_Worker 子类（如装配/机加/质检）。迁移自动补录的员工带入；报表人名后显示「（子类）」标记。
     * HR 录入真实档案时可清空。为 null 则不显示标记。
     */
    @Column(name = "legacy_category")
    private String legacyCategory;

    /**
     * 乐观锁版本号。每次写都 +1；前端在 profile_change_requests 上 snapshot employee_version，
     * 审批时校验，不一致即 409（防止申请期内 HR 改了档案导致员工"按过期基线"被合并）。
     */
    @Column(name = "version", nullable = false)
    private Integer version = 0;
}
