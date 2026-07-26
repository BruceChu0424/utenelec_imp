package com.uten.imp.features.finance.expense;

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
 * 一般费用明细分摊。源老库 M_DPaidItem（8,537 行）。按部门分摊。
 *
 * <p>{@code expense_style_id → payment_styles(category=EXPENSE)}（如办公费/差旅费/房租…）。
 * {@code department_id} 分摊部门。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "finance_expense_items")
public class FinanceExpenseItem extends BaseEntity {

    private Integer legacyId;                         // M_DPaidItem.ID

    @Column(name = "expense_id", nullable = false)
    private UUID expenseId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** 费用项目（办公费/差旅费/房租…），→ payment_styles(category=EXPENSE)。 */
    @Column(name = "expense_style_id")
    private UUID expenseStyleId;

    /** 分摊部门。 */
    @Column(name = "department_id")
    private UUID departmentId;

    /** AccID 对方账户。 */
    @Column(name = "counterpart_account_id")
    private UUID counterpartAccountId;

    /** dfmc 对方名称。 */
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

    /** Summary 摘要。 */
    private String summary;

    @Column(name = "line_no")
    private Integer lineNo;

    private String remark;
}
