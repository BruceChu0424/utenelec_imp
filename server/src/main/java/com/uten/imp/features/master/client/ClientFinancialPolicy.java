package com.uten.imp.features.master.client;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.CurrentAuthorityGuard;
import java.util.Set;

/** One field boundary for ordinary writes, inline edits and operation-history replay. */
public final class ClientFinancialPolicy {
    public static final String AUTHORITY = "client:finance";
    public static final Set<String> FINANCIAL_COLUMNS = Set.of(
            "bank", "bank_account", "tax_id", "credit", "init_total", "tday",
            "default_settlement_method_id", "default_currency_id", "credit_floor", "price_style", "init_total2", "exchange_rate");
    public static final Set<String> FINANCIAL_FIELDS = Set.of(
            "bank", "bankAccount", "taxId", "credit", "initTotal", "tday",
            "defaultSettlementMethodId", "defaultCurrencyId", "creditFloor");
    private ClientFinancialPolicy() {}
    public static boolean hasAuthority() {
        try { CurrentAuthorityGuard.requireAll(AUTHORITY); return true; }
        catch (ApiException denied) { return false; }
    }
    public static void requireAuthority() {
        if (!hasAuthority()) throw new ApiException(ErrorCode.FORBIDDEN, "客户财务资料仅限具有财务维护权限的人员修改");
    }
}
