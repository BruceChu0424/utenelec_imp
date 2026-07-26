package com.uten.imp.features.subcontract.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 委外出入状况表行（综合 O · design doc 22 §6.3）：按 委外商×货品 汇总
 * 发料(15)/材料退(16)/收回成品(17)/成品退(18)/损耗(19)。
 *
 * <p>signed_qty 已乘 direction：发料/成品退/损耗 显示为负（出库方向），
 * 材料退/收回成品显示为正（入库方向）。前端展示按需取绝对值或保留符号。
 */
@Getter
@AllArgsConstructor
public class SubcontractInOutRow {
    private UUID supplierId;
    private UUID goodsId;
    /** 发料（type=15, dir=-1，显示负值）。 */
    private BigDecimal issueQty;
    /** 材料退（type=16, dir=+1，显示正值）。 */
    private BigDecimal mReturnQty;
    /** 收回成品（type=17, dir=+1，显示正值）。 */
    private BigDecimal receiptQty;
    /** 成品退（type=18, dir=-1，显示负值）。 */
    private BigDecimal returnQty;
    /** 损耗（type=19, dir=-1，显示负值）。 */
    private BigDecimal wasteQty;
}
