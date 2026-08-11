package com.uten.imp.features.payroll;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "payroll_variable_inputs")
public class PayrollVariableInput extends BaseEntity {

    @Column(name = "employee_id", nullable = false)
    private UUID employeeId;

    @Column(name = "payroll_year", nullable = false)
    private short payrollYear;

    @Column(name = "payroll_month", nullable = false)
    private short payrollMonth;

    @Column(name = "overtime_amount", nullable = false, precision = 18, scale = 2)
    private BigDecimal overtimeAmount = BigDecimal.ZERO;

    @Column(name = "bonus_amount", nullable = false, precision = 18, scale = 2)
    private BigDecimal bonusAmount = BigDecimal.ZERO;

    @Column(name = "social_insurance_amount", nullable = false, precision = 18, scale = 2)
    private BigDecimal socialInsuranceAmount = BigDecimal.ZERO;

    @Column(name = "housing_fund_amount", nullable = false, precision = 18, scale = 2)
    private BigDecimal housingFundAmount = BigDecimal.ZERO;

    @Column(name = "tax_amount", nullable = false, precision = 18, scale = 2)
    private BigDecimal taxAmount = BigDecimal.ZERO;

    @Column(name = "other_earning_amount", nullable = false, precision = 18, scale = 2)
    private BigDecimal otherEarningAmount = BigDecimal.ZERO;

    @Column(name = "other_deduction_amount", nullable = false, precision = 18, scale = 2)
    private BigDecimal otherDeductionAmount = BigDecimal.ZERO;

    @Column(name = "source_note")
    private String sourceNote;
}
