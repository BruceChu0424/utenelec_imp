package com.uten.imp.common.validation;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.org.employee.EmployeeVehiclePhoneService;
import com.uten.imp.features.org.employee.MyVehiclePhoneController;
import com.uten.imp.features.production.analysis.AnalysisLinkedSalesOrderService;
import com.uten.imp.features.production.analysis.GoodsOwningWarehouseWriteService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisController;
import com.uten.imp.features.production.analysis.MaterialAnalysisPlanWithdrawalService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisSupplyProgressService;
import com.uten.imp.features.production.analysis.MaterialStockReallocationService;
import com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService;
import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionController;
import com.uten.imp.features.warehouse.place.WarehousePlaceSuggestionService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.validation.beanvalidation.LocalValidatorFactoryBean;
import org.springframework.validation.beanvalidation.MethodValidationPostProcessor;
import org.springframework.validation.beanvalidation.MethodValidationInterceptor;
import org.springframework.validation.annotation.Validated;
import org.springframework.aop.framework.Advised;
import org.springframework.aop.support.AopUtils;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.method.HandlerMethod;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.endsWith;
import static org.hamcrest.Matchers.not;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Verify that moving @Valid into array elements keeps validation before service calls. */
class ContainerCascadeHttpValidationTest {
    private LocalValidatorFactoryBean validator;

    @BeforeEach
    void openValidator() {
        validator = new LocalValidatorFactoryBean();
        validator.afterPropertiesSet();
    }

    @AfterEach
    void closeValidator() {
        validator.close();
    }

    @Test
    void owningWarehouseArrayRejectsMissingGoodsBeforeCallingTheWriteService() throws Exception {
        var service = mock(GoodsOwningWarehouseWriteService.class);
        var mvc = http(analysisController(service));
        mvc.perform(put("/api/production/material-analyses/goods-owning-warehouses")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("[{\"owningWarehouseId\":\"" + UUID.randomUUID() + "\"}]"))
                .andExpect(status().isUnprocessableContent())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()))
                .andExpect(jsonPath("$.fieldErrors[0].field").value(endsWith("requests[0].goodsId")));
        verifyNoInteractions(service);
    }

    @Test
    void owningWarehouseArrayStillAllowsEmptyRequestsAndClearingAWarehouse() throws Exception {
        var service = mock(GoodsOwningWarehouseWriteService.class);
        when(service.applyOwningWarehouses(anyList())).thenReturn(Map.of("updated", 0, "skipped", 0));
        var mvc = http(analysisController(service));
        UUID goods = UUID.randomUUID();
        mvc.perform(put("/api/production/material-analyses/goods-owning-warehouses")
                        .contentType(MediaType.APPLICATION_JSON).content("[]"))
                .andExpect(status().isOk());
        mvc.perform(put("/api/production/material-analyses/goods-owning-warehouses")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("[{\"goodsId\":\"" + goods + "\",\"owningWarehouseId\":null}]"))
                .andExpect(status().isOk());
        verify(service).applyOwningWarehouses(List.of());
        verify(service).applyOwningWarehouses(List.of(
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(goods, null)));
    }

    @Test
    void selfServiceVehicleAndPhoneArraysUseTheConfiguredMethodValidationProxy() throws Exception {
        var controller = new MyVehiclePhoneController(mock(EmployeeVehiclePhoneService.class),
                mock(SecurityContextCurrentUser.class), mock(TxSessionVars.class));
        for (String method : List.of("replaceMyVehicles", "replaceMyPhones")) {
            var handler = new HandlerMethod(controller, controller.getClass().getMethod(method, List.class))
                    .createWithValidateFlags();
            assertThat(handler.shouldValidateArguments()).as("Class-level @Validated delegates "+method+" to AOP").isFalse();
        }
        Object proxy=validatedController(controller);
        assertThat(AopUtils.isAopProxy(proxy)).isTrue();
        assertThat(((Advised)proxy).getAdvisors()).anyMatch(advisor->advisor.getAdvice() instanceof MethodValidationInterceptor);
    }

    @Test
    void warehousePlaceSuggestionStillRejectsInvalidItemsAtTheHttpBoundary() throws Exception {
        var service = mock(WarehousePlaceSuggestionService.class);
        var mvc = http(new WarehousePlaceSuggestionController(service));
        String warehouse = UUID.randomUUID().toString();
        for (String items : List.of("[]", "null", "[null]", "[{}]")) {
            mvc.perform(post("/api/warehouse/place-suggestions")
                            .contentType(MediaType.APPLICATION_JSON)
                            .content("{\"warehouseId\":\"" + warehouse + "\",\"items\":" + items + "}"))
                    .andExpect(status().isUnprocessableContent())
                    .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));
        }
        verifyNoInteractions(service);
    }

    @Test
    void arrayValidationErrorsExposeTheIndexedFieldWithoutRejectedValues() throws Exception {
        String secret = "secret-input-value";
        http(new ProbeController()).perform(post("/test/container-cascades")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("[{\"value\":\"" + secret + "\"}]"))
                .andExpect(status().isUnprocessableContent())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()))
                .andExpect(jsonPath("$.fieldErrors[0].field").value("entries[0].value"))
                .andExpect(jsonPath("$.fieldErrors[0].rejectedValue").doesNotExist())
                .andExpect(content().string(not(containsString(secret))));
    }

    @Test
    void invalidServerReturnValuesRemainInternalErrors() throws Exception {
        http(new ProbeController()).perform(get("/test/container-cascades/return"))
                .andExpect(status().isInternalServerError())
                .andExpect(jsonPath("$.code").value(ErrorCode.INTERNAL.name()))
                .andExpect(jsonPath("$.fieldErrors").isEmpty());
    }

    private MockMvc http(Object controller) {
        return MockMvcBuilders.standaloneSetup(validatedController(controller)).setValidator(validator)
                .setControllerAdvice(new GlobalExceptionHandler()).build();
    }
    private Object validatedController(Object controller) {
        if(!controller.getClass().isAnnotationPresent(Validated.class))return controller;
        var processor=new MethodValidationPostProcessor();
        processor.setValidator(validator);
        processor.setProxyTargetClass(true);
        processor.afterPropertiesSet();
        return processor.postProcessAfterInitialization(controller,"validated-http-fixture");
    }

    private static MaterialAnalysisController analysisController(GoodsOwningWarehouseWriteService writes) {
        return new MaterialAnalysisController(mock(MaterialAnalysisService.class),
                mock(MaterialAnalysisCommandService.class), mock(MaterialStockReallocationService.class),
                mock(ProductionGoodsWorkshopPreferenceService.class),
                mock(MaterialAnalysisSupplyProgressService.class), mock(AnalysisLinkedSalesOrderService.class),
                mock(AuditDetailViewRecorder.class), writes, mock(MaterialAnalysisPlanWithdrawalService.class));
    }

    record ProbeEntry(@Size(max = 3) String value) {}

    @RestController
    static class ProbeController {
        @PostMapping("/test/container-cascades")
        public int save(@RequestBody List<@Valid ProbeEntry> entries) {
            return entries.size();
        }

        @NotNull
        @GetMapping("/test/container-cascades/return")
        public String invalidReturn() {
            return null;
        }
    }
}
