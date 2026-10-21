package com.uten.imp.common.columns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class BusinessColumnDeletionServiceTest {
    private final EntityManager em = mock(EntityManager.class);
    private final SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
    private final BusinessColumnService service = new BusinessColumnService(em, user, new ObjectMapper());
    private final UUID actor = UUID.randomUUID(), id = UUID.randomUUID();

    @Test void creatorCanRemoveCatalogEntryWithoutChangingDefinitionsOrSnapshots() {
        authenticate(false, "sales_order:edit");
        Query select = rows("TEXT", "NONE", actor);
        Query insert = query();
        when(em.createNativeQuery(contains("INSERT INTO business_column_deletions"))).thenReturn(insert);
        service.delete("sales_order", id);
        verify(select).setParameter("scope", "sales_order");
        verify(insert).setParameter("actor", actor);
        verify(insert).executeUpdate();
        verify(em, never()).createNativeQuery(startsWith("DELETE FROM business_column_definitions"));
        verify(em, never()).createNativeQuery(contains("extra_columns"));
    }

    @Test void evenAdministratorCannotDeleteAnotherCreatorsDefinitionOrAnOwnerlessDefinition() {
        authenticate(true);
        for (UUID owner : new UUID[]{UUID.randomUUID(), null}) {
            rows("TEXT", "NONE", owner);
            assertThatThrownBy(() -> service.delete("sales_order", id))
                    .isInstanceOf(ApiException.class).hasMessageContaining("自己创建")
                    .satisfies(e -> assertThat(((ApiException) e).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        }
        verify(em, never()).createNativeQuery(contains("INSERT INTO business_column_deletions"));
    }

    @Test void readOnlyAndVisitorAccountsCannotDeleteEvenTheirOwnDefinition() {
        authenticate(false, "sales_order:view");
        assertThatThrownBy(() -> service.delete("sales_order", id)).isInstanceOf(ApiException.class);
        when(user.get()).thenReturn(Optional.of(AuthUser.visitor(actor, "visitor", "V001", Set.of("sales_order:edit"))));
        assertThatThrownBy(() -> service.delete("sales_order", id)).isInstanceOf(ApiException.class);
        verifyNoInteractions(em);
    }

    @Test void creatorStillNeedsCurrentPricePermissionForFinancialColumn() {
        authenticate(false, "sales_order:edit");
        rows("AMOUNT", "ADD", actor);
        assertThatThrownBy(() -> service.delete("sales_order", id))
                .isInstanceOf(ApiException.class).hasMessageContaining("价格权限");
        verify(em, never()).createNativeQuery(contains("INSERT INTO business_column_deletions"));
    }

    @Test void wrongScopeOrMissingDefinitionCannotBeDeleted() {
        authenticate(false, "purchase_order:edit");
        Query select = query();
        when(select.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(contains("FOR UPDATE"))).thenReturn(select);
        assertThatThrownBy(() -> service.delete("purchase_order", id))
                .isInstanceOf(ApiException.class)
                .satisfies(e -> assertThat(((ApiException) e).getCode()).isEqualTo(ErrorCode.NOT_FOUND));
        verify(select).setParameter("scope", "purchase_order");
    }

    @Test void searchGrantsDeleteOnlyForCreatorWithCurrentWriteAndPriceAuthority() {
        authenticate(false, "sales_order:edit");
        Query search = query();
        when(search.getResultList()).thenReturn(List.of(
                row("TEXT", "NONE", actor), row("TEXT", "NONE", UUID.randomUUID()), row("AMOUNT", "ADD", actor)));
        when(em.createNativeQuery(contains("NOT EXISTS"))).thenReturn(search);
        assertThat(service.search("sales_order", "")).extracting(BusinessColumnService.Definition::canDelete)
                .containsExactlyInAnyOrder(true, false, false);
        authenticate(false, "sales_order:view");
        assertThat(service.search("sales_order", "")).allSatisfy(d -> assertThat(d.canDelete()).isFalse());
    }

    @Test void recreatingDeletedDefinitionRestoresOnlyTheCreatorsExistingIdentity() {
        authenticate(false, "sales_order:edit");
        Query insert = query(), select = query(), deleted = query(), restore = query();
        when(em.createNativeQuery(contains("INSERT INTO business_column_definitions"))).thenReturn(insert);
        when(em.createNativeQuery(contains("FOR UPDATE"))).thenReturn(select);
        when(em.createNativeQuery(startsWith("SELECT column_id"))).thenReturn(deleted);
        when(em.createNativeQuery(startsWith("DELETE FROM business_column_deletions"))).thenReturn(restore);
        when(select.getSingleResult()).thenReturn(row("TEXT", "NONE", actor));
        when(deleted.getResultList()).thenReturn(List.of(id));
        var input = new BusinessColumnService.Create("sales_order", "备注列", "TEXT", "NONE");
        assertThat(service.create(input).id()).isEqualTo(id);
        verify(restore).executeUpdate();
        when(select.getSingleResult()).thenReturn(row("TEXT", "NONE", UUID.randomUUID()));
        assertThatThrownBy(() -> service.create(input)).isInstanceOf(ApiException.class)
                .satisfies(e -> assertThat(((ApiException) e).getCode()).isEqualTo(ErrorCode.CONFLICT));
        verify(restore, times(1)).executeUpdate();
    }

    private void authenticate(boolean administrator, String... permissions) {
        when(user.get()).thenReturn(Optional.of(new AuthUser(actor, UUID.randomUUID(), "creator",
                Set.of(permissions), false, true, administrator)));
        when(user.id()).thenReturn(Optional.of(actor));
        when(user.requireId()).thenReturn(actor);
    }
    private Object[] row(String type, String operation, UUID creator) {
        return new Object[]{id, "sales_order", "备注列", type, operation, 0L, creator};
    }
    private Query rows(String type, String operation, UUID creator) {
        Query select = query();
        when(select.getResultList()).thenReturn(java.util.Collections.singletonList(row(type, operation, creator)));
        when(em.createNativeQuery(contains("FOR UPDATE"))).thenReturn(select);
        return select;
    }
    private Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }
}
