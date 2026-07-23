package com.uten.imp.features.org.employee;

import com.uten.imp.common.domain.BaseEntity;
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
 * 劳动合同（1:N）。续签次数 = count(*)；当前合同 = max(sign_order)。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "employee_contracts")
public class EmployeeContract extends BaseEntity {

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "employee_id", nullable = false)
    private Employee employee;

    @Column(name = "contract_type", nullable = false)
    private String contractType;

    @Column(name = "start_date", nullable = false)
    private LocalDate startDate;

    @Column(name = "end_date")
    private LocalDate endDate;

    @Column(name = "probation_months")
    private Integer probationMonths;

    @Column(name = "sign_order", nullable = false)
    private Integer signOrder = 1;

    private String remark;
}
