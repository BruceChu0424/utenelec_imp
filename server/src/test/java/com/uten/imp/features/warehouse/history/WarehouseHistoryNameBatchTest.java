package com.uten.imp.features.warehouse.history;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.util.EmployeeNameResolver;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Every warehouse history source uses the same bounded name projection and row-specific fallback. */
class WarehouseHistoryNameBatchTest {
    private final EntityManager em = mock(EntityManager.class);
    private final EmployeeNameResolver names = mock(EmployeeNameResolver.class);
    private final WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
    private final WarehouseHistoryQueryService service = new WarehouseHistoryQueryService(em, names, scopes);

    @ParameterizedTest @EnumSource(WarehouseHistoryType.class)
    void currentAndFrozenNamesRemainCorrectForAllHistoricalDocumentKinds(WarehouseHistoryType type) {
        UUID known = UUID.randomUUID(), unknown = UUID.randomUUID();
        Object[] first = row(known, unknown, "旧制单名", "第一行审核快照");
        Object[] second = row(null, unknown, "独立历史制单人", "第二行审核快照");
        stubPage(List.of(first, second), 2);
        when(names.namesOf(anyCollection())).thenReturn(Map.of(known, " 当前姓名 "));

        var result = service.list(type, "", null, null, null, 1, 20);

        verify(names).namesOf(Arrays.asList(known, unknown, null, unknown));
        verify(names, never()).nameOf(any());
        assertThat(result.getItems()).extracting(WarehouseHistoryListItem::makerName)
                .containsExactly("当前姓名", "独立历史制单人");
        // A missing id's first fallback must not become a page cache entry for another row.
        assertThat(result.getItems()).extracting(WarehouseHistoryListItem::approverName)
                .containsExactly("第一行审核快照", "第二行审核快照");
        assertThat(result.getItems()).extracting(WarehouseHistoryListItem::id)
                .containsExactly((UUID) first[0], (UUID) second[0]);
        assertThat(result.getItems()).allSatisfy(item -> {
            assertThat(item.type()).isEqualTo(type.pathSegment());
            assertThat(item.sourceDocumentNo()).isEqualTo("0001. 原文来源");
            assertThat(item.status()).isEqualTo((short) 1);
        });
        assertThat(result.getTotal()).isEqualTo(2);
    }

    @Test void emptyPageAndRowsWithoutIdentitiesNeverFallBackToScalarLookups() {
        stubPage(List.of(), 0);
        assertThat(service.list(WarehouseHistoryType.PURCHASE_RECEIPT, "", null, null, null, 1, 20).getItems()).isEmpty();
        verifyNoInteractions(names);
    }

    @Test void blankCurrentNameUsesItsOwnSnapshotAndNullIdsKeepNullWhenNoSnapshotExists() {
        UUID blank = UUID.randomUUID();
        stubPage(java.util.Collections.singletonList(row(blank, null, " 冻结原名 ", "  ")), 1);
        when(names.namesOf(anyCollection())).thenReturn(Map.of(blank, "  "));
        var item = service.list(WarehouseHistoryType.SUBCONTRACT_WASTE, "", null, null, null, 1, 20).getItems().getFirst();
        assertThat(item.makerName()).isEqualTo("冻结原名");
        assertThat(item.approverName()).isNull();
        verify(names, never()).nameOf(any());
    }

    @Test void namesAreReadAgainAfterScopeChangesAndNoOutsidePageIdentityIsRequested() {
        UUID ownerA = UUID.randomUUID(), ownerB = UUID.randomUUID();
        Query count = query(), rows = query();
        when(scopes.current(null)).thenReturn(WarehouseTaskScope.ALL);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> call.<String>getArgument(0).startsWith("SELECT COUNT(*)") ? count : rows);
        when(count.getSingleResult()).thenReturn(1L);
        when(rows.getResultList()).thenReturn(java.util.Collections.singletonList(row(ownerA, null, null, null)),
                java.util.Collections.singletonList(row(ownerB, null, null, null)),
                java.util.Collections.singletonList(row(ownerA, null, null, null)));
        when(names.namesOf(anyCollection())).thenReturn(Map.of(ownerA, "A"), Map.of(ownerB, "B"), Map.of(ownerA, "A2"));
        for (String expected : List.of("A", "B", "A2")) {
            assertThat(service.list(WarehouseHistoryType.SUBCONTRACT_RETURN, "", null, null, null, 1, 20)
                    .getItems().getFirst().makerName()).isEqualTo(expected);
        }
        verify(names, times(2)).namesOf(Arrays.asList(ownerA, null));
        verify(names).namesOf(Arrays.asList(ownerB, null));
    }

    private void stubPage(List<Object[]> page, long total) {
        Query count = query(), rows = query();
        when(scopes.current(null)).thenReturn(WarehouseTaskScope.ALL);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> call.<String>getArgument(0).startsWith("SELECT COUNT(*)") ? count : rows);
        when(count.getSingleResult()).thenReturn(total);
        when(rows.getResultList()).thenReturn(page);
    }
    private static Query query() { return mock(Query.class, RETURNS_SELF); }
    private static Object[] row(UUID maker, UUID approver, String makerName, String approverName) {
        return new Object[]{UUID.randomUUID(), "HISTORY", LocalDate.of(2026, 1, 1), null, "供应商", null, "仓库",
                (short) 1, true, "0001. 原文来源", maker, approver, makerName, approverName, "备注", 1L};
    }
}
