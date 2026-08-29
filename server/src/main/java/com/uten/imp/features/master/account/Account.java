package com.uten.imp.features.master.account;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 账户主档（基础资料-账户资料）。源 M_Acc（27 行）。
 *
 * <p>逐字段对应 accounts 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 账户类型靠 {@code account_type} 枚举重建（老库 AStyle 全为 1，退化丢弃）；按 {@code name}
 * 关键字映射，规则见 {@link AccountService#inferAccountType}（迁移脚本与运行时复用同一份语义）。
 *
 * <p>余额守恒：{@code balanceCurrent = initBalance + receiptsTotal − paymentsTotal
 * + balanceAdjustmentsTotal}
 * （Service 维护；详见 design doc 26 §五 Service 层断言）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "accounts")
public class Account extends SoftDeletableEntity {

    /** 老库 M_Acc.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    /** 账户编号（源 M_Acc.Number：001~009 / UT00101 含币种前缀）。 */
    private String code;

    /** 账户名称（源 M_Acc.AccName：农业银行/现金/微信/支票/基本户…）。 */
    @Column(name = "name", nullable = false)
    private String name;

    /** 银行账号尾号（源 M_Acc.AccNode，仅基本户填）。 */
    @Column(name = "bank_account_no")
    private String bankAccountNo;

    /**
     * 账户类型枚举（取代退化字段 AStyle）：
     * BANK/CASH/CHECK/FOREIGN_CHECK/THIRD_PARTY/OFFSHORE/GENERAL。
     * 由前端枚举下拉选择；迁移时按 name 关键字 CASE WHEN 映射。
     */
    @Column(name = "account_type", nullable = false)
    private String accountType = "BANK";

    /** 币种（多币种账户：香港=USD，其它=RMB）。 */
    @Column(name = "currency_id")
    private UUID currencyId;

    /** 期初金额（源 M_Acc.InitTotal，仅基本户/现金有非零值）。 */
    @Column(name = "init_balance", precision = 18, scale = 4)
    private BigDecimal initBalance = BigDecimal.ZERO;

    /** 收入累计（源 M_Acc.GetTotal，Service 累加）。 */
    @Column(name = "receipts_total", precision = 18, scale = 4)
    private BigDecimal receiptsTotal = BigDecimal.ZERO;

    /** 支出累计（源 M_Acc.PaidTotal，Service 累加）。 */
    @Column(name = "payments_total", precision = 18, scale = 4)
    private BigDecimal paymentsTotal = BigDecimal.ZERO;

    /** 已过账余额校准差额累计；不混入正常收款/付款累计。 */
    @Column(name = "balance_adjustments_total", precision = 18, scale = 4)
    private BigDecimal balanceAdjustmentsTotal = BigDecimal.ZERO;

    /** 当前余额 = init + receipts − payments + adjustments（冗余，Service 维护）。 */
    @Column(name = "balance_current", precision = 18, scale = 4)
    private BigDecimal balanceCurrent = BigDecimal.ZERO;

    /** 账户币种口径的可选警戒线；仅告警，不构成透支授权。 */
    @Column(name = "balance_floor", precision = 18, scale = 4)
    private BigDecimal balanceFloor;

    /** 老库父节点 ID（M_Acc.ParentID→SystemItem，保留 legacy 不 FK）。 */
    @Column(name = "parent_legacy_id")
    private Integer parentLegacyId;

    /** 老库字典叶节点 ID（M_Acc.StyleID→M_Style.ID，账户类叶节点）。 */
    @Column(name = "style_legacy_id")
    private Integer styleLegacyId;

    /** 会计科目 UUID 真源；styleLegacyId 仅为老库兼容影子。 */
    @Column(name = "style_id")
    private UUID styleId;

    /** 状态（使用/禁用）。 */
    @Column(name = "status", nullable = false)
    private String status = "使用";

    /** 是否单据迁移/运行时自动补录（事后人工补全）。 */
    @Column(name = "auto_created", nullable = false)
    private boolean autoCreated = false;
}
