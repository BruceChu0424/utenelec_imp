package com.uten.imp.features.finance.asset.application;

import jakarta.persistence.EntityManager;
import java.util.UUID;

/** One eligibility rule for policy activation, frozen snapshots and legacy asset entry points. */
final class FinanceAssetExpenseStyles {
    private FinanceAssetExpenseStyles() { }
    static void requireActive(EntityManager em,UUID style) {
        com.uten.imp.features.finance.FinanceAccountingExpenseStyles.requireAnyActive(em,style);
    }
}
