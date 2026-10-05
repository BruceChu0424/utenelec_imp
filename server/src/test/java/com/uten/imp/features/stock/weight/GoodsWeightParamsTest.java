package com.uten.imp.features.stock.weight;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.stock.weight.GoodsWeightFactsStore.BalanceKey;
import com.uten.imp.features.stock.weight.dto.StockWeightBalance;
import com.uten.imp.features.stock.weight.dto.WeightParams;
import com.uten.imp.features.stock.weight.dto.WeightParamsRequest;
import com.uten.imp.features.stock.weight.dto.WeightParamsResponse;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.validation.beanvalidation.LocalValidatorFactoryBean;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 单重参数结构化契约 (ADR-135 §7.2 / ADR-151): 请求行只带 (goodsId, supplierId?, warehouseId?, colorId?),
 * 单重按 (货品, 供应商) 解析、与请求同序返回; 库存均重参考按 (仓库, 货品, 颜色) 单独返回。
 */
class GoodsWeightParamsTest {

    private final GoodsWeightFactsStore facts = mock(GoodsWeightFactsStore.class);
    private final NamedParameterJdbcTemplate db = mock(NamedParameterJdbcTemplate.class);
    private final GoodsWeightEstimateService service = new GoodsWeightEstimateService(db, facts,
            mock(SecurityContextCurrentUser.class), new ObjectMapper(), mock(PlatformTransactionManager.class),
            0.00005);

    @Test
    void unitWeightFollowsGoodsAndSupplierWhileStockReferenceIsReturnedSeparatelyByExactDimensions() {
        UUID goods = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID otherWarehouse = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        List<WeightParamsRequest.Line> lines = List.of(
                new WeightParamsRequest.Line(goods, null, warehouse, null),
                new WeightParamsRequest.Line(goods, null, warehouse, color),
                new WeightParamsRequest.Line(goods, null, otherWarehouse, null),
                new WeightParamsRequest.Line(goods, null),
                new WeightParamsRequest.Line(goods, supplier, warehouse, null));
        GoodsWeightFacts goodsFacts = new GoodsWeightFacts(goods, true, UUID.randomUUID(), null, "COUNT",
                new BigDecimal("0.025"), "KG", null, null, null);
        when(facts.loadAll(any())).thenReturn(Map.of(goods, goodsFacts));
        when(facts.supplierRows(any(), any())).thenReturn(Map.of());
        StockWeightBalance plain = balance(warehouse, goods, null, "1000", "20", false);
        StockWeightBalance colored = balance(warehouse, goods, color, "1000", "30", true);
        StockWeightBalance other = balance(otherWarehouse, goods, null, "1000", "40", false);
        when(facts.stockBalances(lines)).thenReturn(Map.of(
                new BalanceKey(warehouse, goods, null), plain,
                new BalanceKey(warehouse, goods, color), colored,
                new BalanceKey(otherWarehouse, goods, null), other));

        WeightParamsResponse result = service.params(lines);

        assertThat(result.items()).extracting(WeightParams::goodsId).containsOnly(goods);
        assertThat(result.items()).extracting(WeightParams::supplierId)
                .containsExactly(null, null, null, null, supplier);
        assertThat(result.items()).allSatisfy(params -> {
            assertThat(params.basis()).isEqualTo("MASTER_PRIOR");
            assertThat(params.tier()).isEqualTo("RED");
            assertThat(params.unitWeightKg()).isEqualByComparingTo("0.025");
        });
        // 同仓同色的两行(不同供应商)共用同一库存快照, 只返回一次。
        assertThat(result.stockBalances()).containsExactly(plain, colored, other);
        verify(facts).stockBalances(lines);
        verifyNoInteractions(db);
    }

    @Test
    void missingGoodsCannotLeakAStaleBalance() {
        UUID goods = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        List<WeightParamsRequest.Line> lines = List.of(new WeightParamsRequest.Line(goods, null, warehouse, null));
        when(facts.loadAll(any())).thenReturn(Map.of());
        when(facts.supplierRows(any(), any())).thenReturn(Map.of());
        when(facts.stockBalances(lines)).thenReturn(Map.of(new BalanceKey(warehouse, goods, null),
                balance(warehouse, goods, null, "1000", "20", false)));

        WeightParamsResponse result = service.params(lines);

        assertThat(result.items().getFirst().basis()).isEqualTo("NONE");
        assertThat(result.stockBalances()).isEmpty();
    }

