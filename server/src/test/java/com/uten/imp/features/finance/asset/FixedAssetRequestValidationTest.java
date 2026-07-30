package com.uten.imp.features.finance.asset;

import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.finance.asset.FixedAssetRequests.CreateAssetRequest;
import com.uten.imp.features.finance.asset.FixedAssetRequests.CreateDeferredRequest;
import com.uten.imp.features.finance.asset.FixedAssetRequests.UpdateAssetRequest;
import com.uten.imp.features.finance.asset.FixedAssetRequests.UpdateDeferredRequest;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.math.BigDecimal;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class FixedAssetRequestValidationTest {

    private final Validator validator =
            Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void allFourRequestContractsRejectOutOfRangeValues() {
        assertFalse(validator.validate(new CreateAssetRequest(
                "A".repeat(65),
                "asset",
                null,
                null,
                BigDecimal.ZERO,
                new BigDecimal("1.0001"),
                0,
                "2026-13",
                "unknown",
                null)).isEmpty());

        assertFalse(validator.validate(new UpdateAssetRequest(
                null,
                "",
                null,
                null,
                new BigDecimal("-1"),
                new BigDecimal("-0.1"),
                1201,
                "2026-00",
                "unknown",
                "x".repeat(2001))).isEmpty());

        assertFalse(validator.validate(new CreateDeferredRequest(
                "",
                "deferred",
                null,
                BigDecimal.ZERO,
                0,
                "bad",
                "unknown",
                null)).isEmpty());

        assertFalse(validator.validate(new UpdateDeferredRequest(
                null,
                "",
                null,
                new BigDecimal("-1"),
                1201,
                "2026-99",
                "unknown",
                "x".repeat(2001))).isEmpty());
    }

    @Test
    void validExistingJsonContractReachesServiceAsExpected() throws Exception {
        FixedAssetService service = mock(FixedAssetService.class);
        UUID id = UUID.randomUUID();
        when(service.createAsset(argThat(body ->
                "FA-001".equals(body.get("code"))
                        && new BigDecimal("1234.5000").equals(body.get("originalValue"))
                        && Integer.valueOf(60).equals(body.get("usefulMonths")))))
                .thenReturn(id);
        MockMvc mvc = mvc(service);

        mvc.perform(post("/api/finance/fixed-assets")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {
                                  "code":"FA-001",
                                  "name":"Machine",
                                  "originalValue":1234.5000,
                                  "salvageRate":0.05,
                                  "usefulMonths":60,
                                  "startPeriod":"2026-07",
                                  "status":"在用"
                                }
                                """))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(id.toString()));

        verify(service).createAsset(argThat(body -> "FA-001".equals(body.get("code"))));
    }

    @Test
    void controllerRejectsInvalidCreateAndUpdateBodiesBeforeService() throws Exception {
        FixedAssetService service = mock(FixedAssetService.class);
        MockMvc mvc = mvc(service);

        mvc.perform(post("/api/finance/fixed-assets")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"code":"FA","name":"A","originalValue":0,
                                 "usefulMonths":0,"startPeriod":"2026-13"}
                                """))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));
        mvc.perform(put("/api/finance/fixed-assets/{id}", UUID.randomUUID())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"salvageRate\":1.1}"))
                .andExpect(status().isUnprocessableEntity());
        mvc.perform(post("/api/finance/deferred-expenses")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"code":"DA","name":"D","totalAmount":-1,
                                 "usefulMonths":12,"startPeriod":"2026-07"}
                                """))
                .andExpect(status().isUnprocessableEntity());
        mvc.perform(put("/api/finance/deferred-expenses/{id}", UUID.randomUUID())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"startPeriod\":\"2026-99\"}"))
                .andExpect(status().isUnprocessableEntity());
        mvc.perform(post("/api/finance/fixed-assets")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"code":"FA","name":"A","originalValue":"not-a-number",
                                 "usefulMonths":12,"startPeriod":"2026-07"}
                                """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value(ErrorCode.MALFORMED_REQUEST.name()));

        verifyNoInteractions(service);
    }

    @Test
    void representativeValidRequestsHaveNoViolations() {
        assertTrue(validator.validate(new CreateAssetRequest(
                "FA-001",
                "Machine",
                null,
                null,
                new BigDecimal("100.0000"),
                new BigDecimal("0.0500"),
                60,
                "2026-07",
                "在用",
                null)).isEmpty());
        assertTrue(validator.validate(new CreateDeferredRequest(
                "DA-001",
                "Insurance",
                null,
                new BigDecimal("100.0000"),
                12,
                "2026-07",
                "摊销中",
                null)).isEmpty());
    }

    private static MockMvc mvc(FixedAssetService service) {
        return MockMvcBuilders.standaloneSetup(new FixedAssetController(service))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();
    }
}
