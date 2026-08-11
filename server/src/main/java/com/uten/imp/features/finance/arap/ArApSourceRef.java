package com.uten.imp.features.finance.arap;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * AR/AP 立账的一对多不可变业务来源快照。
 *
 * <p>当前仅保存销售发运对应的 {@code SALES_ORDER} 来源。金额取发运行快照，
 * 不回查可能已被后续业务调整的订单金额。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "ar_ap_source_refs")
public class ArApSourceRef extends BaseEntity {

    public static final String SALES_ORDER = "SALES_ORDER";

    @Column(name = "ledger_id", nullable = false)
    private UUID ledgerId;

    @Column(name = "source_type", nullable = false)
    private String sourceType;

    @Column(name = "source_id", nullable = false)
    private UUID sourceId;

    @Column(name = "source_no", nullable = false)
    private String sourceNo;

    @Column(name = "amount_original", nullable = false, precision = 18, scale = 4)
    private BigDecimal amountOriginal = BigDecimal.ZERO;

    @Column(name = "amount_local", nullable = false, precision = 18, scale = 4)
    private BigDecimal amountLocal = BigDecimal.ZERO;
}
