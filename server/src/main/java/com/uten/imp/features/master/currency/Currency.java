package com.uten.imp.features.master.currency;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;

/**
 * 币种主档（基础资料-币种资料）。
 *
 * <p>逐字段对应 currencies 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_Currency 迁移：legacy_id=B_Currency.ID（溯源+重跑幂等），code=Number、name=CurName、
 * exchangeRate=ExRate（参考汇率）、status=Status。B_Currency 扁平表（ParentID 全 0），无分类树。
 *
 * <p>采购订货/收货/退货主表 currency_id 引用本表（有美金/港币进出口采购）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "currencies")
public class Currency extends SoftDeletableEntity {

    /** 老库 B_Currency.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    private String code;        // Number 编号（001/002/003）

    private String name;        // CurName 币种名称（人民币/美金/港币）

    /** 参考汇率（源 ExRate；实际汇率以采购单据 exchange_rate 为准）。 */
    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;

    /**
     * UUID-bound functional-currency authority. It is set only by a reviewed
     * forward migration; ordinary master-data writes cannot change it.
     */
    @Column(name = "is_base_currency", nullable = false, insertable = false, updatable = false)
    private boolean baseCurrency;

    private String status;      // Status（使用/禁用）

    /** 单据迁移/运行时自动补录标记。 */
    @Column(name = "auto_created", nullable = false)
    private boolean autoCreated = false;
}
