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
    private boolean legacyImported;
    /** Command response proof only: the server-bound original of an unapproval successor. */
    private java.util.UUID unapprovalOriginalId;

    /** DTOs retain their original legacy ID even when source status was draft or reversed. */
    @com.fasterxml.jackson.annotation.JsonProperty("legacyImported")
    public boolean isLegacyImported() {
        if (legacyImported) return true;
        try { return getClass().getMethod("getLegacyId").invoke(this) != null; }
        catch (NoSuchMethodException missing) { return false; }
        catch (ReflectiveOperationException failure) { throw new IllegalStateException("Invalid document origin metadata", failure); }
    }

    @com.fasterxml.jackson.annotation.JsonProperty("historyReadOnly")
    public boolean isHistoryReadOnly() { return historyReadOnly || isLegacyImported(); }

    public void setLegacyImported(boolean imported) {
        legacyImported = imported;
        if (imported) { historyReadOnly = true; disableHistoryActions(); }
    }

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
        legacyImported = source.isLegacyImported();
        historyReadOnly = source.isHistoryReadOnly();
        if (historyReadOnly || deleted) disableHistoryActions();
    }

    /** Domain DTOs clear their existing action flags without replacing business status. */
    public void disableHistoryActions() { }
}
