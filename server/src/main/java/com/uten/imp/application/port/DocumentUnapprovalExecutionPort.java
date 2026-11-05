package com.uten.imp.application.port;
import java.util.UUID;
/** Trusted atomic executor used behind reviewed HTTP commands. The generic
 * document owner retains its original family/lineage/reversal authority. */
public interface DocumentUnapprovalExecutionPort {
    Object unapproveTrusted(String family,UUID originalId,String key,String reason,String expectedSnapshot,UUID requestId);
    String currentFactsSnapshot(String family,UUID originalId);
}
