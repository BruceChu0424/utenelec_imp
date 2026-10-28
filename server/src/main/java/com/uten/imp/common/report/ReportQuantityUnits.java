package com.uten.imp.common.report;

/** Units come from persisted quantity snapshots, never a current master or an in-use flag. */
public final class ReportQuantityUnits {
    private ReportQuantityUnits() { }
    public static String transactionUnit(String itemAlias) {
        requireAlias(itemAlias);
        return "("+itemAlias+".unit_id)";
    }
    /** A recorded 1:1 conversion permits the stored transaction unit to label the same base quantity. */
    public static String oneToOneExecutionUnit(String snapshotAlias) {
        requireAlias(snapshotAlias);
        return "(CASE WHEN "+snapshotAlias+".product_unit_rate=1 THEN "+snapshotAlias+".product_unit_id END)";
    }
    private static void requireAlias(String alias) {
        if(alias==null||!alias.matches("[a-zA-Z_][a-zA-Z0-9_]*"))throw new IllegalArgumentException("Trusted quantity alias required");
    }
}
