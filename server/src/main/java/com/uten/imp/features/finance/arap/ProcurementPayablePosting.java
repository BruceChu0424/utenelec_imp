package com.uten.imp.features.finance.arap;

import com.uten.imp.application.port.ProcurementPayableRecognitionPort;

/** One native posting adapter; its return value is the true formal-AP flag, never a candidate flag. */
public final class ProcurementPayablePosting {
    private ProcurementPayablePosting() { }
    public static boolean post(ProcurementPayableRecognitionPort first,ArApLedgerService ledgers,ArApLedgerService.ArApPostingRequest req){
        if(first!=null&&first.defer(new ProcurementPayableRecognitionPort.Candidate(
            new ProcurementPayableRecognitionPort.Source(req.sourceDocType(),req.sourceDocId()),req.sourceDocNo(),req.billDate(),req.dueDate(),
            req.supplierId(),req.currencyId(),req.exchangeRate(),req.amountOriginal(),req.amountOriginalLocal(),req.settlementMethodId(),req.settlementStyleLegacy())))return false;
        if(req.amountOriginal().signum()!=0||req.amountOriginalLocal().signum()!=0){ledgers.postArAp(req);return true;}return false;
    }
}
