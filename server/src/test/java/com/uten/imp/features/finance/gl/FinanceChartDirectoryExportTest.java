package com.uten.imp.features.finance.gl;

import com.uten.imp.common.export.*;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.features.finance.report.FinanceReportColumnOptions;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FinanceChartDirectoryExportTest {
    @Test void directoryKeepsItsDisplaySchemaAndAppliesKeywordAndHeadersBeforePaging() {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{"1001","库存现金",null,"资产","SYS1 现金",1}));
        String keyword="1001 现金_%";
        try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            var response=FinanceChartReports.directory(em,2,20,
                    new FinanceReportColumnOptions(Map.of("classification","资产","search.name","库存"),"code","desc"),keyword);
            assertEquals(List.of("code","name","currencyName","classification","targets"),
                    response.columns().stream().map(column->column.key()).toList());
            assertEquals("资产",response.rows().getFirst().get("classification"));
        }
        ArgumentCaptor<String> sql=ArgumentCaptor.forClass(String.class);verify(em).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("ORDER BY s.path,s.id"));
        assertTrue(sql.getValue().contains("WHEN 'ASSET' THEN '资产'"));
        assertTrue(sql.getValue().indexOf(":directoryKeyword")<sql.getValue().indexOf("LIMIT :__limit"));
        assertTrue(sql.getValue().indexOf(":headerFacet_classification")<sql.getValue().indexOf("LIMIT :__limit"));
        assertFalse(sql.getValue().contains(keyword));
        verify(query).setParameter("headerFacet_classification","资产");
        verify(query).setParameter("directoryKeyword",com.uten.imp.common.util.KeywordSearch.phrase(keyword));
        verify(query).setParameter("__limit",20);verify(query).setParameter("__offset",20L);
    }

    @Test void directorySelectionUsesOnlyUniqueCodeAndNeverSuppliesOutputValues() {
        var selection=new ExportRowSelection(new TableColumnProjection("finance.chart.directory",null,
                List.of(new TableColumnProjection.Column("name","科目名称",100.0,"text",null)),
                List.of(Map.of("code","1002"))));
        var columns=List.of(new ExportColumn("code","科目编码","text"),new ExportColumn("name","科目名称","text"));
        var actual=selection.select(columns,List.of(Map.of("code","1001","name","库存现金"),Map.of("code","1002","name","银行存款")));
        selection.verifyComplete();assertEquals(List.of(Map.of("code","1002","name","银行存款")),actual);
    }

    @Test void importTemplateRetainsItsOriginalNineFieldsWithoutDirectoryClassificationOrTargets() {
        var em=mock(EntityManager.class);
        var template=FinanceChartReports.read(em,true,1,20,FinanceReportColumnOptions.NONE);
        assertEquals(List.of("code","name","currency","d0","c0","d","c","d1","c1"),
                template.columns().stream().map(column->column.key()).toList());
        verifyNoInteractions(em);
    }
}
