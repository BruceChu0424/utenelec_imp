package com.uten.imp.features.org.employee;

import com.uten.imp.common.domain.AuditableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.MapsId;
import jakarta.persistence.OneToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.util.UUID;

/**
 * 薪资数字（pgcrypto 加密）。主键 = employee_id（1:1）。仅 hr+finance+admin 可见解密明文。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "employee_compensation")
public class EmployeeCompensation extends AuditableEntity {

    @Id
    @Column(name = "employee_id")
    private UUID employeeId;

    @Column(name = "base_salary_enc")
    private String baseSalaryEnc;

    @Column(name = "perf_salary_enc")
    private String perfSalaryEnc;

    @Column(name = "social_insurance_base_enc")
    private String socialInsuranceBaseEnc;

    @Column(name = "housing_fund_base_enc")
    private String housingFundBaseEnc;

    @Column(name = "allowance_standard_enc")
    private String allowanceStandardEnc;

    @Column(name = "social_insurance_location")
    private String socialInsuranceLocation;
}
