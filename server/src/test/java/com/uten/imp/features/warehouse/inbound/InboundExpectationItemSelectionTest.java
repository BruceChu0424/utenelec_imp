package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.InboundExpectationItem;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.InboundExpectationTask;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class InboundExpectationItemSelectionTest {
    @Test void getByIdsBindsPhysicalItemQueryAndKeepsLegacyDocumentEntry() throws Exception {
        var service = mock(ProcurementArrivalControlService.class);
        var mvc = mvc(service);
        UUID expectation = UUID.randomUUID();
        UUID item = UUID.randomUUID();
        mvc.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", expectation.toString()).param("itemIds", item.toString()))
                .andExpect(status().isOk());
        verify(service).expectationsByIds(List.of(expectation), List.of(item));
        mvc.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", expectation.toString())).andExpect(status().isOk());
        verify(service).expectationsByIds(List.of(expectation), null);
        mvc.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", expectation.toString()).param("itemIds", ""))
                .andExpect(status().isOk());
        verify(service).expectationsByIds(List.of(expectation), List.of());
    }

    @Test void malformedPhysicalItemIdUsesTheProductionErrorContractBeforeCallingService() throws Exception {
        var service = mock(ProcurementArrivalControlService.class);
        var mvc = mvc(service);
        mvc.perform(get("/api/warehouse/inbound/expectations/by-ids")
                .param("ids", UUID.randomUUID().toString()).param("itemIds", "invalid-row"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.status").value(400))
                .andExpect(jsonPath("$.code").value("MALFORMED_REQUEST"))
                .andExpect(jsonPath("$.message").value("查询条件 itemIds 的格式不对"))
                .andExpect(jsonPath("$.fieldErrors").value(org.hamcrest.Matchers.nullValue()));
        verifyNoInteractions(service);
    }

    @Test void selectionKeepsOriginalOrderLineEvenWhenGoodsRepeatOnTheSameOrder() {
        UUID goods = UUID.randomUUID();
        var first = item(goods, "5000");
        var selected = item(goods, "50");
        for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
            var visible = task(type, List.of(first, selected));
            var result = ProcurementArrivalControlService.selectedExpectationItems(
                    List.of(visible), List.of(selected.id(), selected.id()));
            assertThat(result).hasSize(1);
            assertThat(result.getFirst().items()).containsExactly(selected);
            assertThat(result.getFirst().items().getFirst().orderItemId()).isEqualTo(selected.orderItemId());
            assertThat(result.getFirst().remainingQty()).isEqualByComparingTo("50");
            assertThat(ProcurementArrivalControlService.selectedExpectationItems(List.of(visible), null))
                    .containsExactly(visible);
        }
    }

    @Test void unknownHiddenOrStaleItemFailsClosedInsteadOfReturningWholeOrderOrPartialSelection() {
        var item = item(UUID.randomUUID(), "50");
        var visible = List.of(task("PURCHASE", List.of(item)));
        for (var selection : List.of(List.of(UUID.randomUUID()), List.of(item.id(), UUID.randomUUID()))) {
            assertThatThrownBy(() -> ProcurementArrivalControlService.selectedExpectationItems(visible, selection))
                    .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        }
        assertThatThrownBy(() -> ProcurementArrivalControlService.selectedExpectationItems(visible, List.of()))
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        assertThatThrownBy(() -> ProcurementArrivalControlService.selectedExpectationItems(visible,
                java.util.Collections.nCopies(101, item.id())))
                .isInstanceOfSatisfying(ApiException.class, error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
    }

    @Test void sourceSelectionCannotBeEmptyOrContainNull() {
        var service = mock(ProcurementArrivalControlService.class, org.mockito.Mockito.CALLS_REAL_METHODS);
        for (List<UUID> ids : java.util.Arrays.asList(null, List.<UUID>of(), java.util.Arrays.asList((UUID) null))) {
            assertThatThrownBy(() -> service.expectationsByIds(ids, null))
                    .isInstanceOfSatisfying(ApiException.class,
                            error -> assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
    }

    @SuppressWarnings("removal")
    private static org.springframework.test.web.servlet.MockMvc mvc(ProcurementArrivalControlService service) {
        var controller = new WarehouseInboundController(service, null, null, null, null, null, null);
        return org.springframework.test.web.servlet.setup.MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new GlobalExceptionHandler())
                .setMessageConverters(new org.springframework.http.converter.json.MappingJackson2HttpMessageConverter(
                        Jackson2ObjectMapperAutoConfiguration.domainObjectMapper()))
                .build();
    }

    private static InboundExpectationItem item(UUID goods, String qty) {
        return new InboundExpectationItem(UUID.randomUUID(), UUID.randomUUID(), 1,
                goods, "UT3128", "产品外箱", null, null, null, null, null, null,
                BigDecimal.ONE, null, new BigDecimal(qty), BigDecimal.ZERO,
                new BigDecimal(qty), BigDecimal.ZERO, null);
    }

    private static InboundExpectationTask task(String type, List<InboundExpectationItem> items) {
        return new InboundExpectationTask(UUID.randomUUID(), type, UUID.randomUUID(), "CD20261021000002",
                UUID.randomUUID(), "供应商", null, null, null, null, null, null, null, "OPEN",
                new BigDecimal("5050"), BigDecimal.ZERO, new BigDecimal("5050"), BigDecimal.ZERO,
                items, List.of("CREATE_" + type + "_RECEIPT"), List.of(), 0, 0);
    }
}
