package com.uten.imp.features.reporting.export;

import com.uten.imp.features.master.export.MasterReportExportSource;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ExportLimitPort;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.account.AccountService;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.currency.CurrencyService;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.mould.MouldService;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.warehouse.WarehouseService;
import com.uten.imp.features.master.referencemethod.ReferenceMethodService;
import jakarta.validation.Validation;
import jakarta.validation.ValidatorFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.*;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MasterReportExportSourceTest {
    static ValidatorFactory validators;
    final GoodsService goods=mock(GoodsService.class);
    final ClientService clients=mock(ClientService.class);
    final SupplierService suppliers=mock(SupplierService.class);
    final AccountService accounts=mock(AccountService.class);
    final CurrencyService currencies=mock(CurrencyService.class);
    final ColorService colors=mock(ColorService.class);
    final UnitService units=mock(UnitService.class);
    final MouldService moulds=mock(MouldService.class);
    final WarehouseService warehouses=mock(WarehouseService.class);
    final ReferenceMethodService references=mock(ReferenceMethodService.class);
    final ExportLimitPort limits=mock(ExportLimitPort.class);
    final AtomicReference<Object> decoded=new AtomicReference<>();
    final ExportPayload payload=new ExportPayload(List.of(),List.of(),0);
    MasterReportExportSource source;
    @BeforeAll static void validation(){validators=Validation.buildDefaultValidatorFactory();}
    @AfterAll static void close(){validators.close();}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    @BeforeEach void source(){
        source=new MasterReportExportSource(goods,clients,suppliers,accounts,currencies,colors,units,moulds,warehouses,
                references,new ObjectMapper(),validators.getValidator(),limits);
        when(limits.exportMaxRows()).thenReturn(100_000);
        org.mockito.stubbing.Answer<ExportPayload> capture=call->{decoded.set(call.getArgument(0));return payload;};
        doAnswer(capture).when(goods).export(any(),any(),any(),anyInt());
        doAnswer(capture).when(clients).export(any(),any(),any(),anyInt());
        doAnswer(capture).when(suppliers).export(any(),any(),any(),anyInt());
        doAnswer(capture).when(accounts).export(any(),any(),any(),anyInt());
        doAnswer(capture).when(currencies).export(any(),any(),any(),anyInt());
        doAnswer(capture).when(colors).export(any(),anyInt());
        doAnswer(capture).when(units).export(any(),anyInt());
        doAnswer(capture).when(moulds).export(any(),anyInt());
        doAnswer(capture).when(warehouses).export(any(),anyInt());
        doAnswer(capture).when(references).exportSettlementAdmin(any(),anyInt());
    }
    private static ReportExportRequest request(String report,String filter){
        return new ReportExportRequest(UUID.randomUUID(),"master",report,Map.of("filter",filter),null,null,null);
    }
    private static void exporter(String report){
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("exporter",null,
                List.of(new SimpleGrantedAuthority(report+":export"))));
    }
    @ParameterizedTest @ValueSource(strings={"goods","client","supplier","account","currency","color","unit","mould","warehouse","settlement_method"})
    void everyOriginalExportOnlyAuthorityUsesItsOwnTypedSource(String report){
        exporter(report);
        assertThat(source.read(request(report,"{}"))).isSameAs(payload);
        assertThat(decoded.get()).isNotNull();
        assertThat(MasterReportExportSource.permission(report)).isEqualTo(report+":export");
        assertThat(MasterReportExportSource.projectionScope(report)).isEqualTo("master_"+report);
        assertThat(MasterReportExportSource.authorityDomain(report))
                .isEqualTo(Set.of("client","supplier").contains(report)?report:"master_"+report);
        if("client".equals(report))assertThat(((ClientQueryFilter)decoded.get()).excludeLegacyFinanceStub()).isTrue();
    }
    @Test void setsColumnTermsAndExactContactValuesDoNotFlattenOrRound(){
        exporter("goods"); UUID one=UUID.randomUUID(),two=UUID.randomUUID();
        source.read(request("goods","{\"categoryRootIds\":[\""+one+"\",\""+two+"\"],\"nullFields\":[\"unitRef\"],\"columnSearch\":{\"name\":\"=original\"}}"));
        var goodsFilter=(GoodsQueryFilter)decoded.get();
        assertThat(goodsFilter.categoryRootIds()).containsExactlyInAnyOrder(one,two);
        assertThat(goodsFilter.nullFields()).containsExactly("unitRef");
        assertThat(goodsFilter.columnSearch()).containsEntry("name","=original");
        exporter("client");
        source.read(request("client","{\"mobile\":\"00123\",\"bankAccount\":\"00001\",\"credit\":\"12345678901234567890.000100\",\"excludeLegacyFinanceStub\":false}"));
        var client=(ClientQueryFilter)decoded.get();
        assertThat(client.mobile()).isEqualTo("00123");assertThat(client.bankAccount()).isEqualTo("00001");
        assertThat(client.credit().toPlainString()).isEqualTo("12345678901234567890.000100");
        assertThat(client.excludeLegacyFinanceStub()).isFalse();
    }
    @Test void invalidOrCredentialFiltersAreRejectedBeforePersistenceWithoutExposingValues(){
        for(String raw:List.of("{", "[]", "{\"unknown\":\"private-sentinel\"}", "{\"password\":\"private-sentinel\"}",
                "{\"columnSearch\":{\"password\":\"private-sentinel\"}}", "{\"keyword\":\""+"x".repeat(201)+"\"}")){
            assertThatThrownBy(()->source.validate(request("client",raw))).isInstanceOf(ApiException.class)
                    .hasMessage("主档导出筛选参数无效").hasMessageNotContaining("private-sentinel");
        }
        verifyNoInteractions(clients);
    }
    @Test void anotherFeatureExportDoesNotAuthorizeAClientExport(){
        exporter("supplier");
        assertThatThrownBy(()->source.read(request("client","{}"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(clients);
    }
}
