package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Account + source auxiliary UUID + currency is the accounting grain; names never resolve identity. */
public interface FinancialAuxiliaryValidationPort {
    record Selection(String accountCode,UUID auxiliaryId,UUID currencyId) { }
    record Ref(UUID auxiliaryId,String role,UUID partyId,String sourceSystem,String sourceCode,String sourceName) { }
    /** Preview may expose an unmapped item as a located problem; it never creates a business party. */
    Ref inspect(Selection selection);
    /** Historical reads retain the typed identity of an inactive auxiliary; never authorizes a new posting. */
    default Ref inspectHistorical(Selection selection){return inspect(selection);}
    /** Every posted reference is locked and mapped; the result is position-aligned and may contain null for non-auxiliary accounts. */
    List<Ref> validateForPosting(List<Selection> selections);
    /** Exact source-book/role/code lookup. A caption is not a matching key. */
    Ref resolveImported(String accountCode,String sourceSystem,String role,String sourceCode,UUID currencyId);
    /** Exact native relationship only; multiple external aliases require an explicit account binding. */
    Ref resolveNative(String accountCode,String role,UUID partyId,UUID currencyId);
}
