package com.uten.imp.features.stock.weight;

import com.uten.imp.features.stock.weight.GoodsWeightFactsStore.BalanceKey;
import com.uten.imp.features.stock.weight.dto.StockWeightBalance;
import com.uten.imp.features.stock.weight.dto.WeightParamsRequest;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.RowCallbackHandler;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class GoodsWeightBalanceQueryTest {

    @Test
    void oneBatchUsesNullSafeExactDimensionsAndPreservesEstimatedProvenance() throws Exception {
        NamedParameterJdbcTemplate db = mock(NamedParameterJdbcTemplate.class);
        UUID goods = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        ResultSet plain = row(warehouse, goods, null, "1000", "20", false);
        ResultSet colored = row(warehouse, goods, color, "500", "11", true);
        doAnswer(call -> {
            RowCallbackHandler handler = call.getArgument(2);
            handler.processRow(plain);
            handler.processRow(colored);
            return null;
        }).when(db).query(anyString(), any(MapSqlParameterSource.class), any(RowCallbackHandler.class));
        List<WeightParamsRequest.Line> lines = List.of(
                new WeightParamsRequest.Line("plain", goods, null, warehouse, null),
                new WeightParamsRequest.Line("same", goods, UUID.randomUUID(), warehouse, null),
                new WeightParamsRequest.Line("colored", goods, null, warehouse, color),
                new WeightParamsRequest.Line("no-warehouse", goods, null));

        Map<BalanceKey, StockWeightBalance> balances = new GoodsWeightFactsStore(db).stockBalances(lines);

        assertThat(balances).hasSize(2);
        assertThat(balances.get(new BalanceKey(warehouse, goods, null)).weightKg())
                .isEqualByComparingTo("20");
        assertThat(balances.get(new BalanceKey(warehouse, goods, color)).estimated()).isTrue();
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        ArgumentCaptor<MapSqlParameterSource> args = ArgumentCaptor.forClass(MapSqlParameterSource.class);
        verify(db).query(sql.capture(), args.capture(), any(RowCallbackHandler.class));
        assertThat(args.getValue().getValues()).hasSize(6)
                .containsEntry("warehouse0", warehouse).containsEntry("goods0", goods)
                .containsEntry("color0", null).containsEntry("color1", color);
        assertThat(sql.getValue()).contains("b.warehouse_id = requested.warehouse_id",
                "b.goods_id = requested.goods_id", "b.color_id IS NOT DISTINCT FROM requested.color_id",
                "WHERE b.qty > 0 AND b.weight > 0", "NOT g.is_deleted");
    }

    @Test
    void omittingWarehouseNeverFallsBackToAllWarehouses() {
        NamedParameterJdbcTemplate db = mock(NamedParameterJdbcTemplate.class);

        assertThat(new GoodsWeightFactsStore(db).stockBalances(List.of(
                new WeightParamsRequest.Line("legacy", UUID.randomUUID(), null)))).isEmpty();

        verifyNoInteractions(db);
    }

    private static ResultSet row(UUID warehouse, UUID goods, UUID color, String qty, String kg,
                                 boolean estimated) throws Exception {
        ResultSet row = mock(ResultSet.class);
        when(row.getObject("warehouse_id", UUID.class)).thenReturn(warehouse);
        when(row.getObject("goods_id", UUID.class)).thenReturn(goods);
        when(row.getObject("color_id", UUID.class)).thenReturn(color);
        when(row.getBigDecimal("qty")).thenReturn(new BigDecimal(qty));
        when(row.getBigDecimal("weight")).thenReturn(new BigDecimal(kg));
        when(row.getBoolean("weight_estimated")).thenReturn(estimated);
        return row;
    }
}
