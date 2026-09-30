package com.uten.imp.features.stock.ledger;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.ledger.dto.StockLedgerRow;
import com.uten.imp.features.stock.ledger.dto.StockLedgerSummary;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 流水行脱敏与派生 (替代旧 /api/stock/movements 的成本脱敏用例): 金额按 goods:cost:view,
 * 往来方名称按「能打开来源单据」的权限, 调拨对方仓不遮; 红冲标签、重量调整行、按重量计货品的结存重量;
 * 汇总的期初/期末倒推与未知重量。
 */
class StockLedgerRowMaskingTest {

    private static final StockLedgerQueryService.GoodsHead PIECES =
            new StockLedgerQueryService.GoodsHead(UUID.randomUUID(), "个", null);
    private static final StockLedgerQueryService.GoodsHead KILOGRAMS =
            new StockLedgerQueryService.GoodsHead(UUID.randomUUID(), "千克", BigDecimal.ONE);

    @Test
    void viewerWithoutCostOrSourceAuthorityGetsNeitherAmountNorCounterpart() throws SQLException {
        StockLedgerRow row = StockLedgerQueryService.row(salesShipment((short) 1), PIECES, false, Set.of("stock:view"));

        assertThat(row.amountLocal()).isNull();
        assertThat(row.costMasked()).isTrue();
        assertThat(row.counterpartKind()).isEqualTo("CLIENT");
        assertThat(row.counterpartName()).isNull();
        assertThat(row.counterpartMasked()).isTrue();
        // 单号照常显示 (点开时由来源页自己的权限把关); 方向与自然方向相反 → 红冲。
        assertThat(row.billNo()).isEqualTo("SS-001");
        assertThat(row.typeLabel()).isEqualTo("销售出库(红冲)");
    }

    @Test
    void costAndSourceAuthoritiesRevealAmountAndCounterpart() throws SQLException {
        StockLedgerRow row = StockLedgerQueryService.row(salesShipment((short) -1), PIECES, true,
                Set.of("stock:view", "warehouse_sales_outbound:view"));

        assertThat(row.amountLocal()).isEqualByComparingTo("123.45");
        assertThat(row.costMasked()).isFalse();
        assertThat(row.counterpartName()).isEqualTo("客户甲");
        assertThat(row.counterpartMasked()).isFalse();
        assertThat(row.typeLabel()).isEqualTo("销售出库");
        assertThat(row.qtySigned()).isEqualByComparingTo("-5");
        assertThat(row.unitName()).isEqualTo("个");
    }

    @Test
    void transferPeerWarehouseIsNeverMaskedButUnregisteredSourcesAre() {
        assertThat(StockLedgerSourceAccess.canSeeCounterpart("STOCK_DOC", "WAREHOUSE", Set.of())).isTrue();
        assertThat(StockLedgerSourceAccess.canSeeCounterpart("LEGACY_X", "CLIENT", Set.of("stock:view"))).isFalse();
        assertThat(StockLedgerSourceAccess.canSeeCounterpart("STOCK_DOC", "WORKSHOP", Set.of("stock_doc:view")))
                .isTrue();
        assertThat(StockLedgerSourceAccess.canSeeCounterpart("PURCHASE_RECEIPT", "SUPPLIER",
                Set.of("warehouse_purchase_receipt_history:view"))).isTrue();
        assertThat(StockLedgerSourceAccess.canSeeCounterpart("PURCHASE_RECEIPT", "SUPPLIER",
                Set.of("stock_doc:view"))).isFalse();
    }

    @Test
    void weightAdjustmentRowsCarryNoQuantityNoAmountAndAKindLabel() throws SQLException {
        Map<String, Object> values = base();
        values.put("row_kind", "W");
        values.put("movement_type", null);
        values.put("direction", null);
        values.put("adj_kind", "COUNT");
        values.put("qty_signed", BigDecimal.ZERO);
        values.put("weight_signed", new BigDecimal("-0.2500"));
        values.put("amount_local", null);
        values.put("counterpart_kind", null);
        StockLedgerRow row = StockLedgerQueryService.row(resultSet(values), PIECES, true, Set.of());

        assertThat(row.rowKind()).isEqualTo("W");
        assertThat(row.typeLabel()).isEqualTo("盘点定重");
        assertThat(row.adjustmentKind()).isEqualTo("COUNT");
        assertThat(row.qtySigned()).isNull();
        assertThat(row.amountLocal()).isNull();
        assertThat(row.weightKgSigned()).isEqualByComparingTo("-0.25");
        assertThat(row.counterpartMasked()).isFalse();
        assertThat(StockLedgerQueryService.adjustmentLabel("RESIDUAL")).isEqualTo("重量尾差调整");
        assertThat(StockLedgerQueryService.adjustmentLabel("ANCHOR")).isEqualTo("重量起算");
        assertThat(StockLedgerQueryService.adjustmentLabel("MANUAL")).isEqualTo("人工核重");
        assertThat(StockLedgerQueryService.adjustmentLabel("REVERSAL")).isEqualTo("撤销盘点重量");
    }

    @Test
    void massUnitGoodsDeriveBalanceWeightFromBalanceQuantity() throws SQLException {
        Map<String, Object> values = base();
        values.put("balance_qty_after", new BigDecimal("12.34567"));
        values.put("balance_weight_after", new BigDecimal("99"));
        StockLedgerRow row = StockLedgerQueryService.row(resultSet(values), KILOGRAMS, true, Set.of());

        assertThat(row.balanceWeightKgAfter()).isEqualByComparingTo("12.3457");
        assertThat(StockLedgerQueryService.exactWeight(new BigDecimal("-1"), BigDecimal.ONE)).isNull();
        assertThat(StockLedgerQueryService.exactWeight(BigDecimal.ZERO, BigDecimal.ONE)).isEqualByComparingTo("0");
    }

