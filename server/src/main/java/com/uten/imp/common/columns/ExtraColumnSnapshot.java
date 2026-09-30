package com.uten.imp.common.columns;

import java.util.UUID;

/** Immutable document terms. Changing the catalog never changes an existing document. */
public record ExtraColumnSnapshot(UUID columnId, String name, String type, String operation, String value) {
    public boolean financial() { return !"NONE".equals(operation) || "AMOUNT".equals(type); }
    public ExtraColumnSnapshot masked() {
        return financial() ? new ExtraColumnSnapshot(columnId, name, type, operation, null) : this;
    }
}
