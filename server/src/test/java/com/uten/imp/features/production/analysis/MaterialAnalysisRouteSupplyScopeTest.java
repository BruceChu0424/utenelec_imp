package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MaterialAnalysisRouteSupplyScopeTest {
    @Test void includesEveryExactTargetIncludingZeroQuantityAliasesAndDeduplicatesSharedTargets() {
        UUID first=UUID.randomUUID(),second=UUID.randomUUID(),target=UUID.randomUUID(),other=UUID.randomUUID();
        var result=MaterialAnalysisRouteSupplyScope.expand(List.of(change(first,"BUY"),change(second,"BUY")),
                Map.of(first,delegation(Map.of(target,BigDecimal.ZERO,other,BigDecimal.TEN)),
                        second,delegation(Map.of(target,BigDecimal.ONE))),
                Map.of(target,material(target),other,material(other)));
        assertThat(result).extracting(MaterialAnalysisRouteBatchWriter.Change::materialId)
                .containsExactlyInAnyOrder(first,second,target,other);
        assertThat(result).allSatisfy(row->assertThat(row.route()).isEqualTo("BUY"));
    }

    @Test void neverGuessesOtherRowsByGoodsAndDoesNotTreatMemberChildAsItsParent() {
        UUID original=UUID.randomUUID(),unrelated=UUID.randomUUID();
        assertThat(MaterialAnalysisRouteSupplyScope.expand(List.of(change(original,"MAKE")),
                Map.of(original,new AggregateDelegationProjection.Delegation(BigDecimal.TEN,Map.of(),true)),
                Map.of(unrelated,material(unrelated))))
                .containsExactly(change(original,"MAKE"));
    }

    @Test void rejectsMissingTargetInsteadOfSilentlyDroppingItsSupplyGuard() {
        UUID original=UUID.randomUUID(),missing=UUID.randomUUID();
        assertThrows(ApiException.class,()->MaterialAnalysisRouteSupplyScope.expand(List.of(change(original,"BUY")),
                Map.of(original,delegation(Map.of(missing,BigDecimal.ONE))),Map.of()));
    }

    @Test void rejectsConflictingRoutesConvergingOnTheSameActualNodeBeforeAnyWrite() {
        UUID first=UUID.randomUUID(),second=UUID.randomUUID(),target=UUID.randomUUID();
        assertThrows(ApiException.class,()->MaterialAnalysisRouteSupplyScope.expand(
                List.of(change(first,"BUY"),change(second,"SUBCONTRACT")),
                Map.of(first,delegation(Map.of(target,BigDecimal.ONE)),second,delegation(Map.of(target,BigDecimal.ONE))),
                Map.of(target,material(target))));
    }

    private static AggregateDelegationProjection.Delegation delegation(Map<UUID,BigDecimal> targets) {
        return new AggregateDelegationProjection.Delegation(BigDecimal.ONE,targets,false);
    }
    private static MaterialAnalysisRouteBatchWriter.Change change(UUID id,String route) {
        return new MaterialAnalysisRouteBatchWriter.Change(id,id.toString(),id,route,null);
    }
    private static MaterialAnalysisService.MaterialRow material(UUID id) {
        var row=mock(MaterialAnalysisService.MaterialRow.class);
        when(row.actionGroupKey()).thenReturn(id.toString());when(row.goodsId()).thenReturn(id);
        return row;
    }
}
