package com.uten.imp.features.finance.receipt;

/** The same original account-posting proof backs customer and physical-batch cash reads. */
public final class ReceiptCashPostingProof {
    private ReceiptCashPostingProof() { }
    public static String aggregate(String receipt) {
        alias(receipt);
        return "SELECT count(*) AS count,min(account_id::text)::uuid AS account_id,"
                +"min(account_currency_id::text)::uuid AS currency_id,SUM(in_amount) AS incoming,"
                +"SUM(out_amount) AS outgoing,SUM(amount_local) AS cash_local FROM finance_reconciliations "
                +"WHERE source_doc_type='RECEIPT' AND entry_kind='POSTING' AND NOT is_deleted AND source_doc_id="+receipt+".id";
    }
    public static String verified(String receipt,String flow) {
        return proof(receipt,flow,true);
    }
    /** Approved settlement cash is distinct from the richer bank-reference reconciliation view. */
    public static String approvedPosting(String receipt,String flow){return proof(receipt,flow,false);}
    private static String proof(String receipt,String flow,boolean requireReference) {
        alias(receipt);alias(flow);
        return "("+receipt+".legacy_id IS NULL AND "+receipt+".settlement_authority_version>=2 AND "+receipt+".bank_booked_at IS NOT NULL "
                +(requireReference?"AND NULLIF(btrim("+receipt+".bank_reference),'') IS NOT NULL ":"")
                +"AND "+receipt+".account_amount>0 AND "+receipt+".account_amount_local>0 "
                +"AND "+flow+".count=1 AND "+flow+".account_id="+receipt+".account_id AND "+flow+".currency_id="+receipt+".account_currency_id "
                +"AND "+flow+".incoming="+receipt+".account_amount AND "+flow+".outgoing=0 AND "+flow+".cash_local="+receipt+".account_amount_local)";
    }
    private static void alias(String value){if(!value.matches("[a-z][a-z0-9_]*"))throw new IllegalArgumentException("SQL alias");}
}
