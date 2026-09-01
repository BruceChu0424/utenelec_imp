package com.uten.imp.features.master.referencemethod;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "settlement_methods")
public class SettlementMethod extends SoftDeletableEntity {
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;
    @Column(nullable = false, unique = true)
    private String code;
    @Column(name = "system_role", unique = true)
    private String systemRole;
    @Column(name = "legacy_code")
    private String legacyCode;
    @Column(nullable = false)
    private String name;
    @Column(nullable = false)
    private String status = "使用";
    @Column(name = "sort_order", nullable = false)
    private Integer sortOrder = 0;
    private String remark;

    // ===== 账期策略（V330/ADR-047；V453 起可经结算方式管理页维护）=====
    /** 到期基准：RECEIPT_DATE/QC_ACCEPTANCE_DATE/STATEMENT_END/STATEMENT_CONFIRM_DATE/INVOICE_DATE。 */
    @Column(name = "terms_base", nullable = false)
    private String termsBase = "RECEIPT_DATE";
    /** 到期规则：NET_DAYS/EOM_PLUS_DAYS/FIXED_DAY_OF_MONTH。 */
    @Column(name = "due_rule", nullable = false)
    private String dueRule = "NET_DAYS";
    /** 默认天数（0-3650）；供应商正数 tday 优先。 */
    @Column(name = "default_due_days", nullable = false)
    private Integer defaultDueDays = 0;
    /** 固定日（1-31）；仅 FIXED_DAY_OF_MONTH 时非空。 */
    @Column(name = "fixed_day_of_month")
    private Integer fixedDayOfMonth;
    /** 跨月数（0-120）。 */
    @Column(name = "months_ahead", nullable = false)
    private Integer monthsAhead = 0;
}
