package com.uten.imp.features.admin;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Validation;
import org.junit.jupiter.api.Test;

import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertTrue;

class DataScopeRequestValidationTest {

    @Test
    void expectedOwnerSetHasSameCentralBoundaryAsDesiredSet() {
        try (var factory = Validation.buildDefaultValidatorFactory()) {
            var request = new AdminUserController.DataScopesBody(
                    List.of(),
                    Collections.nCopies(
                            RequestLimits.ADMIN_SCOPE_OWNERS + 1,
                            UUID.randomUUID()));

            assertTrue(factory.getValidator().validate(request).stream()
                    .anyMatch(violation -> violation.getPropertyPath().toString()
                            .equals("expectedOwnerEmployeeIds")));
        }
    }
}
