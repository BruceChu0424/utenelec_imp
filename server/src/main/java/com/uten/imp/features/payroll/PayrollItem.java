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
@Table(name = "payroll_items")
public class PayrollItem extends BaseEntity {

    @Column(name = "slip_id", nullable = false)
    private UUID slipId;

    @Column(name = "line_no", nullable = false)
    private int lineNo;

    @Column(name = "item_code", nullable = false)
    private String itemCode;

    @Column(nullable = false)
    private String name;

    @Column(name = "item_type", nullable = false)
    private String itemType;

    @Column(nullable = false, precision = 18, scale = 2)
    private BigDecimal amount;

    @Column(name = "source_type", nullable = false)
    private String sourceType;

    private String description;
}
