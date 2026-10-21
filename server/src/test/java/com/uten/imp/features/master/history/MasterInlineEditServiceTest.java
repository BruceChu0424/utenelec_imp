package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.account.AccountService;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorDetail;
import com.uten.imp.features.master.color.dto.ColorSaveRequest;
import com.uten.imp.features.master.currency.CurrencyService;
import com.uten.imp.features.master.currency.dto.CurrencyDetail;
import com.uten.imp.features.master.currency.dto.CurrencySaveRequest;
import com.uten.imp.features.master.mould.MouldService;
import com.uten.imp.features.master.referencemethod.ReferenceMethodService;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import com.uten.imp.features.master.supplier.dto.SupplierDetail;
import com.uten.imp.features.master.supplier.dto.SupplierSaveRequest;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.unit.dto.UnitDetail;
import com.uten.imp.features.master.unit.dto.UnitSaveRequest;
import com.uten.imp.features.master.warehouse.WarehouseService;
import com.uten.imp.features.master.warehouse.dto.WarehouseDetail;
import com.uten.imp.features.master.warehouse.dto.WarehouseSaveRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.Validation;
import jakarta.validation.ValidatorFactory;
import org.hibernate.query.NativeQuery;
import org.junit.jupiter.api.*;
import org.mockito.ArgumentCaptor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MasterInlineEditServiceTest {
    EntityManager em;ColorService colors;UnitService units;CurrencyService currencies;MasterInlineEditService service;
    ClientService clients;SupplierService suppliers;WarehouseService warehouses;
    ValidatorFactory validators;UUID id=UUID.randomUUID();
    @BeforeEach @SuppressWarnings("unchecked") void start() {
        em=mock(EntityManager.class);NativeQuery<Object> query=mock(NativeQuery.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);when(query.getResultList()).thenReturn(List.of(id));
        colors=mock(ColorService.class);units=mock(UnitService.class);currencies=mock(CurrencyService.class);
        clients=mock(ClientService.class);suppliers=mock(SupplierService.class);warehouses=mock(WarehouseService.class);
        var current=mock(SecurityContextCurrentUser.class);var user=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"inline-test",Set.of(),false,true,true);
        when(current.get()).thenReturn(Optional.of(user));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));
        validators=Validation.buildDefaultValidatorFactory();
        service=new MasterInlineEditService(em,new ObjectMapper(),validators.getValidator(),current,mock(TxSessionVars.class),colors,units,currencies,mock(MouldService.class),mock(AccountService.class),mock(ReferenceMethodService.class),clients,suppliers,warehouses);
    }
    @AfterEach void stop() {SecurityContextHolder.clearContext();validators.close();}
    @Test void staleListValueCannotReachOriginalUpdateCommand() {
        when(colors.detail(id)).thenReturn(new ColorDetail(id,"C01","someone else changed","使用",null));
        assertThrows(ApiException.class,()->service.patch("colors",id,Map.of("name","old"),Map.of("name","mine")));
        verify(colors,never()).update(any(),any());
    }
    @Test void successfulPatchKeepsCurrentUnchangedFormFieldsAndOriginalNumber() {
        when(colors.detail(id)).thenReturn(new ColorDetail(id,"C01","old","使用",null));
        service.patch("colors",id,Map.of("name","old"),Map.of("name","new"));
        var request=ArgumentCaptor.forClass(ColorSaveRequest.class);verify(colors).update(eq(id),request.capture());
        assertEquals("new",request.getValue().getName());assertEquals("C01",request.getValue().getCode());assertEquals("使用",request.getValue().getStatus());
    }
    @Test void readOnlyNumberAndMissingExpectedValueAreRejectedBeforeReadingTheRow() {
        assertThrows(ApiException.class,()->service.patch("colors",id,Map.of("code","C01"),Map.of("code","new")));
        assertThrows(ApiException.class,()->service.patch("colors",id,Map.of(),Map.of("name","new")));
        verifyNoInteractions(colors);verifyNoInteractions(em);
    }
    @Test void changingUnitNamePreservesMeasurementAndLeavingMassClearsItsCode() {
        when(units.detail(id)).thenReturn(new UnitDetail(id,"U01","公斤","使用",null,"MASS","KG"));
        service.patch("units",id,Map.of("name","公斤"),Map.of("name","千克"));
        service.patch("units",id,Map.of("measurementDimension","MASS"),Map.of("measurementDimension","COUNT"));
        var requests=ArgumentCaptor.forClass(UnitSaveRequest.class);verify(units,times(2)).update(eq(id),requests.capture());
        assertEquals("MASS",requests.getAllValues().get(0).getMeasurementDimension());assertEquals("KG",requests.getAllValues().get(0).getMassUnitCode());
        assertEquals("COUNT",requests.getAllValues().get(1).getMeasurementDimension());assertNull(requests.getAllValues().get(1).getMassUnitCode());
    }
    @Test void decimalStringsCompareExactlyAndUnchangedPrecisionStaysInJava() {
        BigDecimal exact=new BigDecimal("123456789012.123456");
        when(currencies.detail(id)).thenReturn(new CurrencyDetail(id,"B01","original",exact,false,"使用",null));
        service.patch("currencies",id,Map.of("name","original"),Map.of("name","changed"));
        var request=ArgumentCaptor.forClass(CurrencySaveRequest.class);verify(currencies).update(eq(id),request.capture());
        assertEquals(exact,request.getValue().getExchangeRate());
        service.patch("currencies",id,Map.of("exchangeRate",exact.toPlainString()),Map.of("exchangeRate","1.230000"));
        verify(currencies).update(eq(id),argThat(value->value.getExchangeRate().compareTo(new BigDecimal("1.23"))==0));
    }
    @Test void clientVersionedPatchPreservesExactFinancialBaselineAndLearnedPresenceFields() throws Exception {
        BigDecimal exact=new BigDecimal("99999999999999.9999");
        ClientDetail detail=dto(ClientDetail.class,Map.of("id",id,"categoryId",UUID.randomUUID(),"code","CL01","name","original","status","使用","version",7L,"writable",true,"credit",exact,"initTotal",exact,"nameEn","learned name"));
        when(clients.detail(id)).thenReturn(detail);
        service.patch("clients",id,Map.of("version",7),Map.of("name","changed"));
        var request=ArgumentCaptor.forClass(ClientSaveRequest.class);verify(clients).update(eq(id),request.capture());
        assertEquals(exact,request.getValue().getCredit());assertEquals(exact,request.getValue().getInitTotal());assertEquals(7L,request.getValue().getVersion());
        assertFalse(request.getValue().hasNameEn());assertFalse(request.getValue().hasOwnerEmployeeReference());
        assertFalse(request.getValue().hasDefaultCurrencyReference());assertFalse(request.getValue().hasDefaultSettlementMethodReference());
        assertFalse(request.getValue().hasDefaultShipmentPolicy());verify(em).clear();
    }
    @Test void supplierVersionedPatchPreservesExactOpeningAndOmitsUntouchedDefaultTerms() throws Exception {
        BigDecimal exact=new BigDecimal("99999999999999.9999");
        SupplierDetail detail=dto(SupplierDetail.class,Map.of("id",id,"categoryId",UUID.randomUUID(),"code","SP01","name","original","status","使用","version",9L,"initTotal",exact,"defaultTaxRate",new BigDecimal("0.1234")));
        when(suppliers.detail(id)).thenReturn(detail);
        service.patch("suppliers",id,Map.of("version",9),Map.of("name","changed"));
        var request=ArgumentCaptor.forClass(SupplierSaveRequest.class);verify(suppliers).update(eq(id),request.capture());
        assertEquals(exact,request.getValue().getInitTotal());assertNull(request.getValue().getDefaultTaxRate());
        assertFalse(request.getValue().hasDefaultCurrencyReference());assertFalse(request.getValue().hasDefaultSettlementMethodReference());assertFalse(request.getValue().hasOwnerEmployeeReference());
    }
    @Test void clientScopeLossAndStaleVersionDoNotReachUpdate() throws Exception {
        ClientDetail detail=dto(ClientDetail.class,Map.of("id",id,"categoryId",UUID.randomUUID(),"name","original","version",7L,"writable",false));
        when(clients.detail(id)).thenReturn(detail);
        assertThrows(ApiException.class,()->service.patch("clients",id,Map.of("version",7),Map.of("name","changed")));
        org.springframework.test.util.ReflectionTestUtils.setField(detail,"writable",true);
        assertThrows(ApiException.class,()->service.patch("clients",id,Map.of("version",6),Map.of("name","changed")));
        verify(clients,never()).update(any(),any());
    }
    @Test void warehousePatchPreservesCurrentFormValuesAndOmitsUnchangedWorkshopReference() throws Exception {
        UUID workshop=UUID.randomUUID();
        when(warehouses.detail(id)).thenReturn(dto(WarehouseDetail.class,Map.of(
            "id",id,"code","WH01","name","五金仓","location","东侧","remark","原备注",
            "status","使用","accountable",true,"defective",false,"workshopDepartmentId",workshop)));
        service.patch("warehouses",id,Map.of("name","五金仓"),Map.of("name","五金备件仓"));
        var request=ArgumentCaptor.forClass(WarehouseSaveRequest.class);verify(warehouses).update(eq(id),request.capture());
        var saved=request.getValue();
        assertEquals("五金备件仓",saved.getName());assertEquals("WH01",saved.getCode());
        assertEquals("东侧",saved.getLocation());assertEquals("原备注",saved.getRemark());
        assertEquals("使用",saved.getStatus());assertTrue(saved.getAccountable());assertFalse(saved.getDefective());
        assertFalse(saved.hasWorkshopDepartmentReference());assertFalse(saved.hasParentReference());assertNull(saved.getIsLineSide());
    }
    @Test void warehouseBooleanCasAndExplicitNullWorkshopArePassedToAuthoritativeUpdate() throws Exception {
        UUID workshop=UUID.randomUUID();
        when(warehouses.detail(id)).thenReturn(dto(WarehouseDetail.class,Map.of(
            "id",id,"code","WH01","name","五金仓","status","使用","accountable",true,
            "defective",false,"workshopDepartmentId",workshop)));
        Map<String,Object> changes=new HashMap<>();changes.put("accountable",false);changes.put("workshopDepartmentId",null);
        service.patch("warehouses",id,Map.of("accountable",true,"workshopDepartmentId",workshop.toString()),changes);
        var request=ArgumentCaptor.forClass(WarehouseSaveRequest.class);verify(warehouses).update(eq(id),request.capture());
        assertFalse(request.getValue().getAccountable());
        assertTrue(request.getValue().hasWorkshopDepartmentReference());assertNull(request.getValue().getWorkshopDepartmentId());
    }
    @Test void warehouseStaleBooleanOrTextBooleanBaselineCannotOverwriteCurrentValue() throws Exception {
        when(warehouses.detail(id)).thenReturn(dto(WarehouseDetail.class,Map.of("id",id,"name","仓库","accountable",true)));
        for(Object expected:List.of(false,"true")) {
            ApiException error=assertThrows(ApiException.class,()->service.patch("warehouses",id,
                Map.of("accountable",expected),Map.of("accountable",false)));
            assertEquals(ErrorCode.CONFLICT,error.getCode());
        }
        verify(warehouses,never()).update(any(),any());
    }
    @Test void warehouseIdentityAndMissingExpectedAreRejectedBeforeLocking() {
        for(String key:List.of("code","parentId","isLineSide","lineSide","legacyId","selectableForNew")) {
            assertThrows(ApiException.class,()->service.patch("warehouses",id,Map.of(key,"old"),Map.of(key,"new")));
        }
        assertThrows(ApiException.class,()->service.patch("warehouses",id,Map.of(),Map.of("name","changed")));
        verifyNoInteractions(warehouses,em);
    }
    @Test void warehouseServiceLifecycleRefusalIsNotBypassedByThePatchAdapter() throws Exception {
        when(warehouses.detail(id)).thenReturn(dto(WarehouseDetail.class,Map.of("id",id,"name","内料仓","lineSide",true)));
        var refusal=new ApiException(ErrorCode.VALIDATION_FAILED,"车间内料仓这里只读");
        when(warehouses.update(eq(id),any())).thenThrow(refusal);
        assertSame(refusal,assertThrows(ApiException.class,()->service.patch("warehouses",id,
            Map.of("name","内料仓"),Map.of("name","changed"))));
    }
    @Test void warehousePatchRequiresBothViewAndEditBeforeLocking() {
        for(Set<String> permissions:List.of(Set.of("warehouse:view"),Set.of("warehouse:edit"))) {
            var user=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"warehouse-test",permissions,false,true,false);
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));
            ApiException error=assertThrows(ApiException.class,()->service.patch("warehouses",id,
                Map.of("name","old"),Map.of("name","changed")));
            assertEquals(ErrorCode.FORBIDDEN,error.getCode());
        }
        verifyNoInteractions(warehouses,em);
    }
    @SuppressWarnings("unchecked") private static <T>T dto(Class<T> type,Map<String,Object> fields) throws Exception {
        var constructor=type.getConstructors()[0];
        Object[] args=Arrays.stream(constructor.getParameterTypes()).map(t->t==boolean.class?Boolean.FALSE:null).toArray();
        T value=(T)constructor.newInstance(args);fields.forEach((key,field)->org.springframework.test.util.ReflectionTestUtils.setField(value,key,field));return value;
    }
}
