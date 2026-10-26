package com.uten.imp.security;

import com.uten.imp.application.port.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class NativeReadScopeVersionAuthorityTest {
    final UUID actor=UUID.randomUUID(),employee=UUID.randomUUID(),other=UUID.randomUUID(),warehouse=UUID.randomUUID();
    final NamedParameterJdbcTemplate jdbc=mock(NamedParameterJdbcTemplate.class);
    final SubmitterPrincipalRestorer restorer=mock(SubmitterPrincipalRestorer.class);
    final OwnerVisibility owners=mock(OwnerVisibility.class);
    final ReadScopeVersionAuthority authority=new ReadScopeVersionAuthority(jdbc,restorer,owners);
    AuthUser subject;
    @BeforeEach void setup(){
        subject=user(false,Set.of("production_quality_inspection:view","production_quality_inspection:approve","subcontract_short_delivery:view"));
        when(restorer.currentStamps(actor)).thenReturn(Optional.of(new SubmitterPrincipalRestorer.AuthorizationStamps(1,7)));
        when(restorer.restore(actor,1,7L)).thenAnswer(call->subject);
        when(jdbc.queryForObject(anyString(),anyMap(),eq(Long.class))).thenReturn(0L);
        when(jdbc.queryForObject(contains("business_dataset_id"),anyMap(),any(org.springframework.jdbc.core.RowMapper.class)))
                .thenReturn(new ReadScopeVersionAuthority.DatasetRealm(UUID.fromString("00000000-0000-0000-0000-000000000935"),0));
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    AuthUser user(boolean admin,Set<String> permissions){return new AuthUser(actor,employee,"native-reader",permissions,false,true,admin);}
    @SuppressWarnings("unchecked") <T> void port(String field,T value){ObjectProvider<T> provider=mock(ObjectProvider.class);when(provider.getIfAvailable()).thenReturn(value);ReflectionTestUtils.setField(authority,field,provider);}

    @Test void nativeModeProbeAlsoRequiresANewReadOnlyRepeatableSnapshot() throws Exception {
        var tx=ReadScopeVersionAuthority.class.getMethod("scopeFor",String.class,AuthUser.class,boolean.class)
                .getAnnotation(org.springframework.transaction.annotation.Transactional.class);
        assertThat(tx.readOnly()).isTrue();
        assertThat(tx.propagation()).isEqualTo(org.springframework.transaction.annotation.Propagation.REQUIRES_NEW);
        assertThat(tx.isolation()).isEqualTo(org.springframework.transaction.annotation.Isolation.REPEATABLE_READ);
    }

    @Test void companyAndStockReportProfilesDoNotAcquireOwnerOrKeeperRestrictions(){
        assertThat(authority.scopeFor("native_feature",subject,false)).matches("[0-9a-f]{64}");
        assertThat(authority.scopeFor("stock",subject)).matches("[0-9a-f]{64}");
        verifyNoInteractions(owners);
    }
    @Test void nativeOwnersUseTheOriginalFeaturePortsAndSalesLedger(){
        var subcontract=mock(SubcontractDocumentReadAccessPort.class);port("subcontractAccess",subcontract);
        when(subcontract.scope()).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(employee)));
        String before=authority.scopeFor("native_subcontract_owner",subject,false);
        when(subcontract.scope()).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(employee,other)));
        assertThat(authority.scopeFor("native_subcontract_owner",subject,false)).isNotEqualTo(before);
        var production=mock(ProductionDocumentReadScopePort.class);port("productionAccess",production);
        when(production.scope()).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(employee)));
        assertThat(authority.scopeFor("native_production_owner",subject,false)).matches("[0-9a-f]{64}");
        when(owners.evaluate("sales","sales:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(employee)));
        authority.scopeFor("native_sales_owner",subject,false);
        verify(jdbc).queryForObject(anyString(),eq(Map.of("domain","sales")),eq(Long.class));
    }
    @Test void purchasePrintingUsesPurchaseOwnersWhileTheReportContractRemainsCompanyWide(){
        when(owners.evaluate("purchase","purchase:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(employee)));
        String own=authority.scopeFor("native_purchase_owner",subject,false);
        when(owners.evaluate("purchase","purchase:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(employee,other)));
        assertThat(authority.scopeFor("native_purchase_owner",subject,false)).isNotEqualTo(own);
        clearInvocations(owners);
        assertThat(authority.scopeFor("purchase",subject)).matches("[0-9a-f]{64}");verifyNoInteractions(owners);
    }
    @Test void qualityPoolRemainsCompanyWideWhileViewOnlyUsesPlanOwners(){
        var quality=mock(ProductionQualityPoolAccessPort.class);port("qualityAccess",quality);
        var production=mock(ProductionDocumentReadScopePort.class);port("productionAccess",production);
        when(quality.canAccessQualityPool()).thenReturn(true);
        String company=authority.scopeFor("native_fqc_records",subject,false);
        verifyNoInteractions(production);
        when(quality.canAccessQualityPool()).thenReturn(false);
        when(production.scope()).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(employee)));
        assertThat(authority.scopeFor("native_fqc_records",subject,false)).isNotEqualTo(company);
    }
    @Test void workshopProofUsesAssignmentDimensionsNotBusinessFiltersOrEveryHistoricalSegment(){
        var policy=mock(ProductionWorkshopReadScopePolicy.class);port("workshopAccess",policy);
        when(policy.snapshot(subject)).thenReturn(new ProductionWorkshopReadScopePolicy.Snapshot(false,employee,List.of(other)));
        String before=authority.scopeFor("native_workshop_tasks",subject,false);
        when(policy.snapshot(subject)).thenReturn(new ProductionWorkshopReadScopePolicy.Snapshot(false,null,List.of()));
        assertThat(authority.scopeFor("native_workshop_tasks",subject,false)).isNotEqualTo(before);
        verifyNoInteractions(owners);
    }
    @Test void warehouseProofAlwaysCallsFreshUniverseWithoutWindowOrSelectedWarehouse(){
        var port=mock(WarehouseTaskScopePort.class);port("warehouseAccess",port);
        when(port.freshAccess(actor,false)).thenReturn(new WarehouseTaskScopePort.WarehouseAccess(WarehouseTaskScopePort.Role.KEEPER,List.of(warehouse),
                new WarehouseTaskScopePort.WarehouseTaskScope(true,List.of(warehouse),false),false));
        String before=authority.scopeFor("native_warehouse_tasks",subject,false);
        when(port.freshAccess(actor,false)).thenReturn(new WarehouseTaskScopePort.WarehouseAccess(WarehouseTaskScopePort.Role.OTHER,List.of(),WarehouseTaskScopePort.WarehouseTaskScope.NONE,false));
        assertThat(authority.scopeFor("native_warehouse_tasks",subject,false)).isNotEqualTo(before);
        verify(port,times(2)).freshAccess(actor,false);verify(port,never()).access();verify(port,never()).current(any());
    }
    @Test void taskProofReusesFreshActualGrantAlgorithmAndRestoresTheOriginalPrincipal(){
        subject=user(true,Set.of("production_quality_inspection:view","production_quality_inspection:approve"));
        var audience=mock(TaskAudiencePort.class);port("taskAudience",audience);
        var task=new java.util.concurrent.atomic.AtomicReference<>(user(false,Set.of("production_quality_inspection:view")));
        when(audience.freshTaskSubject(subject)).thenAnswer(call->task.get());
        var warehousePort=mock(WarehouseTaskScopePort.class);port("warehouseAccess",warehousePort);
        when(warehousePort.freshAccess(actor,true)).thenAnswer(call->{
            assertThat(SecurityContextHolder.getContext().getAuthentication().getPrincipal()).isSameAs(task.get());
            return new WarehouseTaskScopePort.WarehouseAccess(WarehouseTaskScopePort.Role.OTHER,List.of(),WarehouseTaskScopePort.WarehouseTaskScope.ALL,false);
        });
        var original=SecurityContextHolder.getContext();
        String before=authority.scopeFor("native_warehouse_tasks",subject,true);
        assertThat(SecurityContextHolder.getContext()).isSameAs(original);
        task.set(user(false,Set.of()));
        assertThat(authority.scopeFor("native_warehouse_tasks",subject,true)).isNotEqualTo(before);
        verify(audience,times(2)).freshTaskSubject(subject);
    }
}
