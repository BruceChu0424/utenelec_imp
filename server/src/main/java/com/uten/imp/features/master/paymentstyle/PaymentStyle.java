package com.uten.imp.features.master.paymentstyle;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 收付款类别混合树（基础资料-收付款类别）。源 M_Style（124 节点）。
 *
 * <p>邻接表 {@code parent} + 真实深度 {@code level} + 物化路径 {@code path}
 * （由 DB 触发器 trg_payment_style_path 维护，对齐 material_categories 范式）。
 * 老库重复 StyleNumber 原号保留；新建 code 由服务端生成并经 V279 全局终身预约。
 * 在线定位、父子关系和业务引用只使用 UUID id，legacyId 仅用于迁移溯源。
 *
 * <p>category 由老库 StyleClassid 映射：
 * 1→ACCOUNT（账户类叶节点，挂 accounts） / 2→LIABILITY（应付科目） / 3→EQUITY（资本）
 * / 4→EXPENSE（费用项目，被 finance_expense_items 引用） / 5→INCOME（收入项目）
 * / METHOD（结算方式，备用——老库 RecStyle/PaidStyle 独立字典未 dump）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "payment_styles")
public class PaymentStyle extends SoftDeletableEntity {

    /** 老库 M_Style.ID，迁移溯源 + 重跑幂等；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    /** 显示编号；历史 StyleNumber 可重复，新号全局终身预约，不能作为关系键。 */
    @Column(nullable = false)
    private String code;

    /** 类别名称（源 M_Style.StyleName：现金/银行存款/办公费用/销售收入…）。 */
    @Column(nullable = false)
    private String name;

    /** 大类：ACCOUNT/LIABILITY/EQUITY/EXPENSE/INCOME/METHOD。 */
    @Column(nullable = false)
    private String category;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "parent_id")
    private PaymentStyle parent;

    /** 真实深度（根=0）；改父级后由 Service 重算整棵子树。 */
    @Column(nullable = false)
    private Integer level = 0;

    @Column(name = "sort_order")
    private Integer sortOrder = 0;

    /** 物化路径（触发器维护）：path = 父path || code || '/'，根节点 '/code/'。 */
    @Column(nullable = false)
    private String path = "/";

    /** 是否部门级核算（源 M_Style.DeptStatus；一般费用/其它收入按部门分摊时用）。 */
    @Column(name = "is_departmental", nullable = false)
    private boolean departmental = false;

    /** 收方向标志（源 M_Style.OrientStatus1）。 */
    @Column(name = "is_receipt", nullable = false)
    private boolean receipt = false;

    /** 付方向标志（源 M_Style.OrientStatus2）。 */
    @Column(name = "is_payment", nullable = false)
    private boolean payment = false;

    /** 账户类叶节点关联的账户 legacy id（源 M_Style.ItemID→M_Acc.ID，仅 ACCOUNT 类有值）。 */
    @Column(name = "linked_account_legacy_id")
    private Integer linkedAccountLegacyId;

    /** 关联账户 UUID 真源；linkedAccountLegacyId 仅为老库兼容影子。 */
    @Column(name = "linked_account_id")
    private UUID linkedAccountId;

    /** 期初金额（源 M_Style.InitTotal，仅账户类叶节点有意义）。 */
    @Column(name = "init_balance", precision = 18, scale = 4)
    private BigDecimal initBalance;

    /** 状态（使用/禁用）。 */
    @Column(nullable = false)
    private String status = "使用";

    /** 是否自动补录（单据迁移/运行时）。 */
    @Column(name = "auto_created", nullable = false)
    private boolean autoCreated = false;
}
