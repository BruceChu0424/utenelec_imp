package com.uten.imp.application.port;
import java.util.UUID;
/** Opaque, actor-bound finance generations; never raw financial evidence. */
public interface FinancialDocumentReviewSnapshotPort {
    boolean supports(String family);
    String factsSnapshot(String family,UUID id);
}
