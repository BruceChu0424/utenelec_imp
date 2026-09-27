package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import static com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class AggregateAdoptionIntentTest {
    @Test void adoptionUsesOnlyOriginalPathsProvenForTheActualTarget() {
        UUID a=UUID.randomUUID(),b=UUID.randomUUID(),first=UUID.randomUUID(),second=UUID.randomUUID(),claim=UUID.randomUUID();
        GroupInput input=mock(GroupInput.class);
        when(input.sourceRequestedQtyByMaterialLineId()).thenReturn(Map.of(a,new BigDecimal("10000"),b,new BigDecimal("1000")));
        MaterialView rowA=row(a,"1000"),rowB=row(b,"1000");
        AnalysisView view=mock(AnalysisView.class);when(view.flatMaterials()).thenReturn(List.of(rowA,rowB));
        SourcePreview firstSource=source(first,List.of(a)),secondSource=source(second,List.of(b));
        GroupPreview group=mock(GroupPreview.class);when(group.sources()).thenReturn(List.of(firstSource,secondSource));
        var result=AggregateMaterialOrderWriteService.sourceAdoptionIntents(input,group,
                List.of(new AdoptedClaim("MAKE_PUBLIC",claim,second,new BigDecimal("500"))),view);
        assertThat(result).containsExactly(new SourceAdoptionIntent(b,second,"MAKE_PUBLIC",claim,new BigDecimal("500.0000")));
    }

    @Test void repeatedClaimsConserveTheSelectedOriginalSharesAcrossOneCanonicalTarget() {
        UUID a=UUID.randomUUID(),b=UUID.randomUUID(),target=UUID.randomUUID();
        GroupInput input=mock(GroupInput.class);
        when(input.sourceRequestedQtyByMaterialLineId()).thenReturn(Map.of(a,new BigDecimal("10000"),b,new BigDecimal("1000")));
        MaterialView rowA=row(a,"1000"),rowB=row(b,"1000");
        AnalysisView view=mock(AnalysisView.class);when(view.flatMaterials()).thenReturn(List.of(rowA,rowB));
        SourcePreview canonical=source(target,List.of(a,b));
        GroupPreview group=mock(GroupPreview.class);when(group.sources()).thenReturn(List.of(canonical));
        var result=AggregateMaterialOrderWriteService.sourceAdoptionIntents(input,group,
                List.of(new AdoptedClaim("MAKE_PUBLIC",UUID.randomUUID(),target,new BigDecimal("500")),
                        new AdoptedClaim("EXTERNAL_PUBLIC",UUID.randomUUID(),target,new BigDecimal("1500"))),view);
        assertThat(result.stream().filter(row->row.originalMaterialLineId().equals(a)).map(SourceAdoptionIntent::qty).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("1000");
        assertThat(result.stream().filter(row->row.originalMaterialLineId().equals(b)).map(SourceAdoptionIntent::qty).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("1000");
        assertThat(result.stream().map(SourceAdoptionIntent::qty).reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("2000");
    }
    @Test void overlappingTargetsReassignEarlierSharesInsteadOfRejectingALegalClaim() {
        UUID a=UUID.randomUUID(),b=UUID.randomUUID(),first=UUID.randomUUID(),second=UUID.randomUUID();
        GroupInput input=mock(GroupInput.class);when(input.sourceRequestedQtyByMaterialLineId()).thenReturn(Map.of(a,new BigDecimal("500"),b,new BigDecimal("500")));
        MaterialView rowA=row(a,"500"),rowB=row(b,"500");AnalysisView view=mock(AnalysisView.class);when(view.flatMaterials()).thenReturn(List.of(rowA,rowB));
        SourcePreview shared=source(first,List.of(a,b)),exclusive=source(second,List.of(a));
        GroupPreview group=mock(GroupPreview.class);when(group.sources()).thenReturn(List.of(shared,exclusive));
        var result=AggregateMaterialOrderWriteService.sourceAdoptionIntents(input,group,List.of(
                new AdoptedClaim("MAKE_PUBLIC",UUID.randomUUID(),first,new BigDecimal("500")),
                new AdoptedClaim("MAKE_PUBLIC",UUID.randomUUID(),second,new BigDecimal("500"))),view);
        assertThat(result).hasSize(2);
        assertThat(result).anySatisfy(row->{assertThat(row.targetMaterialLineId()).isEqualTo(first);assertThat(row.originalMaterialLineId()).isEqualTo(b);assertThat(row.qty()).isEqualByComparingTo("500");});
        assertThat(result).anySatisfy(row->{assertThat(row.targetMaterialLineId()).isEqualTo(second);assertThat(row.originalMaterialLineId()).isEqualTo(a);assertThat(row.qty()).isEqualByComparingTo("500");});
    }

    private MaterialView row(UUID id,String pending) {
        MaterialView row=mock(MaterialView.class);when(row.materialLineId()).thenReturn(id);when(row.planningUncoveredQty()).thenReturn(new BigDecimal(pending));return row;
    }
    private SourcePreview source(UUID id,List<UUID> origins) {
        SourcePreview source=mock(SourcePreview.class);when(source.materialLineId()).thenReturn(id);when(source.originalMaterialLineIds()).thenReturn(origins);return source;
    }
}
