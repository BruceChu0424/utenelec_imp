package com.uten.imp.application.port;

import com.uten.imp.common.finance.PartyOpenBalances;

import java.util.Collection;
import java.util.UUID;

/**
 * 往来单位未结余额的唯一读口(ADR-128)。实现在 finance 模块({@code PartyOpenBalanceQuery}),
 * 销售订单财务确认、出货财审、订货审批等审核页都经这里取余额, 不再各写一份 ar_ap_ledger 汇总 SQL。
 *
 * <p>一次传入一页用到的全部往来单位 id, 一条 SQL 取完(不 N+1); 结果再按单据币种
 * {@link PartyOpenBalances#forDocument} 派生显示视图。只读, 随调用方事务。
 */
public interface PartyOpenBalancePort {

    /** 客户应收侧: 正式应收(含退货红字)、客户预收、旧系统迁入余额。 */
    PartyOpenBalances clients(Collection<UUID> clientIds);

    /** 供应商应付侧: 正式应付、贷项、索赔贷项、预付、旧系统迁入余额。 */
    PartyOpenBalances suppliers(Collection<UUID> supplierIds);
}
