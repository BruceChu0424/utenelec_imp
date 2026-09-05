package com.uten.imp.features.production.execution;

import java.util.UUID;

/** A related document already filtered by its own module data-scope policy. */
public record ProductionExecutionWorkbenchRelatedDocument(
        String route,
        String documentType,
        UUID documentId,
        String documentNo,
        String status,
        boolean canOpen) {
}
