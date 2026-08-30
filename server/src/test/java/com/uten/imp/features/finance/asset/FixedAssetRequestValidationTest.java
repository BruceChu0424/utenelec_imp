package com.uten.imp.features.finance.asset;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchResponses;
import com.uten.imp.features.finance.asset.application.FinanceAssetCategoryService;
import com.uten.imp.features.finance.asset.application.FinanceAssetPeriodService;
import com.uten.imp.features.finance.asset.application.FinanceAssetPostingService;
import com.uten.imp.features.finance.asset.application.FinanceAssetQueryService;
import com.uten.imp.features.finance.asset.application.FinanceAssetWorkflowService;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.math.BigDecimal;
import java.util.Set;
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

/** Contract coverage for the typed professional asset workbench API. */
class FixedAssetRequestValidationTest {

    private final Validator validator = Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void fixedAndDeferredDraftContractsRejectOutOfRangeValues() {
        assertFalse(validator.validate(new AssetWorkbenchRequests.FixedAssetDraft(
                "A".repeat(65), "", null, null, null, "x".repeat(301),
                "x".repeat(161), "x".repeat(101), "x".repeat(101), BigDecimal.ZERO,
                new BigDecimal("1.000001"), 0, "2026-13", null, null, null,
                null, null, null, null, null, "x".repeat(2001), -1L)).isEmpty());

        assertFalse(validator.validate(new AssetWorkbenchRequests.DeferredExpenseDraft(
                "A".repeat(65), "", null, null, null, "x".repeat(301),
                "x".repeat(101), BigDecimal.ZERO, 1201, "2026-00", null, null,
                null, null, null, null, null, "x".repeat(2001), -1L)).isEmpty());
    }

    @Test
    void representativeValidTypedDraftsHaveNoViolations() {
        assertTrue(validator.validate(new AssetWorkbenchRequests.FixedAssetDraft(
                null, "Machine", null, null, null, null, null, null, null,
                new BigDecimal("100.00"), new BigDecimal("0.050000"), 60, "2026-08",
                null, null, null, null, null, null, null, null, null, null)).isEmpty());
        assertTrue(validator.validate(new AssetWorkbenchRequests.DeferredExpenseDraft(
                null, "Insurance", null, null, null, null, null,
                new BigDecimal("100.00"), 12, "2026-08", null, null,
                null, null, null, null, null, null, null)).isEmpty());
    }

    @Test
    void validTypedJsonReachesWorkflowService() throws Exception {
        FinanceAssetWorkflowService workflow = mock(FinanceAssetWorkflowService.class);
        UUID id = UUID.randomUUID();
        when(workflow.createFixed(argThat(body ->
                "Machine".equals(body.name())
                        && new BigDecimal("1234.50").equals(body.originalValue())
                        && Integer.valueOf(60).equals(body.usefulMonths()))))
                .thenReturn(new AssetWorkbenchResponses.WorkflowResult(id, "DRAFT", null, 0L, Set.of("EDIT")));

        mvc(workflow).perform(post("/api/finance/fixed-assets")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {
                                  "name":"Machine",
                                  "originalValue":1234.50,
                                  "salvageRate":0.05,
                                  "usefulMonths":60,
                                  "startPeriod":"2026-08"
                                }
                                """))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(id.toString()))
                .andExpect(jsonPath("$.status").value("DRAFT"));

        verify(workflow).createFixed(argThat(body -> "Machine".equals(body.name())));
    }

    @Test
    void controllerRejectsInvalidTypedBodiesBeforeWorkflow() throws Exception {
        FinanceAssetWorkflowService workflow = mock(FinanceAssetWorkflowService.class);
        MockMvc mvc = mvc(workflow);

        mvc.perform(post("/api/finance/fixed-assets")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"A","originalValue":0,
                                 "usefulMonths":0,"startPeriod":"2026-13"}
                                """))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));
        mvc.perform(put("/api/finance/fixed-assets/{id}", UUID.randomUUID())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"A\",\"originalValue\":1,\"usefulMonths\":12,\"startPeriod\":\"bad\"}"))
                .andExpect(status().isUnprocessableEntity());
        mvc.perform(put("/api/finance/fixed-assets/{id}", UUID.randomUUID())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"A","originalValue":1,
                                 "usefulMonths":12,"startPeriod":"2026-08"}
                                """))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.message").value(
                        org.hamcrest.Matchers.containsString("expectedVersion")));
        mvc.perform(post("/api/finance/deferred-expenses")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"D","totalAmount":-1,
                                 "usefulMonths":12,"startPeriod":"2026-08"}
                                """))
                .andExpect(status().isUnprocessableEntity());
        mvc.perform(post("/api/finance/fixed-assets")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"A","originalValue":"not-a-number",
                                 "usefulMonths":12,"startPeriod":"2026-08"}
                                """))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value(ErrorCode.MALFORMED_REQUEST.name()));

        verifyNoInteractions(workflow);
    }

    private static MockMvc mvc(FinanceAssetWorkflowService workflow) {
        return MockMvcBuilders.standaloneSetup(new FixedAssetController(
                        mock(FinanceAssetQueryService.class), workflow,
                        mock(FinanceAssetCategoryService.class), mock(FinanceAssetPostingService.class),
                        mock(FinanceAssetPeriodService.class), mock(FixedAssetService.class),
                        mock(AuditDetailViewRecorder.class)))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();
    }
}
