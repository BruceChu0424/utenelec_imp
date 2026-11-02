package com.uten.imp.security;

import java.util.List;
import java.util.Locale;
import java.util.Set;

/** Common capability policy; source ownership and object scope remain domain-owned. */
public final class PriceAnalysisAccessPolicy {
    private PriceAnalysisAccessPolicy() {}
    public static final List<String> KINDS = List.of("PURCHASE","SUBCONTRACT","SALES");
    public static final String PURCHASE_READ = "T(com.uten.imp.security.PriceAnalysisAccessPolicy).canAnalyze(principal.permissions, principal.superAdmin, 'PURCHASE')";
    public static final String PURCHASE_WRITE = "hasAuthority('goods:edit') and " + PURCHASE_READ;
    public static boolean canAnalyze(Set<String> grants, boolean superAdmin, String kind) {
        if (kind==null || !KINDS.contains(kind)) return false;
        if (superAdmin) return true;
        if (!grants.containsAll(Set.of("goods:view","goods:price_analysis:view"))) return false;
        String prefix=kind.toLowerCase(Locale.ROOT);
        boolean source=grants.contains(prefix+"_order:view")
                || !kind.equals("SALES") && grants.contains("finance_order_approval:view");
        return source && CommercialPriceVisibility.canViewCommercial(grants,prefix+"_order:price:view");
    }
    public static boolean canReadHistory(Set<String> grants, boolean superAdmin, String kind) {
        return canAnalyze(grants,superAdmin,kind) || "SALES".equals(kind)
                && grants.containsAll(Set.of("goods:view","goods:price_analysis:view","sales_quote_finance:view"));
    }
    public static boolean canOpen(Set<String> grants, boolean superAdmin) {
        return KINDS.stream().anyMatch(kind->canReadHistory(grants,superAdmin,kind));
    }
    public static List<String> analyzableKinds(Set<String> grants, boolean superAdmin) {
        return KINDS.stream().filter(kind->canAnalyze(grants,superAdmin,kind)).toList();
    }
}
