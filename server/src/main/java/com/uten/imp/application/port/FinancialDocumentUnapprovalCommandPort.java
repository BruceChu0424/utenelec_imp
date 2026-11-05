package com.uten.imp.application.port;
import java.util.UUID;
/** The generic reversal flow delegates only finance HTTP commands to its owner. */
public interface FinancialDocumentUnapprovalCommandPort {
    record Command(UUID requestId,String idempotencyKey,String reason,String expectedSnapshot) { }
    boolean supports(String family);
    Object execute(String family,UUID originalId,Command command);
}
