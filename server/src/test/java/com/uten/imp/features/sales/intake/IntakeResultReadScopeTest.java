package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class IntakeResultReadScopeTest {
    private final MasterIntakeLookupPort lookup=mock(MasterIntakeLookupPort.class);
    @Test void everyUnselectedCustomerCandidateIsCheckedAgain() {
        UUID selected=UUID.randomUUID(); UUID candidate=UUID.randomUUID();
        var profile=mock(MasterIntakeLookupPort.ClientProfile.class); when(profile.status()).thenReturn("使用");
        when(lookup.clientProfile(selected)).thenReturn(profile);
        Map<String,Object> result=Map.of("client",Map.of("selectedClientId",selected.toString(),
                "candidates",List.of(Map.of("clientId",candidate.toString(),"name","historically visible"))));
        assertThatThrownBy(()->IntakeResultReadScope.requireVisible(result,lookup)).isInstanceOf(ApiException.class);
        verify(lookup).clientProfile(selected); verify(lookup).clientProfile(candidate);
    }
    @Test void nestedBundleGoodsAndCandidatesAreOneBoundedLookup() {
        UUID first=UUID.randomUUID(); UUID nested=UUID.randomUUID();
        var row=mock(MasterIntakeLookupPort.GoodsRow.class); when(row.id()).thenReturn(first);
        when(lookup.goodsByIds(Set.of(first,nested))).thenReturn(List.of(row));
        Map<String,Object> result=Map.of("lines",List.of(Map.of("selectedGoodsId",first.toString(),"bundleParts",List.of(
                Map.of("candidates",List.of(Map.of("goodsId",nested.toString(),"name","old candidate")))))));
        assertThatThrownBy(()->IntakeResultReadScope.requireVisible(result,lookup)).isInstanceOf(ApiException.class);
        verify(lookup).goodsByIds(Set.of(first,nested));
    }
    @Test void invalidReferenceCannotSilentlyDropFromAccessCheck() {
        assertThatThrownBy(()->IntakeResultReadScope.requireVisible(Map.of("lines",List.of(Map.of("selectedGoodsId","invalid"))),lookup))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(lookup);
    }
    @Test void visibleReferencesKeepOriginalResultUnmodified() {
        UUID id=UUID.randomUUID(); var row=mock(MasterIntakeLookupPort.GoodsRow.class); when(row.id()).thenReturn(id);
        when(lookup.goodsByIds(Set.of(id))).thenReturn(List.of(row));
        Map<String,Object> result=Map.of("lines",List.of(Map.of("candidates",List.of(Map.of("goodsId",id.toString())))));
        assertThatCode(()->IntakeResultReadScope.requireVisible(result,lookup)).doesNotThrowAnyException();
        assertThat(result).containsKey("lines");
    }
    @Test void customerColumnsNamedLikeServerIdsRemainOrdinaryText() {
        Map<String,Object> result=Map.of("file",Map.of("clientId","customer filename"),"header",Map.of("goodsId","supplier code"),
                "lines",List.of(Map.of("extraValues",Map.of("goodsId","客户编码ABC","clientId","客户名称XYZ"))));
        assertThatCode(()->IntakeResultReadScope.requireVisible(result,lookup)).doesNotThrowAnyException();
        verifyNoInteractions(lookup);
    }
    @Test void reassignedDuplicateDocumentInvalidatesOldDocumentMetadata() {
        UUID client=UUID.randomUUID(); UUID doc=UUID.randomUUID();
        var profile=mock(MasterIntakeLookupPort.ClientProfile.class); when(profile.status()).thenReturn("使用");
        when(lookup.clientProfile(client)).thenReturn(profile);
        when(lookup.recentDocs(client,SalesIntakePipeline.DUPLICATE_DAYS)).thenReturn(List.of());
        Map<String,Object> result=Map.of("client",Map.of("selectedClientId",client.toString()),
                "duplicates",List.of(Map.of("docType","order","id",doc.toString(),"billNo","historically-visible")));
        assertThatThrownBy(()->IntakeResultReadScope.requireVisible(result,lookup)).isInstanceOf(ApiException.class);
        verify(lookup).recentDocs(client,SalesIntakePipeline.DUPLICATE_DAYS);
    }
}
