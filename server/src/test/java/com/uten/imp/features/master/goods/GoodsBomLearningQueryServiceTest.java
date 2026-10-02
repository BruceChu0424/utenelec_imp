package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * 「BOM 学习记录」(ADR-129)：组装边的设计/真实使用数量取自视图(Java 不重算平均值)，
 * BOM 外实际用过的料单列并标出「删过不再自动加回」，看不到的组件整行不列；
 * 两种行都经 BomItemUsage 同一个映射，canRelearn 与重新学习接口同一权限；不良数、实产单耗与不良率
 * 同样原样取视图，档案带同一批族的不良数。
 */
class GoodsBomLearningQueryServiceTest {
    final EntityManager em=mock(EntityManager.class);
    final MasterReferenceValidationPort references=mock(MasterReferenceValidationPort.class);
    final MasterObjectAccess access=mock(MasterObjectAccess.class);
    final TxSessionVars tx=mock(TxSessionVars.class);
    final SecurityContextCurrentUser currentUser=mock(SecurityContextCurrentUser.class);
    final GoodsBomMaterialEvidenceQuery evidence=mock(GoodsBomMaterialEvidenceQuery.class);
    final GoodsBomLearningQueryService service=new GoodsBomLearningQueryService(em,references,access,tx,currentUser,evidence);

    @Test void invisibleParentIsRejectedBeforeAnyLearningQuery() {
        UUID parent=UUID.randomUUID();
        doThrow(new ApiException(ErrorCode.NOT_FOUND,"货品不存在")).when(references).requireVisibleGoods(parent);
        assertThrows(ApiException.class,()->service.summary(parent));verifyNoInteractions(em,access,evidence);
    }

