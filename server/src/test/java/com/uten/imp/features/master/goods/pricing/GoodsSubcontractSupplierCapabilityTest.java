package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsSubcontractSupplierCapabilityTest {
    private final NamedParameterJdbcTemplate db=mock(NamedParameterJdbcTemplate.class);
    private final MasterReferenceValidationPort references=mock(MasterReferenceValidationPort.class);
    private final GoodsPriceAccess access=mock(GoodsPriceAccess.class);
    private final GoodsSubcontractSupplierService service=new GoodsSubcontractSupplierService(db,new ObjectMapper(),references,access);
    private final UUID goods=UUID.randomUUID();

    @Test void onlySubcontractSourceTypeEnablesTheTabAndTheProbeNeverReadsChildFacts() {
        when(db.queryForList(anyString(),anyMap()))
                .thenReturn(List.of(Map.of("source_type","委外")))
                .thenReturn(List.of(Map.of("source_type","采购")));
        assertThat(service.capability(goods)).isEqualTo(new GoodsSubcontractSupplierContracts.Capability(goods,true));
        assertThat(service.capability(goods).applicable()).isFalse();
        verify(db,times(2)).queryForList(eq("SELECT source_type FROM goods WHERE id=:id AND NOT is_deleted AND NOT auto_created"),eq(Map.of("id",goods)));
        verifyNoMoreInteractions(db);verify(references,times(2)).requireVisibleGoods(goods);
        verify(access,times(2)).require(GoodsPriceContracts.Kind.SUBCONTRACT);verifyNoMoreInteractions(access);
    }
    @Test void sourcePermissionDenialStopsBeforeGoodsOrAnyDatabaseRead() {
        doThrow(new ApiException(ErrorCode.FORBIDDEN,"无来源权限")).when(access).require(GoodsPriceContracts.Kind.SUBCONTRACT);
        assertThatThrownBy(()->service.capability(goods)).isInstanceOfSatisfying(ApiException.class,e->assertThat(e.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        verifyNoInteractions(references,db);
    }
    @Test void inaccessibleOrMissingGoodsNeverEnableTheTab() {
        doThrow(new ApiException(ErrorCode.NOT_FOUND,"货品不可见")).when(references).requireVisibleGoods(goods);
        assertThatThrownBy(()->service.capability(goods)).hasMessageContaining("不可见");verifyNoInteractions(db);
        reset(references);when(db.queryForList(anyString(),anyMap())).thenReturn(List.of());
        assertThatThrownBy(()->service.capability(goods)).isInstanceOfSatisfying(ApiException.class,e->assertThat(e.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
    }
}
