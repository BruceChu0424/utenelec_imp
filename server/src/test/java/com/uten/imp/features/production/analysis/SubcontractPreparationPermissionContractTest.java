package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

class SubcontractPreparationPermissionContractTest {

    @Test
    void listAndStartUseExactPreparationAuthorities() throws Exception {
        Method tasks = SubcontractPreparationController.class.getMethod(
                "tasks", int.class, int.class, String.class, String.class,
                UUID.class, UUID.class, UUID.class);
        Method start = SubcontractPreparationController.class.getMethod(
                "start", UUID.class,
                SubcontractPreparationContracts.StartRequest.class);

        assertEquals(
                "hasAuthority('subcontract_preparation:view')",
                tasks.getAnnotation(PreAuthorize.class).value());
        assertEquals(
                "hasAuthority('subcontract_preparation:view')"
                        + " and hasAuthority('subcontract_preparation:start')",
                start.getAnnotation(PreAuthorize.class).value());
    }
}
