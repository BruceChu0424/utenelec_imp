package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.ResponseEntity;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;

class GlobalExceptionHandlerTest {

    @Test
    void dataIntegrityConflictDoesNotExposeDatabaseDetails() {
        GlobalExceptionHandler handler = new GlobalExceptionHandler();
        DataIntegrityViolationException failure = new DataIntegrityViolationException(
                "could not execute statement",
                new RuntimeException("secret SQL and constraint details"));

        ResponseEntity<ApiError> response = handler.handleDataIntegrity(failure);

        assertEquals(409, response.getStatusCode().value());
        assertNotNull(response.getBody());
        assertEquals("CONFLICT", response.getBody().getCode());
        assertFalse(response.getBody().getMessage().contains("secret SQL"));
    }
}