    @Test void noLearningProfileStillIncludesVisibleMaterialEvidence() {
        UUID parent=UUID.randomUUID(), material=UUID.randomUUID();
        Query empty=query(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(empty);
        java.util.function.Predicate<UUID> visible=ignored->true;
        when(access.visibleGoodsOwner()).thenReturn(visible);
        var choice=new GoodsBomMaterialEvidenceQuery.Evidence("PERIODIC_CHOICE","CONFIRMED",material,
                "PC01","PC颗粒",null,null,UUID.randomUUID(),"千克",false,1L,null);
        when(evidence.list(parent,visible)).thenReturn(List.of(choice));

        var summary=service.summary(parent);

        assertNull(summary.profile());assertTrue(summary.components().isEmpty());
        assertEquals(List.of(choice),summary.materialEvidence());
        verify(references).requireVisibleGoods(parent);
    }

    @Test void goodsWithoutSamplesStillListsItsBomEdgesWithDesignUsageOnly() {
        UUID edge=UUID.randomUUID(),component=UUID.randomUUID(),owner=UUID.randomUUID();
        Query profile=query(List.of());
        Query edges=query(Collections.singletonList(edgeRow(edge,component,"P01",owner,"2",
                null,null,"NO_DATA","2.000000","DESIGN",0L,"0","0",false,"0",null,null)));
        Query offBom=query(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(profile,edges,offBom);
        when(access.visibleGoodsOwner()).thenReturn(ignored->true);

        var result=service.summary(UUID.randomUUID());

        assertNull(result.profile());
        assertEquals(1,result.components().size());
        var only=result.components().getFirst();
        assertTrue(only.inBom());assertEquals(edge,only.bomItemId());
        assertEquals(0,new BigDecimal("2").compareTo(only.designQty()));
        assertNull(only.usage().actualQty());assertEquals("NO_DATA",only.usage().actualStatus());
        assertEquals("DESIGN",only.usage().usageBasis());
        // 没有学习数据：不良数是 0，实产单耗与不良率为空(不编造)。
        assertEquals(0,only.usage().actualDefectQty().signum());
        assertNull(only.usage().actualPerProducedQty());assertNull(only.usage().actualDefectRate());
        assertFalse(result.canRelearn());
        verify(em,times(3)).createNativeQuery(anyString());
    }

    @Test void componentsCarryDatabaseAveragesOffBomReleasedRowsAndRespectOwnerVisibility() {
        UUID visible=UUID.randomUUID(),hidden=UUID.randomUUID();
        UUID edge=UUID.randomUUID(),component=UUID.randomUUID(),released=UUID.randomUUID();
        Query profile=query(Collections.singletonList(new Object[]{new BigDecimal("400"),new BigDecimal("100"),2L,null,"个"}));
        Query edges=query(List.of(
                edgeRow(edge,component,"P01",visible,"0.3","0.275","0.275","ACTUAL","0.275000","ACTUAL",2L,"400","110",true,
                        "100","0.22","0.2"),
                edgeRow(UUID.randomUUID(),UUID.randomUUID(),"SECRET",hidden,"1",null,null,"NO_DATA","1.000000","DESIGN",0L,"0","0",false,
                        "0",null,null)));
        Query offBom=query(List.of(
                offBomRow(released,"R01",visible,true,"0.05","ACTUAL",2L,"400","20","100","0.04","0.2"),
                offBomRow(UUID.randomUUID(),"SECRET2",hidden,false,"1","ACTUAL",2L,"400","400","0","1","0")));
        when(em.createNativeQuery(anyString())).thenReturn(profile,edges,offBom);
        when(access.visibleGoodsOwner()).thenReturn(visible::equals);

        var result=service.summary(UUID.randomUUID());

        assertEquals(0,new BigDecimal("400").compareTo(result.profile().totalOutputQty()));
        assertEquals(0,new BigDecimal("100").compareTo(result.profile().totalDefectQty()));
        assertEquals(2,result.profile().sampleCount());assertEquals("个",result.profile().outputUnitName());
        assertEquals(2,result.components().size());
        var inBom=result.components().get(0);
        assertEquals(component,inBom.componentGoodsId());assertTrue(inBom.inBom());assertTrue(inBom.usage().systemLearned());
        // 平均值是视图算好的 actual_qty，不是 Java 用净耗/产量再除一次。
        assertEquals(0,new BigDecimal("0.275").compareTo(inBom.usage().actualQty()));
        assertEquals(0,new BigDecimal("0.3").compareTo(inBom.designQty()));
        assertEquals(0,new BigDecimal("110").compareTo(inBom.usage().actualNetQty()));
        assertEquals(0,new BigDecimal("400").compareTo(inBom.usage().actualOutputQty()));
        assertEquals(2,inBom.usage().actualSampleCount());assertEquals("ACTUAL",inBom.usage().usageBasis());
        // 不良只派生说明数，也是视图算好的：实产单耗 = 净耗 / (良品 + 不良)，不良率 = 不良 / (良品 + 不良)。
        assertEquals(0,new BigDecimal("100").compareTo(inBom.usage().actualDefectQty()));
        assertEquals(0,new BigDecimal("0.22").compareTo(inBom.usage().actualPerProducedQty()));
        assertEquals(0,new BigDecimal("0.2").compareTo(inBom.usage().actualDefectRate()));
        var offBomRow=result.components().get(1);
        assertEquals(released,offBomRow.componentGoodsId());
        assertFalse(offBomRow.inBom());assertTrue(offBomRow.released());assertNull(offBomRow.bomItemId());
        assertNull(offBomRow.designQty());
        // BOM 外的料走同一个映射：状态与窗口是视图给的，没有计算采用值，也不是系统学习边。
        var offUsage=offBomRow.usage();
        assertEquals(0,new BigDecimal("0.05").compareTo(offUsage.actualQty()));
        assertEquals(0,new BigDecimal("0.05").compareTo(offUsage.actualPerUnitQty()));
        assertEquals("ACTUAL",offUsage.actualStatus());
        assertNull(offUsage.effectiveQty());assertNull(offUsage.usageBasis());assertFalse(offUsage.systemLearned());
        assertEquals(2,offUsage.actualSampleCount());
        assertEquals(0,new BigDecimal("20").compareTo(offUsage.actualNetQty()));
        assertEquals(0,new BigDecimal("400").compareTo(offUsage.actualOutputQty()));
        assertEquals(0,new BigDecimal("100").compareTo(offUsage.actualDefectQty()));
        assertEquals(0,new BigDecimal("0.04").compareTo(offUsage.actualPerProducedQty()));
        assertEquals(0,new BigDecimal("0.2").compareTo(offUsage.actualDefectRate()));
    }

    @Test void offBomRowsReadTheSingleUsageViewInsteadOfRecomputingStatusOrBaseline() {
        Query profile=query(List.of()),edges=query(List.of()),offBom=query(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(profile,edges,offBom);
        when(access.visibleGoodsOwner()).thenReturn(ignored->true);

        service.summary(UUID.randomUUID());

        verify(em).createNativeQuery(argThat((String sql)->sql.contains("FROM v_goods_bom_actual_usage a")
                && sql.contains(com.uten.imp.features.master.goods.dto.BomItemUsage.OFF_BOM_COLUMNS)
                && !sql.contains("baseline") && !sql.contains("goods_bom_actual_usages")));
    }

    @Test void canRelearnFollowsTheRelearnPermission() {
        Query empty=query(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(empty);
        when(access.visibleGoodsOwner()).thenReturn(ignored->true);
        when(currentUser.get()).thenReturn(Optional.of(user(Set.of("goods:view","goods:bom:edit"))))
                .thenReturn(Optional.of(user(Set.of("goods:view"))));

        assertTrue(service.summary(UUID.randomUUID()).canRelearn());
        assertFalse(service.summary(UUID.randomUUID()).canRelearn());
    }

    @Test void relearnWithoutAnyUsageRowFailsInPlainWords() {
        UUID goods=UUID.randomUUID();
        Query relearn=mock(Query.class);when(relearn.setParameter(anyString(),any())).thenReturn(relearn);
        when(relearn.getSingleResult()).thenReturn(0);
        when(em.createNativeQuery(anyString())).thenReturn(relearn);

        ApiException error=assertThrows(ApiException.class,()->service.relearn(goods,UUID.randomUUID()));

        assertEquals("这个组件还没有真实使用数据，不需要重新学习",error.getMessage());
        verify(tx).bind();verify(references).requireVisibleGoods(goods);
    }

    @Test void relearnCallsTheDatabaseFunctionThenReturnsTheSameSummary() {
        UUID goods=UUID.randomUUID(),component=UUID.randomUUID();
        Query relearn=mock(Query.class);when(relearn.setParameter(anyString(),any())).thenReturn(relearn);
        when(relearn.getSingleResult()).thenReturn(1);
        Query profile=query(Collections.singletonList(new Object[]{new BigDecimal("100"),BigDecimal.ZERO,1L,null,"个"}));
        Query edges=query(List.of()),offBom=query(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(relearn,profile,edges,offBom);
        when(access.visibleGoodsOwner()).thenReturn(ignored->true);

        var result=service.relearn(goods,component);

        assertNotNull(result.profile());
        verify(em).createNativeQuery(contains("fn_relearn_bom_actual_usage"));
        verify(relearn).setParameter("goods",goods);verify(relearn).setParameter("component",component);
    }

    /** [行 id, 组件 id, 编号, 名称, 单位 id, 单位名, 归属人, 设计值, BomItemUsage.COLUMNS...]。 */
    private static Object[] edgeRow(UUID edge,UUID component,String code,UUID owner,String design,
                                    String actual,String perUnit,String status,String effective,String basis,
                                    long samples,String output,String net,boolean learned,
                                    String defect,String perProduced,String defectRate) {
        return new Object[]{edge,component,code,"名称"+code,UUID.randomUUID(),"千克",owner,new BigDecimal(design),
                amount(actual),amount(perUnit),status,
                new BigDecimal(effective),basis,samples,new BigDecimal(output),new BigDecimal(net),null,null,learned,
                new BigDecimal(defect),amount(perProduced),amount(defectRate)};
    }

    /** [组件 id, 编号, 名称, 单位 id, 单位名, 归属人, 删过, BomItemUsage.OFF_BOM_COLUMNS...]。 */
    private static Object[] offBomRow(UUID component,String code,UUID owner,boolean released,String actual,
                                      String status,long samples,String output,String net,
                                      String defect,String perProduced,String defectRate) {
        BigDecimal value=amount(actual);
        return new Object[]{component,code,"名称"+code,UUID.randomUUID(),"千克",owner,released,
                value,value,status,null,null,samples,new BigDecimal(output),new BigDecimal(net),null,null,false,
                new BigDecimal(defect),amount(perProduced),amount(defectRate)};
    }

    private static BigDecimal amount(String value){return value==null?null:new BigDecimal(value);}

    private static AuthUser user(Set<String> permissions) {
        return new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"tester",permissions,false,true,false);
    }

    private Query query(List<?> rows) {
        Query query=mock(Query.class);when(query.setParameter(eq("goods"),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);return query;
    }
}
