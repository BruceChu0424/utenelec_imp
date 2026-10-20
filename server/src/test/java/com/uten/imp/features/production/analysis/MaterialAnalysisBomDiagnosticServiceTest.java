package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.RdMaterialIssuePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MaterialAnalysisBomDiagnosticServiceTest {
    @Test
    void batchInspectionRetainsRepeatedGoodsSourceIndexesAndLeavesValidDemandAvailable() {
        EntityManager em = mock(EntityManager.class);
        MaterialAnalysisService analyses = mock(MaterialAnalysisService.class);
        RdMaterialIssuePort engineering = mock(RdMaterialIssuePort.class);
        UUID bad = UUID.randomUUID(), good = UUID.randomUUID(), component = UUID.randomUUID();
        List<PreviewItem> items = List.of(source(bad,"A"), source(good,"B"), source(bad,"C"));
        when(analyses.normalizePreviewItems(items)).thenReturn(items);
        Query goodsQuery=query(List.of(bad, good));
        Query findingsQuery=query(Collections.singletonList(new Object[]{"UNIT_MISSING","FG","产品","P","父件","C","组件",1,1L,bad,bad,component}));
        when(em.createNativeQuery(anyString())).thenReturn(goodsQuery,findingsQuery);
        when(engineering.openTaskNos(anyCollection())).thenReturn(Map.of(
                new RdMaterialIssuePort.Target(component,true).key(), "RD-EXISTING"));
        var service = new MaterialAnalysisBomDiagnosticService(em, analyses,
                mock(ProductionDocumentAccessPolicy.class), engineering);

        var result = service.inspect(new BomDiagnosticRequest(null,items));

        assertThat(result.blockedSourceIndexes()).containsExactly(0,2);
        assertThat(result.findings()).singleElement().satisfies(finding -> {
            assertThat(finding.repairGoodsId()).isEqualTo(component);
            assertThat(finding.taskNo()).isEqualTo("RD-EXISTING");
        });
        verify(engineering,never()).forward(any(),any(),anyString());
    }

    @Test
    void forwardingUsesOnlyRevalidatedFindingsAndKeepsExactSourceEvidence() {
        UUID root = UUID.randomUUID(), parent = UUID.randomUUID(), component = UUID.randomUUID();
        RdMaterialIssuePort engineering = mock(RdMaterialIssuePort.class);
        var service = spy(new MaterialAnalysisBomDiagnosticService(mock(EntityManager.class),
                mock(MaterialAnalysisService.class), mock(ProductionDocumentAccessPolicy.class), engineering));
        var request = new BomDiagnosticRequest(null,List.of(source(root,"DEMAND-ONE")));
        var finding = new BomFinding("real-key",root,parent,component,component,true,"产品","父件","组件",
                "UNIT_MISSING","组件没有单位","维护基本单位",null);
        doReturn(new BomDiagnosticView(List.of(finding),List.of(0))).when(service).inspect(request);
        when(engineering.forward(any(),isNull(),anyString())).thenReturn("RD-NEW");

        assertThatThrownBy(() -> service.forward(new BomForwardRequest(request,List.of("forged-key"))))
                .isInstanceOf(ApiException.class).hasMessageContaining("问题已变化");
        verify(engineering,never()).forward(any(),any(),anyString());

        var result = service.forward(new BomForwardRequest(request,List.of("real-key","real-key")));
        assertThat(result.findings()).singleElement().satisfies(item -> assertThat(item.taskNo()).isEqualTo("RD-NEW"));
        verify(engineering,times(1)).forward(eq(new RdMaterialIssuePort.Target(component,true)),isNull(),
                argThat(description -> description.contains("DEMAND-ONE") && description.contains(root.toString())
                        && description.contains("real-key") && description.contains("组件没有单位")));
    }

    @Test
    void forwardingARepairedProblemCannotCreateAStaleTask() {
        RdMaterialIssuePort engineering = mock(RdMaterialIssuePort.class);
        var service = spy(new MaterialAnalysisBomDiagnosticService(mock(EntityManager.class),
                mock(MaterialAnalysisService.class), mock(ProductionDocumentAccessPolicy.class), engineering));
        var request = new BomDiagnosticRequest(null,List.of(source(UUID.randomUUID(),"FIXED")));
        doReturn(new BomDiagnosticView(List.of(),List.of())).when(service).inspect(request);
        assertThatThrownBy(() -> service.forward(new BomForwardRequest(request,List.of("old-key"))))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(engineering);
    }

    private static PreviewItem source(UUID goods,String reference) {
        return new PreviewItem("STOCK",null,goods,null,UUID.randomUUID(),reference,"测试备货",null,BigDecimal.ONE);
    }
    private static Query query(List<?> rows) {
        Query query=mock(Query.class);
        when(query.setParameter(anyString(),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }
}
