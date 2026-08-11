package com.uten.imp.features.payroll;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import jakarta.persistence.Version;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "payroll_slips")
public class PayrollSlip extends BaseEntity {

    @Column(name = "batch_id", nullable = false)
    private UUID batchId;

    @Column(name = "employee_id", nullable = false)
    private UUID employeeId;

    @Column(name = "employee_code_snapshot", nullable = false)
    private String employeeCodeSnapshot;

    @Column(name = "employee_name_snapshot", nullable = false)
    private String employeeNameSnapshot;

    @Column(name = "department_id_snapshot")
    private UUID departmentIdSnapshot;

    @Column(name = "department_name_snapshot")
    private String departmentNameSnapshot;

    @Column(name = "payroll_year", nullable = false)
    private short payrollYear;

    @Column(name = "payroll_month", nullable = false)
    private short payrollMonth;

    @Column(nullable = false)
    private String status = "PENDING";

    @Column(name = "gross_income", nullable = false, precision = 18, scale = 2)
    private BigDecimal grossIncome;

    @Column(name = "total_deduction", nullable = false, precision = 18, scale = 2)
    private BigDecimal totalDeduction;

    @Column(name = "net_income", nullable = false, precision = 18, scale = 2)
    private BigDecimal netIncome;

    @Column(nullable = false)
    private boolean active = true;

    @Column(name = "published_at")
    private Instant publishedAt;

    @Column(name = "viewed_at")
    private Instant viewedAt;

    @Column(name = "downloaded_at")
    private Instant downloadedAt;

    private String remark;

    @Version
    @Column(nullable = false)
    private long version;
}
