package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * One route for first supplier AP recognition. Native owners retain physical approval,
 * quantity/cost/return permissions and their original locks. These hooks never invent
 * an AP UUID to satisfy a receipt, funding or inventory constraint.
 */
public interface ProcurementPayableRecognitionPort {
    record Source(String type,UUID id) { }
    record Candidate(Source source,String billNo,LocalDate commercialDate,LocalDate dueDate,
            UUID supplierId,UUID currencyId,BigDecimal exchangeRate,BigDecimal amountOriginal,
            BigDecimal amountLocal,UUID settlementMethodId,Short settlementStyleLegacy) { }
    /** Must run before inventory locks; snapshots the server-approval cutover under its shared policy lock. */
    boolean beginApproval(Source source);
    /** Frozen chargeable consideration only. True means the owner must not also call legacy postArAp. */
    boolean defer(Candidate candidate);
    /** The source is reversible only after its real formal AP/settlements have been undone. */
    boolean requireReversible(Source source);
    /** After the real physical reversal succeeded, symmetrically reverses only its own pending journal. */
    void sourceReversed(Source source);
    /** Read-only exact candidate identity for IQC funding. No dummy ledger or name matching. */
    UUID pendingSource(String receiptType,UUID receiptId);
}
