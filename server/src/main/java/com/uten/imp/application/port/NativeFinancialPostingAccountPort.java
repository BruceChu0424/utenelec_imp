package com.uten.imp.application.port;

import java.time.LocalDate;
import java.util.UUID;

/** One owner of explicit native-account correspondence. Accounting property and actual original unit are separate dimensions. */
public interface NativeFinancialPostingAccountPort {
    record Party(String role,UUID id) { }
    record Request(String role,UUID existingStyleId,UUID originalCurrencyId,Party party,LocalDate postingDate) { }
    record Account(UUID styleId,String accountCode,UUID accountingCurrencyId,
            FinancialAuxiliaryValidationPort.Ref auxiliary,UUID originalCurrencyId,
            UUID configurationId,long configurationVersion,boolean originalGlobalRole,
            boolean complete,String basis) { }
    /** Trusted domain callers own their ordinary action authority. Resolving an account never posts money or mutates an existing GL entry. */
    Account resolve(Request request);
    /** Called in the original native approval, after its real ledger row was flushed. No GL is created. */
    void captureArAp(UUID ledgerId);
    /** A document-specific released credit inherits the exact original target debt identity. No current-role lookup. */
    void captureStatementCredit(UUID ledgerId,UUID targetLedgerId);
    /** Original account evidence wins over current configuration. Null means a legacy debt has no frozen evidence. */
    Account frozenArAp(UUID ledgerId);
    /** After actual source allocations, before the native approved header. Returns its first real counter style. */
    UUID prepareCash(String kind,UUID documentId);
    /** After its original GL writer/reversal: attach evidence to the same entries, never post again. */
    void attachCash(String kind,UUID documentId);
    /** A reviewed original complete month cannot be replayed as native journal generation. */
    void requireNoImportedPeriod(LocalDate day);
    /** Ordinary supplier credit application moves book balance only when original account/auxiliary identities differ. */
    void supplierOffsetApplied(UUID allocationId);
    void supplierOffsetReversed(UUID allocationId,String reason);
    /** Freeze the original customer advance liability and each actual receivable for the existing offset projection. */
    void captureCustomerOffset(UUID allocationId);
    void bindArApEntry(UUID ledgerId,UUID voucherId,int entryLine,boolean ownerReversesJournal);
    /** True means the ordinary native original is retained and a real linked GL reversal was appended. */
    boolean reverseArApGl(UUID ledgerId);
    /** Period -> source styles -> account/ledger rows, matching registration and common settlement lock order. */
    void lockCashSources(String kind,UUID documentId);
    void lockDebtSources(java.util.List<UUID> ledgerIds);
    /** Include every controlled journal counterpart before locking any debt row; one globally sorted style set. */
    void lockDebtSources(java.util.List<UUID> ledgerIds,java.util.List<UUID> additionalStyleIds);
}
