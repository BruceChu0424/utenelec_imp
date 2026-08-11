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
@Table(name = "payroll_batches")
public class PayrollBatch extends BaseEntity {

    @Column(name = "payroll_year", nullable = false)
    private short payrollYear;

    @Column(name = "payroll_month", nullable = false)
    private short payrollMonth;

    @Column(name = "department_id")
    private UUID departmentId;

    @Column(name = "department_name_snapshot")
    private String departmentNameSnapshot;

    @Column(nullable = false)
    private String status = "DRAFT";

    @Column(name = "include_overtime", nullable = false)
    private boolean includeOvertime;

    @Column(name = "include_bonus", nullable = false)
    private boolean includeBonus;

    @Column(name = "include_social_insurance", nullable = false)
    private boolean includeSocialInsurance;

    @Column(name = "include_tax", nullable = false)
    private boolean includeTax;

    @Column(nullable = false)
    private int headcount;

    @Column(name = "gross_income", nullable = false, precision = 18, scale = 2)
    private BigDecimal grossIncome = BigDecimal.ZERO;

    @Column(name = "total_deduction", nullable = false, precision = 18, scale = 2)
    private BigDecimal totalDeduction = BigDecimal.ZERO;

    @Column(name = "net_income", nullable = false, precision = 18, scale = 2)
    private BigDecimal netIncome = BigDecimal.ZERO;

    @Column(name = "generated_by", nullable = false)
    private UUID generatedBy;

    @Column(name = "submitted_by")
    private UUID submittedBy;

    @Column(name = "approved_by")
    private UUID approvedBy;

    @Column(name = "published_by")
    private UUID publishedBy;

    @Column(name = "submitted_at")
    private Instant submittedAt;

    @Column(name = "approved_at")
    private Instant approvedAt;

    @Column(name = "published_at")
    private Instant publishedAt;

    @Column(name = "rejected_at")
    private Instant rejectedAt;

    @Column(name = "reject_reason")
    private String rejectReason;

    @Version
    @Column(nullable = false)
    private long version;
}