    /**
     * 2026-10-04 实测: 客户端把 4 个 UUID 拼成 147 字的 key, 服务端 @Size(max=100) 整批 422 且页面静默。
     * 结构化契约下 4 个 UUID 齐全的行必须 200, 响应只带结构化身份, 不再出现 key 字段。
     */
    @Test
    void fourUuidLineIsAcceptedOverHttpAndResponseCarriesStructuredIdentityOnly() throws Exception {
        UUID goods = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        GoodsWeightEstimateService estimates = mock(GoodsWeightEstimateService.class);
        StockWeightBalance reference = balance(warehouse, goods, color, "10", "2.5", false);
        WeightParams params = new WeightParams(goods, supplier, "NONE", false, null, null, null, null, 0.02, null,
                null, null, null, 20, null, new BigDecimal("3"), null, null, null, false, null, null, null, "COUNT",
                true, 0.00005);
        when(estimates.params(List.of(new WeightParamsRequest.Line(goods, supplier, warehouse, color))))
                .thenReturn(new WeightParamsResponse(List.of(params), List.of(reference)));
        var validator = new LocalValidatorFactoryBean();
        validator.afterPropertiesSet();
        MockMvc http = MockMvcBuilders.standaloneSetup(new StockWeightController(estimates, null, null, null))
                .setControllerAdvice(new GlobalExceptionHandler()).setValidator(validator).build();

        String body = """
                {"lines":[{"goodsId":"%s","supplierId":"%s","warehouseId":"%s","colorId":"%s"}]}
                """.formatted(goods, supplier, warehouse, color);
        var response = http.perform(post("/api/stock/weight/params").contentType("application/json").content(body))
                .andReturn().getResponse();

        assertThat(response.getStatus()).isEqualTo(200);
        JsonNode json = new ObjectMapper().readTree(response.getContentAsString());
        JsonNode item = json.path("items").get(0);
        assertThat(item.path("goodsId").asText()).isEqualTo(goods.toString());
        assertThat(item.path("supplierId").asText()).isEqualTo(supplier.toString());
        assertThat(item.has("key")).isFalse();
        assertThat(item.has("stockBalance")).isFalse();
        JsonNode stock = json.path("stockBalances").get(0);
        assertThat(stock.path("warehouseId").asText()).isEqualTo(warehouse.toString());
        assertThat(stock.path("goodsId").asText()).isEqualTo(goods.toString());
        assertThat(stock.path("colorId").asText()).isEqualTo(color.toString());

        // 缺 goodsId 仍是逐行校验错误(422), 不是整批静默失败。
        var invalid = http.perform(post("/api/stock/weight/params").contentType("application/json")
                .content("{\"lines\":[{\"warehouseId\":\"" + warehouse + "\"}]}")).andReturn().getResponse();
        assertThat(invalid.getStatus()).isEqualTo(422);
    }

    @Test
    void requestJsonDeserializesStructuredIdentityWithoutAnyKey() throws Exception {
        UUID goods = UUID.randomUUID();
        WeightParamsRequest request = new ObjectMapper().readValue("""
                {"lines":[{"goodsId":"%s"}]}
                """.formatted(goods), WeightParamsRequest.class);

        assertThat(request.lines()).containsExactly(new WeightParamsRequest.Line(goods, null));
        assertThat(request.lines().getFirst().warehouseId()).isNull();
        assertThat(request.lines().getFirst().colorId()).isNull();
    }

    @Test
    void emptyPageDoesNotQueryStorage() {
        WeightParamsResponse result = service.params(List.of());
        assertThat(result.items()).isEmpty();
        assertThat(result.stockBalances()).isEmpty();
        verifyNoInteractions(facts, db);
    }

    private static StockWeightBalance balance(UUID warehouse, UUID goods, UUID color, String qty, String kg,
                                              boolean estimated) {
        return new StockWeightBalance(warehouse, goods, color, new BigDecimal(qty), new BigDecimal(kg), estimated);
    }
}
