package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.org.employee.dto.BusinessEmployeeReference;
import org.junit.jupiter.api.Test;
import java.util.Arrays;
import java.util.Set;
import java.util.stream.Collectors;
import static org.junit.jupiter.api.Assertions.*;

class BusinessEmployeeReferencePurposeTest {
    @Test void warehouseReferenceDoesNotTurnReadScopeOrHrViewIntoAnOperatingCapability() {
        var purpose=BusinessEmployeeReferencePurpose.WAREHOUSE_ARRIVAL_RECEIVER;
        assertFalse(purpose.mayListCandidates(Set.of("warehouse_inbound:view","warehouse_task:view:all","employee:view")));
        assertTrue(purpose.mayEcho(Set.of("warehouse_inbound:view")));
        assertTrue(purpose.mayListCandidates(Set.of("warehouse_inbound:view","warehouse_inbound:stock_in")));
    }
    @Test void createAndEditAreAlternativesButUnrelatedWritesAreNot() {
        var purpose=BusinessEmployeeReferencePurpose.PURCHASE_ORDER_PERSON;
        assertTrue(purpose.mayListCandidates(Set.of("purchase_order:create")));
        assertTrue(purpose.mayListCandidates(Set.of("purchase_order:edit")));
        assertFalse(purpose.mayListCandidates(Set.of("purchase_return:edit","purchase_order:view")));
        assertTrue(purpose.mayEcho(Set.of("purchase_order:view")));
    }
    @Test void readonlyGeneratedAndRetiredDocumentsNeverRegainCandidateWrites() {
        for(var name:Set.of("PURCHASE_REQUEST_PERSON","SUBCONTRACT_APPLICATION_PERSON","SUBCONTRACT_INQUIRY_PERSON")) {
            var purpose=BusinessEmployeeReferencePurpose.parse(name);
            assertTrue(purpose.candidateAuthorityGroups().isEmpty());
            assertFalse(purpose.mayListCandidates(Set.of("purchase_request:create","subcontract_application:edit","subcontract_inquiry:create")));
            assertTrue(purpose.mayEcho(purpose.echoAuthorities()));
        }
    }
    @Test void generatedSubcontractIssueUsesOnlyItsRemainingEditAuthority() {
        var purpose=BusinessEmployeeReferencePurpose.SUBCONTRACT_MATERIAL_ISSUE_PERSON;
        assertTrue(purpose.mayListCandidates(Set.of("subcontract_material_issue:edit")));
        assertFalse(purpose.mayListCandidates(Set.of("subcontract_material_issue:create")));
        assertFalse(purpose.mayListCandidates(Set.of("subcontract_material_issue:view","employee:view")));
        assertTrue(purpose.mayEcho(Set.of("subcontract_material_issue:view")));
    }
    @Test void materialGenerationKeepsItsAndGateAndActualAlternativeActions() {
        var purpose=BusinessEmployeeReferencePurpose.PRODUCTION_MATERIAL_OWNER;
        assertFalse(purpose.mayListCandidates(Set.of("production_material_analysis:generate")));
        assertTrue(purpose.mayListCandidates(Set.of("production_material_analysis:view","production_material_analysis:generate")));
        assertTrue(purpose.mayListCandidates(Set.of("production_material_analysis:view","production_material_analysis:notify")));
        assertFalse(purpose.mayListCandidates(Set.of("production_plan:edit")));
    }
    @Test void categoryCustodianManagerAndReadFilterKeepTheirDifferentOwningActions() {
        assertTrue(BusinessEmployeeReferencePurpose.MOULD_CUSTODIAN.mayListCandidates(Set.of("mould_category:edit")));
        assertFalse(BusinessEmployeeReferencePurpose.MOULD_CUSTODIAN.mayListCandidates(Set.of("mould:edit")));
        assertTrue(BusinessEmployeeReferencePurpose.DEPARTMENT_MANAGER.mayListCandidates(Set.of("department:manager_assign")));
        assertFalse(BusinessEmployeeReferencePurpose.DEPARTMENT_MANAGER.mayListCandidates(Set.of("department:edit")));
        assertTrue(BusinessEmployeeReferencePurpose.SALES_ORDER_SELLER_FILTER.mayListCandidates(Set.of("sales_order:view")));
    }
    @Test void projectionAndUnknownPurposesAreClosedContracts() {
        assertEquals(Set.of("id","code","fullName","departmentId","departmentName","positionName","status","accountStatus"),
                Arrays.stream(BusinessEmployeeReference.class.getRecordComponents()).map(java.lang.reflect.RecordComponent::getName).collect(Collectors.toSet()));
        assertEquals(34,BusinessEmployeeReferencePurpose.values().length);
        assertThrows(ApiException.class,()->BusinessEmployeeReferencePurpose.parse("ANY_WRITE"));
        assertThrows(ApiException.class,()->BusinessEmployeeReferencePurpose.parse(null));
    }
}
