package com.uten.imp.common.validation;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class ExactDocumentSelectionTest {
    private final UUID first = UUID.randomUUID();
    private final UUID second = UUID.randomUUID();

    @Test void acceptsOnlyCompleteExplicitSelectionsRegardlessOfOrder() {
        assertDoesNotThrow(() -> ExactDocumentSelection.requireComplete(List.of(second, first), List.of(first, second)));
        assertDoesNotThrow(() -> ExactDocumentSelection.requireComplete(null, List.of(first, second)));
        assertThrows(ApiException.class, () -> ExactDocumentSelection.requireComplete(List.of(first), List.of(first, second)));
        assertThrows(ApiException.class, () -> ExactDocumentSelection.requireComplete(List.of(first, UUID.randomUUID()), List.of(first, second)));
    }

    @Test void rejectsEmptyDuplicateAndNullSelections() {
        assertThrows(ApiException.class, () -> ExactDocumentSelection.requireComplete(List.of(), List.of(first)));
        assertThrows(ApiException.class, () -> ExactDocumentSelection.requireComplete(List.of(first, first), List.of(first)));
        assertThrows(ApiException.class, () -> ExactDocumentSelection.requireComplete(Arrays.asList(first, null), List.of(first)));
    }
}