    @Test
    void summaryDerivesOpeningAndClosingFromTheAnchorAndMarksUnknownWeights() {
        StockLedgerQuery bounded = new StockLedgerQuery(UUID.randomUUID(), null, null, false,
                OffsetDateTime.parse("2026-07-01T00:00:00+08:00"), OffsetDateTime.parse("2026-09-01T00:00:00+08:00"),
                List.of(), false, null, false, 50, 0);
        StockLedgerQueryService.Totals totals = new StockLedgerQueryService.Totals(
                new BigDecimal("100"), new BigDecimal("50"),
                new BigDecimal("30"), new BigDecimal("12"), false,
                new BigDecimal("10"), new BigDecimal("4"), true,
                7, new BigDecimal("40"), new BigDecimal("10"), BigDecimal.ZERO,
                new BigDecimal("16"), new BigDecimal("4"), 1, 0, new BigDecimal("0.0100"));

        StockLedgerSummary summary = StockLedgerQueryService.summary(totals, bounded, PIECES);

        assertThat(summary.openingQty()).isEqualByComparingTo("70");
        assertThat(summary.closingQty()).isEqualByComparingTo("90");
        assertThat(summary.openingWeightKg()).isEqualByComparingTo("38");
        // 截止日之后有未知重量的行 → 期末重量不知道 (不是 50 - 4)。
        assertThat(summary.closingWeightKg()).isNull();
        assertThat(summary.inWeightUnknownRows()).isEqualTo(1);

        StockLedgerQuery open = new StockLedgerQuery(UUID.randomUUID(), null, null, false, null, null,
                List.of(), false, null, false, 50, 0);
        StockLedgerSummary current = StockLedgerQueryService.summary(totals, open, PIECES);
        assertThat(current.closingQty()).isEqualByComparingTo("100");
        assertThat(current.closingWeightKg()).isEqualByComparingTo("50");

        StockLedgerSummary exact = StockLedgerQueryService.summary(totals, bounded, KILOGRAMS);
        assertThat(exact.openingWeightKg()).isEqualByComparingTo("70");
        assertThat(exact.closingWeightKg()).isEqualByComparingTo("90");
    }

    @Test
    void typeFilterAcceptsCodesAndTheWeightAdjustmentPseudoType() {
        StockLedgerQueryService.TypeFilter filter = StockLedgerQueryService.parseTypes(" 1, 3 ,w,3");
        assertThat(filter.codes()).containsExactly((short) 1, (short) 3);
        assertThat(filter.adjustments()).isTrue();
        assertThat(StockLedgerQueryService.parseTypes(null).codes()).isEmpty();
        assertThatThrownBy(() -> StockLedgerQueryService.parseTypes("1,x")).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> StockLedgerQueryService.parseTypes("0")).isInstanceOf(ApiException.class);
    }

    private static ResultSet salesShipment(short direction) throws SQLException {
        Map<String, Object> values = base();
        values.put("direction", direction);
        values.put("qty_signed", new BigDecimal("5").multiply(BigDecimal.valueOf(direction)));
        return resultSet(values);
    }

    private static Map<String, Object> base() {
        Map<String, Object> values = new HashMap<>();
        values.put("row_kind", "M");
        values.put("id", UUID.randomUUID());
        values.put("transaction_date", OffsetDateTime.parse("2026-09-20T00:00:00+08:00"));
        values.put("movement_type", (short) 3);
        values.put("direction", (short) -1);
        values.put("source_doc_type", "SALES_SHIPMENT");
        values.put("source_doc_id", UUID.randomUUID());
        values.put("source_doc_code", null);
        values.put("bill_no", "SS-001");
        values.put("counterpart_kind", "CLIENT");
        values.put("counterpart_name", "客户甲");
        values.put("warehouse_id", UUID.randomUUID());
        values.put("warehouse_name", "成品仓");
        values.put("qty_signed", new BigDecimal("-5"));
        values.put("weight_signed", new BigDecimal("-1.2500"));
        values.put("weight_source", "MEASURED");
        values.put("balance_qty_after", new BigDecimal("20"));
        values.put("balance_weight_after", new BigDecimal("5.0000"));
        values.put("amount_local", new BigDecimal("123.45"));
        values.put("operator_name", "张三");
        return values;
    }

    private static ResultSet resultSet(Map<String, Object> values) throws SQLException {
        ResultSet rs = mock(ResultSet.class);
        AtomicBoolean lastNull = new AtomicBoolean();
        when(rs.getString(anyString())).thenAnswer(inv -> {
            Object value = values.get(inv.<String>getArgument(0));
            return value == null ? null : value.toString();
        });
        when(rs.getShort(anyString())).thenAnswer(inv -> {
            Object value = values.get(inv.<String>getArgument(0));
            lastNull.set(value == null);
            return value == null ? (short) 0 : ((Number) value).shortValue();
        });
        when(rs.wasNull()).thenAnswer(inv -> lastNull.get());
        when(rs.getBigDecimal(anyString())).thenAnswer(inv -> values.get(inv.<String>getArgument(0)));
        when(rs.getObject(anyString(), org.mockito.ArgumentMatchers.<Class<Object>>any()))
                .thenAnswer(inv -> values.get(inv.<String>getArgument(0)));
        return rs;
    }
}
