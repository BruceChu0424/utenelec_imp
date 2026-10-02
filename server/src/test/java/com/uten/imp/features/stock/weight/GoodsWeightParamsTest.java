package com.uten.imp.features.stock.weight;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.stock.weight.GoodsWeightFactsStore.BalanceKey;
import com.uten.imp.features.stock.weight.dto.StockWeightBalance;
import com.uten.imp.features.stock.weight.dto.WeightParams;
import com.uten.imp.features.stock.weight.dto.WeightParamsRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;

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

class GoodsWeightParamsTest {

    private final GoodsWeightFactsStore facts = mock(GoodsWeightFactsStore.class);
    private final NamedParameterJdbcTemplate db = mock(NamedParameterJdbcTemplate.class);
    private final GoodsWeightEstimateService service = new GoodsWeightEstimateService(db, facts,
            mock(SecurityContextCurrentUser.class), new ObjectMapper(), mock(PlatformTransactionManager.class),
            0.00005);

    @Test
    void stockReferenceIsMatchedByWarehouseGoodsAndExactColorWithoutChangingLearnedBasis() {
        UUID goods = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID otherWarehouse = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        List<WeightParamsRequest.Line> lines = List.of(
                new WeightParamsRequest.Line("plain", goods, null, warehouse, null),
                new WeightParamsRequest.Line("color", goods, null, warehouse, color),
                new WeightParamsRequest.Line("other", goods, null, otherWarehouse, null),
                new WeightParamsRequest.Line("legacy", goods, null),
                new WeightParamsRequest.Line("same-physical-stock", goods, UUID.randomUUID(), warehouse, null));
        GoodsWeightFacts goodsFacts = new GoodsWeightFacts(goods, true, UUID.randomUUID(), null, "COUNT",
                new BigDecimal("0.025"), "KG", null, null, null);
        when(facts.loadAll(any())).thenReturn(Map.of(goods, goodsFacts));
        when(facts.supplierRows(any(), any())).thenReturn(Map.of());
        StockWeightBalance plain = balance(warehouse, null, "1000", "20", false);
        StockWeightBalance colored = balance(warehouse, color, "1000", "30", true);
        StockWeightBalance other = balance(otherWarehouse, null, "1000", "40", false);
        when(facts.stockBalances(lines)).thenReturn(Map.of(
                new BalanceKey(warehouse, goods, null), plain,
                new BalanceKey(warehouse, goods, color), colored,
                new BalanceKey(otherWarehouse, goods, null), other));

        List<WeightParams> result = service.params(lines);

        assertThat(result).extracting(WeightParams::key)
                .containsExactly("plain", "color", "other", "legacy", "same-physical-stock");
        assertThat(result).extracting(WeightParams::stockBalance)
                .containsExactly(plain, colored, other, null, plain);
        assertThat(result).allSatisfy(params -> {
            assertThat(params.basis()).isEqualTo("MASTER_PRIOR");
            assertThat(params.tier()).isEqualTo("RED");
            assertThat(params.unitWeightKg()).isEqualByComparingTo("0.025");
        });
        verify(facts).stockBalances(lines);
        verifyNoInteractions(db);
    }

    @Test
    void missingGoodsCannotLeakAStaleBalanceAndNoWarehouseKeepsTheExistingContract() {
        UUID goods = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        List<WeightParamsRequest.Line> lines = List.of(
                new WeightParamsRequest.Line("missing", goods, null, warehouse, null));
        when(facts.loadAll(any())).thenReturn(Map.of());
        when(facts.supplierRows(any(), any())).thenReturn(Map.of());
        when(facts.stockBalances(lines)).thenReturn(Map.of(new BalanceKey(warehouse, goods, null),
                balance(warehouse, null, "1000", "20", false)));

        WeightParams result = service.params(lines).getFirst();

        assertThat(result.basis()).isEqualTo("NONE");
        assertThat(result.stockBalance()).isNull();
    }

    @Test
    void oldRequestJsonStillDeserializesWithoutInventoryContext() throws Exception {
        UUID goods = UUID.randomUUID();
        WeightParamsRequest request = new ObjectMapper().readValue("""
                {"lines":[{"key":"row","goodsId":"%s"}]}
                """.formatted(goods), WeightParamsRequest.class);

        assertThat(request.lines()).containsExactly(new WeightParamsRequest.Line("row", goods, null));
        assertThat(request.lines().getFirst().warehouseId()).isNull();
        assertThat(request.lines().getFirst().colorId()).isNull();
    }

    @Test
    void emptyPageDoesNotQueryStorage() {
        assertThat(service.params(List.of())).isEmpty();
        verifyNoInteractions(facts, db);
    }

    private static StockWeightBalance balance(UUID warehouse, UUID color, String qty, String kg,
                                               boolean estimated) {
        return new StockWeightBalance(warehouse, color, new BigDecimal(qty), new BigDecimal(kg), estimated);
    }
}
