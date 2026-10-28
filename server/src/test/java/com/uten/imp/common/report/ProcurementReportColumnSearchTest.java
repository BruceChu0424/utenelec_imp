package com.uten.imp.common.report;

import com.uten.imp.features.subcontract.report.ReportColumn;
import com.uten.imp.features.subcontract.report.SubcontractReportService;
import com.uten.imp.security.CommercialPriceVisibility;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProcurementReportColumnSearchTest {
    @Test void calendarDateMenusUseTypedInclusiveRangesAndPreserveTheOwningProjectionOverride() {
        var where=new ReportQueryKit.WhereBuilder("WHERE true");
        ProcurementReportColumnSearch.apply(where,Map.of("search.billDate","2026-10","search.deliverDate","2026-10-01..2026-10-31"),
                Map.of("billDate","date","deliverDate","date"),Map.of("deliverDate","COALESCE(i.deliver_date,o.deliver_date)"));
        var built=where.build(null);
        assertThat(built.sql()).contains("(o.bill_date) >= :report_date_billDate_0_from", "COALESCE(i.deliver_date,o.deliver_date)")
                .doesNotContain("LIKE", "CAST((o.bill_date) AS text)");
        assertThat(built.params()).containsEntry("report_date_billDate_0_from",java.time.LocalDate.of(2026,10,1))
                .containsEntry("report_date_billDate_0_to",java.time.LocalDate.of(2026,11,1))
                .containsEntry("report_date_deliverDate_0_from",java.time.LocalDate.of(2026,10,1))
                .containsEntry("report_date_deliverDate_0_to",java.time.LocalDate.of(2026,11,1));
    }
    @Test
    void onlyDeclaredBusinessValuesAcquireQueriesAndOverridesKeepTheirActualProjection() {
        var where = new ReportQueryKit.WhereBuilder("WHERE true");
        var supported = ProcurementReportColumnSearch.apply(where,
                Map.of("search.goodsName", "_%", "search.amount", ">=0.0000000001"),
                Map.of("goodsName", "text", "amount", "money", "docSeq", "number", "step", "text",
                        "approved", "bool", "__srcId", "text"),
                Map.of("amount", "i.amount_local"));
        assertThat(supported).containsExactlyInAnyOrder("goodsName", "amount");
        var built = where.build(null);
        assertThat(built.sql()).contains("i.goods_name_snapshot", "i.amount_local", ":column_numeric_amount");
        assertThat(built.sql()).doesNotContain("i.amount_original", "_%", "ROW_NUMBER");
        assertThat(built.params()).containsEntry("column_text_goodsName", "_%")
                .containsEntry("column_numeric_amount", new java.math.BigDecimal("0.0000000001"));
    }

    @Test void unsupportedHeaderKeysCannotSilentlyReturnUnfilteredReportRows(){
        for(String key:List.of("docSeq","step","approved","__srcId","costAmount","unknown")){
            var where=new ReportQueryKit.WhereBuilder("WHERE true");
            assertThatThrownBy(()->ReportColumnSearch.apply(where,Map.of("search."+key,"5"),
                    Map.of("qty","number","step","text","approved","bool"),Map.of("qty","i.qty"),Map.of()))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class);
            assertThat(where.build(null).params()).isEmpty();
        }
    }

    @Test
    void maskedMoneyCannotAcquireASearchOracleOrAdvertiseCapabilities() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class, RETURNS_SELF);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(0L);
        List<String> statements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            statements.add(call.getArgument(0));
            return query;
        });
        var service = new SubcontractReportService(em, null);
        var visibility = mock(CommercialPriceVisibility.class);
        ReflectionTestUtils.setField(service, "commercialPriceVisibility", visibility);
        assertThatThrownBy(()->service.execute(List.of(ReportColumn.number("qty","数量"), ReportColumn.money("amount","金额")),
                "SELECT i.qty, i.amount_local", "FROM receipt_items i",
                new ReportQueryKit.WhereBuilder("WHERE true"), "i.id", List.of(),
                Map.of("search.qty", ">0", "search.amount", "invalid-probe"), 1, 20, null, null))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .satisfies(error->assertThat(((com.uten.imp.common.web.ApiException)error).getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN));
        assertThat(statements).isEmpty();
        var result=service.execute(List.of(ReportColumn.number("qty","数量"),ReportColumn.money("amount","金额")),
                "SELECT i.qty,i.amount_local","FROM receipt_items i",new ReportQueryKit.WhereBuilder("WHERE true"),"i.id",List.of(),
                Map.of("search.qty",">0"),1,20,null,null);
        assertThat(result.columnSearchKeys()).containsExactly("qty");
        assertThat(result.columns()).extracting(ReportColumn::key).containsExactly("qty");
        assertThat(statements).allMatch(sql -> sql.contains("column_numeric_qty") && !sql.contains("column_numeric_amount"));
    }
}
