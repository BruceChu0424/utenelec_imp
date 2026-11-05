package com.uten.imp.features.finance;

/** Frozen native advance replay guard shared by cash reports and AP-only monthly statements. */
public final class SupplierAdvanceReplaySql {
    private SupplierAdvanceReplaySql() { }
    public static String unknown(String payment) {
        return "("+nativeHeader(payment)+" AND "+payment+".status IN(1,-1) AND (("
                +payment+".amount_authority_version=2 AND "+noLines(payment)+" AND NOT fn_finance_supplier_advance_replayable("+payment+".id)) OR ("
                +payment+".amount_authority_version IN(0,1) AND NOT COALESCE(("+legacyPostingProof(payment)+" OR "+legacyFullyAllocatedProof(payment)+"),false)) "
                +"OR "+payment+".amount_authority_version IS NULL OR "+payment+".amount_authority_version NOT IN(0,1,2)))";
    }
    public static String unreplayableReversal(String payment) {
        return "("+payment+".status=-1 AND "+unknown(payment)+")";
    }
    public static String legacyReversalProof(String payment) {
        return "("+payment+".status=-1 AND "+legacyPostingProof(payment)+")";
    }
    public static String legacyPostingProof(String payment) {
        return "("+payment+".amount_authority_version IN(0,1) AND "+knownLines(payment)
                +" AND (SELECT count(*) FROM ar_ap_ledger legacy_count WHERE legacy_count.source_doc_type='DIRECT_PAYMENT' AND legacy_count.source_doc_id="+payment+".id)=1 "
                +"AND EXISTS(SELECT 1 FROM ar_ap_ledger legacy WHERE "+legacyIdentity(payment)
                +" AND legacy.legacy_id IS NULL AND legacy.legacy_import_run_id IS NULL"
                +" AND legacy.direction='AP' AND legacy.open_item_kind='PREPAYMENT' AND legacy.supplier_id="+payment+".supplier_id AND legacy.currency_id="+payment+".currency_id"
                +" AND legacy.amount_original=-("+payment+".amount_original-"+lineSum(payment,"amount_original")+") AND legacy.amount_original_local=-("+payment+".amount_local-"+lineSum(payment,"amount_local")+")"
                +" AND legacy.amount_original<0 AND legacy.amount_original_local<0 AND (("+payment+".status=1 AND legacy.status=1 AND NOT legacy.is_deleted AND legacy.deleted_at IS NULL AND "+payment+".reversed_at IS NULL) "
                +"OR ("+payment+".status=-1 AND legacy.status=-1 AND legacy.is_deleted AND legacy.deleted_at IS NOT NULL AND ("+payment+".reversed_at IS NULL OR "+payment+".reversed_at=legacy.deleted_at)))))";
    }
    public static String legacyReversalDate(String payment) {
        return "CASE WHEN "+legacyReversalProof(payment)+" THEN (SELECT min(legacy.deleted_at) FROM ar_ap_ledger legacy WHERE "+legacyIdentity(payment)+") END";
    }
    public static String reversalDate(String payment) {
        return "COALESCE("+legacyReversalDate(payment)+","+payment+".reversed_at)";
    }
    public static String cashRepresentedLedger(String ledger) {
        return "("+ledger+".source_doc_type='DIRECT_PAYMENT' AND EXISTS(SELECT 1 FROM finance_payments represented_cash WHERE represented_cash.id="+ledger+".source_doc_id AND "
                +nativeHeader("represented_cash")+" AND "+noLines("represented_cash")+" AND "+legacyPostingProof("represented_cash")+"))";
    }
    private static String legacyFullyAllocatedProof(String payment) {
        return "(NOT "+noLines(payment)+" AND "+knownLines(payment)+" AND "+payment+".amount_original>0 AND "+payment+".amount_local>0 AND "
                +payment+".amount_original="+lineSum(payment,"amount_original")+" AND "+payment+".amount_local="+lineSum(payment,"amount_local")
                +" AND NOT EXISTS(SELECT 1 FROM ar_ap_ledger legacy_unallocated WHERE legacy_unallocated.source_doc_type='DIRECT_PAYMENT' AND legacy_unallocated.source_doc_id="+payment+".id)"
                +" AND (("+payment+".status=1 AND "+payment+".reversed_at IS NULL) OR ("+payment+".status=-1 AND "+payment+".reversed_at IS NOT NULL)))";
    }
    private static String knownLines(String payment) {
        return "NOT EXISTS(SELECT 1 FROM finance_payment_lines legacy_line WHERE legacy_line.payment_id="+payment+".id AND NOT legacy_line.is_deleted AND ("
                +"legacy_line.amount_original IS NULL OR legacy_line.amount_local IS NULL OR ("+LegacyOpeningBalanceSql.paymentBookLocal("legacy_line")+") IS NULL "
                +"OR legacy_line.supplier_id IS DISTINCT FROM "+payment+".supplier_id OR NOT EXISTS(SELECT 1 FROM ar_ap_ledger legacy_target WHERE legacy_target.id=legacy_line.applied_ledger_id "
                +"AND legacy_target.direction='AP' AND (legacy_target.open_item_kind='PAYABLE' OR (public.fn_is_verified_legacy_opening_target(legacy_target.id,'AP') "
                +"AND "+payment+".bill_date>((legacy_target.legacy_source_resolution->>'snapshotAsOfUtc')::timestamptz AT TIME ZONE 'Asia/Shanghai')::date)) "
                +"AND legacy_target.supplier_id="+payment+".supplier_id AND legacy_target.currency_id="+payment+".currency_id "
                +"AND ((legacy_target.status=1 AND NOT legacy_target.is_deleted) OR (legacy_target.status=-1 AND legacy_target.is_deleted AND legacy_target.deleted_at IS NOT NULL)))))";
    }
    private static String lineSum(String payment,String field) {
        return "(SELECT COALESCE(sum(legacy_line."+field+"),0) FROM finance_payment_lines legacy_line WHERE legacy_line.payment_id="+payment+".id AND NOT legacy_line.is_deleted)";
    }
    private static String nativeHeader(String payment) {
        return payment+".legacy_id IS NULL AND "+payment+".legacy_import_run_id IS NULL AND NOT "+payment+".is_deleted";
    }
    private static String legacyIdentity(String payment) {
        return "legacy.source_doc_type='DIRECT_PAYMENT' AND legacy.source_doc_id="+payment+".id";
    }
    private static String noLines(String payment) {
        return "NOT EXISTS(SELECT 1 FROM finance_payment_lines advance_line WHERE advance_line.payment_id="+payment+".id AND NOT advance_line.is_deleted)";
    }
}
