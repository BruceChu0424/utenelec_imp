package com.uten.imp.features.finance.other_income;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 其它收入明细分摊。源老库 M_OGetItem（1,551 行）。
 *
 * <p>{@code income_style_id → payment_styles(category=INCOME)}（如销售收入/利息/保证金…）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_other_income_items")
public class FinanceOtherIncomeItem extends BaseEntity {

    private Integer legacyId;                         // M_OGetItem.ID

    @Column(name = "income_id", nullable = false)
    private UUID incomeId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** 收入项目，→ payment_styles(category=INCOME)。 */
    @Column(name = "income_style_id")
    private UUID incomeStyleId;

    @Column(name = "department_id")
    private UUID departmentId;

    @Column(name = "counterpart_account_id")
    private UUID counterpartAccountId;

    @Column(name = "counterpart_name")
    private String counterpartName;

    @Column(name = "qty", precision = 18, scale = 4)
    private BigDecimal qty;

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    private String summary;

    @Column(name = "line_no")
    private Integer lineNo;

    private String remark;
}
