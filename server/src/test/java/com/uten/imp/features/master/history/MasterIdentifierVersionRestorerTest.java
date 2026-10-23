package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.mastercode.*;
import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class MasterIdentifierVersionRestorerTest {
    private final EntityManager em = mock(EntityManager.class);
    private final CategoryDrivenCodeService categories = mock(CategoryDrivenCodeService.class);
    private final MasterCodeService fixed = mock(MasterCodeService.class);
    private final MasterIdentifierAvailabilityService availability = mock(MasterIdentifierAvailabilityService.class);
    private final MasterIdentifierVersionRestorer restorer = new MasterIdentifierVersionRestorer(em, categories, fixed, availability);
    private final UUID id = UUID.randomUUID(), category = UUID.randomUUID();

    @BeforeEach void registeredHistoricalOwnership() {
        Query claim = mock(Query.class);
        when(em.createNativeQuery(contains("business_identifier_reservation_members"))).thenReturn(claim);
        when(claim.setParameter(anyString(), any())).thenReturn(claim);
        when(claim.getSingleResult()).thenReturn(true);
    }

    private ObjectNode row(String code, long sequence) {
        return new ObjectMapper().createObjectNode().put("id", id.toString()).put("code", code)
                .put("category_id", category.toString()).put("code_sequence", sequence)
                .put("code_managed", false).putNull("code_prefix_category_id");
    }

    @Test void unchangedDisplayCodeCannotRestoreOldAllocationMetadata() {
        var current = row("CUSTOM", 99);
        var historical = row(" custom ", 1).put("code_managed", true).put("code_prefix_category_id", category.toString());
        var result = restorer.prepare(List.of(new MasterVersionRow("goods", id, current, historical))).getFirst().target();
        assertEquals("CUSTOM", result.path("code").asText());
        assertEquals(99, result.path("code_sequence").asLong());
        assertFalse(result.path("code_managed").asBoolean());
        assertTrue(result.path("code_prefix_category_id").isNull());
        verifyNoInteractions(categories, fixed, availability, em);
    }

    @Test void everyCategoryDomainRebuildsFromTheCurrentSequenceAndCurrentCategory() {
        for (var entry : Map.of("goods", CategoryDrivenCodeService.MasterType.GOODS,
                "clients", CategoryDrivenCodeService.MasterType.CLIENT,
                "suppliers", CategoryDrivenCodeService.MasterType.SUPPLIER,
                "moulds", CategoryDrivenCodeService.MasterType.MOULD).entrySet()) {
            when(categories.allocateForUpdate(eq(entry.getValue()), eq(id), eq(category), eq("OLD"), any()))
                    .thenReturn(new CategoryCodeAllocation("OLD", 99, null, false));
            var result = restorer.prepare(List.of(new MasterVersionRow(entry.getKey(), id, row("NEW", 99), row("OLD", 1)))).getFirst();
            assertEquals(99, result.target().path("code_sequence").asLong());
            verify(categories).allocateForUpdate(eq(entry.getValue()), eq(id), eq(category), eq("OLD"),
                    argThat(allocation -> allocation.sequence() == 99 && allocation.code().equals("NEW")));
        }
    }

    @Test void fixedDomainsUseTheSameIdentityAndNormalSaveResolver() {
        Query root = mock(Query.class);
        when(em.createNativeQuery("SELECT fn_warehouse_root_id()")).thenReturn(root);
        when(root.getSingleResult()).thenReturn(UUID.randomUUID());
        for (var entry : Map.of("colors", MasterCodePrefix.COLOR, "units", MasterCodePrefix.UNIT,
                "currencies", MasterCodePrefix.CURRENCY, "accounts", MasterCodePrefix.ACCOUNT,
                "warehouses", MasterCodePrefix.WAREHOUSE).entrySet()) {
            when(fixed.resolveMutableCode(entry.getValue(), "OLD", id, "NEW")).thenReturn("OLD");
            var result = restorer.prepare(List.of(new MasterVersionRow(entry.getKey(), id, row("NEW", 99), row("OLD", 1)))).getFirst();
            assertEquals("OLD", result.target().path("code").asText());
            assertEquals(99, result.target().path("code_sequence").asLong());
            verify(fixed).resolveMutableCode(entry.getValue(), "OLD", id, "NEW");
        }
    }

    @Test void warehouseRolesAndChangingCategoryCannotBeRestoredThroughNumbering() {
        assertThrows(ApiException.class, () -> restorer.prepare(List.of(new MasterVersionRow("warehouses", id,
                row("NEW", 99).put("is_line_side", true), row("OLD", 1)))));
        Query root = mock(Query.class);
        when(em.createNativeQuery("SELECT fn_warehouse_root_id()")).thenReturn(root);
        when(root.getSingleResult()).thenReturn(id);
        assertThrows(ApiException.class, () -> restorer.prepare(List.of(new MasterVersionRow("warehouses", id, row("NEW", 99), row("OLD", 1)))));
        when(root.getSingleResult()).thenReturn(UUID.randomUUID());
        assertThrows(ApiException.class, () -> restorer.prepare(List.of(new MasterVersionRow("warehouses", id, row("NEW", 99), row("001", 1)))));
        assertThrows(ApiException.class, () -> restorer.prepare(List.of(new MasterVersionRow("goods", id, row("NEW", 99),
                row("OLD", 1).put("category_id", UUID.randomUUID().toString())))));
        verifyNoInteractions(categories, fixed);
    }

    @Test void capabilityChecksDoNotClaimOrAdvanceNumbersAndSequenceLocksFailFast() {
        when(availability.check(MasterIdentifierAvailabilityService.Domain.GOODS, "OLD", id, category))
                .thenReturn(new MasterIdentifierAvailabilityService.Availability("OLD", true, null));
        assertNull(restorer.blockedReason(new MasterVersionRow("goods", id, row("NEW", 99), row("OLD", 1))));
        verifyNoInteractions(categories, fixed);
        Query lock = mock(Query.class);
        when(em.createNativeQuery(contains("FOR UPDATE NOWAIT"))).thenReturn(lock);
        when(lock.setParameter("type", "GOODS")).thenReturn(lock);
        when(lock.getResultList()).thenReturn(List.of(99L));
        restorer.lockForRestore("goods");
        verify(lock).setParameter("type", "GOODS");
    }

    @Test void aDeletedIdentityUsesOnlyTheTrustedRestoreAvailabilityAndResolver() {
        var current = row("NEW", 99).put("is_deleted", true);
        when(availability.checkForRestore(MasterIdentifierAvailabilityService.Domain.COLOR, "OLD", id, null))
                .thenReturn(new MasterIdentifierAvailabilityService.Availability("OLD", true, null));
        when(fixed.resolveMutableCodeForRestore(MasterCodePrefix.COLOR, "OLD", id, "NEW")).thenReturn("OLD");
        var version = new MasterVersionRow("colors", id, current, row("OLD", 1).put("is_deleted", false));
        assertNull(restorer.blockedReason(version));
        assertEquals("OLD", restorer.prepare(List.of(version)).getFirst().target().path("code").asText());
        verify(availability).checkForRestore(MasterIdentifierAvailabilityService.Domain.COLOR, "OLD", id, null);
        verify(fixed).resolveMutableCodeForRestore(MasterCodePrefix.COLOR, "OLD", id, "NEW");
        verify(fixed, never()).resolveMutableCode(any(), any(), any(), any());
    }

    @Test void anUnclaimedIntermediateSnapshotCannotMintANewBusinessNumber() {
        Query claim = mock(Query.class);
        when(em.createNativeQuery(contains("business_identifier_reservation_members"))).thenReturn(claim);
        when(claim.setParameter(anyString(), any())).thenReturn(claim);
        when(claim.getSingleResult()).thenReturn(false);
        var version = new MasterVersionRow("goods", id, row("REAL", 99), row("__MCB_INTERMEDIATE", 1));
        assertNotNull(restorer.blockedReason(version));
        assertThrows(ApiException.class, () -> restorer.prepare(List.of(version)));
        verifyNoInteractions(categories, fixed, availability);
    }
}
