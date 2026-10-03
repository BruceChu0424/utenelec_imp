package com.uten.imp.common.history;

import java.time.Instant;
import lombok.Getter;
import lombok.Setter;

/** Deletion is independent of the document's business status. Never infer missing legacy actors. */
@Getter
@Setter
public class DocumentHistoryMetadata {
    private boolean deleted;
    private Instant deletedAt;
    private String deletedByName;
    private String deletedReason;
    private boolean historyReadOnly;

    public void setHistoryReadOnly(boolean value) {
        historyReadOnly = value;
        if (value) disableHistoryActions();
    }

    public void setDeleted(boolean value) {
        deleted = value;
        if (value) {
            historyReadOnly = true;
            disableHistoryActions();
        }
    }

    public void copyHistoryFrom(DocumentHistoryMetadata source) {
        deleted = source.deleted;
        deletedAt = source.deletedAt;
        deletedByName = source.deletedByName;
        deletedReason = source.deletedReason;
        historyReadOnly = source.historyReadOnly;
        if (historyReadOnly || deleted) disableHistoryActions();
    }

    /** Domain DTOs clear their existing action flags without replacing business status. */
    public void disableHistoryActions() { }
}
