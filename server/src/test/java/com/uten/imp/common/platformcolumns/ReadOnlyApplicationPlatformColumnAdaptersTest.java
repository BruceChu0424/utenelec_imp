package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.PurchasePlatformColumnAdapters;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.request.dto.RequestDetail;
import com.uten.imp.features.purchase.request.dto.RequestItemDto;
import com.uten.imp.features.subcontract.SubcontractPlatformColumnAdapters;
import com.uten.imp.features.subcontract.application.SubcontractApplicationService;
import com.uten.imp.features.subcontract.application.dto.ApplicationDetail;
import com.uten.imp.features.subcontract.application.dto.ApplicationItemDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

import java.math.BigDecimal;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Exercises the actual four domain registrations, including apparently editable legacy details. */
class ReadOnlyApplicationPlatformColumnAdaptersTest {
    private final EntityManager em = mock(EntityManager.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final PurchaseRequestService requests = mock(PurchaseRequestService.class);
    private final SubcontractApplicationService applications = mock(SubcontractApplicationService.class);
    private final ObjectMapper json = new ObjectMapper();
    private final UUID document = UUID.randomUUID(), line = UUID.randomUUID();

    enum Resource {
        PURCHASE_HEADER("purchase_request", false), PURCHASE_ITEM("purchase_request", true),
        SUBCONTRACT_HEADER("subcontract_application", false), SUBCONTRACT_ITEM("subcontract_application", true);

        final String authority;
        final boolean item;
        Resource(String authority, boolean item) { this.authority = authority; this.item = item; }
        boolean purchase() { return authority.equals("purchase_request"); }
    }

    @ParameterizedTest
    @EnumSource(Resource.class)
    void retiredPermissionsAndSuperAdminNeverAuthorizeGenericWritesOrCreates(Resource resource) {
        var adapter = adapter(resource);
        for (boolean superAdmin : List.of(false, true)) {
            login(superAdmin, resource.authority + ":view", resource.authority + ":edit",
                    resource.authority + ":create", "finance:view:all", "purchase_order:decompose");
            assertThat(adapter.canWrite()).as("%s superAdmin=%s", resource, superAdmin).isFalse();
            assertThat(adapter.canCreate()).isFalse();
            forbidden(() -> adapter.requireDefinitionAccess(true));
            forbidden(() -> adapter.requireDocumentSaveAccess(false));
            forbidden(() -> adapter.requireDocumentSaveAccess(true));
            forbidden(() -> adapter.requireDocumentFieldWrite(document));
            forbidden(() -> adapter.authorize(ids(resource), true));
            // Even genuine create-lineage evidence cannot invent a retired create authority.
            try (var ignored = PlatformColumnSaveLineage.begin(Set.of())) {
                PlatformColumnSaveLineage.recordPersisted(document);
                PlatformColumnSaveLineage.recordPersisted(line);
                forbidden(() -> adapter.authorizeCreated(ids(resource)));
            }
        }
        verifyNoInteractions(em, requests, applications);
    }

    @ParameterizedTest
    @EnumSource(Resource.class)
    void existingReadAuthorityStillLoadsTheDomainDetailAndMasksFinancialFacts(Resource resource) {
        login(false, resource.authority + ":view");
        prepareDetail(resource);
        var adapter = adapter(resource);
        assertThatCode(() -> adapter.requireDefinitionAccess(false)).doesNotThrowAnyException();
        var access = adapter.authorize(ids(resource), false).get(recordId(resource));
        assertThat(access.canWrite()).isFalse();
        assertThat(access.priceVisible()).isFalse();
        factsEqual(access.facts(), resource.item
                ? Map.of("qty", money("3"), "weight", money("4")) : Map.of());
        verifyDomainRead(resource);
        verify(em, never()).flush();
    }

    @ParameterizedTest
    @EnumSource(Resource.class)
    void financeReadersKeepExactExistingAmountsWithoutAcquiringWriteRights(Resource resource) {
        login(false, resource.authority + ":view", "finance:view:all");
        prepareDetail(resource);
        var adapter = adapter(resource);
        var access = adapter.authorize(ids(resource), false).get(recordId(resource));
        assertThat(access.canWrite()).isFalse();
        assertThat(adapter.canCreate()).isFalse();
        assertThat(access.priceVisible()).isTrue();
        factsEqual(access.facts(), resource.item
                ? Map.of("qty", money("3"), "weight", money("4"), "price", money("30"),
                        "amountOriginal", money("90"), "amountLocal", money("100"))
                : Map.of("totalOriginal", money("90"), "totalLocal", money("100")));
        verifyDomainRead(resource);
    }

    @ParameterizedTest
    @EnumSource(Resource.class)
    void missingReadAuthorityStillRejectsBeforeAnyRowLookup(Resource resource) {
        login(true, resource.authority + ":edit", resource.authority + ":create", "finance:view:all");
        var adapter = adapter(resource);
        forbidden(() -> adapter.requireDefinitionAccess(false));
        forbidden(() -> adapter.authorize(ids(resource), false));
        verifyNoInteractions(em, requests, applications);
    }

    @ParameterizedTest
    @EnumSource(Resource.class)
    void recordVisibilityStillComesFromTheOriginalDomainService(Resource resource) {
        login(false, resource.authority + ":view", "finance:view:all");
        prepareDetail(resource);
        ApiException hidden = new ApiException(ErrorCode.NOT_FOUND);
        if (resource.purchase()) when(requests.detail(document)).thenThrow(hidden);
        else when(applications.detail(document)).thenThrow(hidden);
        assertThatThrownBy(() -> adapter(resource).authorize(ids(resource), false)).isSameAs(hidden);
        verifyDomainRead(resource);
    }

    private PlatformColumnResourceAdapter adapter(Resource resource) {
        // Other document services are not involved in these four registrations.
        if (resource.purchase()) {
            var factory = new PurchasePlatformColumnAdapters(em, json, current, null, requests, null, null, null);
            return resource.item ? factory.purchaserequestItemPlatformColumns() : factory.purchaserequestHeaderPlatformColumns();
        }
        var factory = new SubcontractPlatformColumnAdapters(em, json, current, null, applications,
                null, null, null, null, null, null, null);
        return resource.item ? factory.subcontractapplicationItemPlatformColumns() : factory.subcontractapplicationHeaderPlatformColumns();
    }

    private void prepareDetail(Resource resource) {
        if (resource.item) {
            Query query = mock(Query.class);
            when(em.createNativeQuery(anyString())).thenReturn(query);
            when(query.setParameter("ids", ids(resource))).thenReturn(query);
            when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{line, document}));
        }
        if (resource.purchase()) {
            var item = new RequestItemDto(line, 1, null, null, null, null, null, null, null, BigDecimal.ONE,
                    money("3"), money("30"), money("90"), money("100"), BigDecimal.ZERO, BigDecimal.ZERO,
                    money("4"), null, null, null, null, null, BigDecimal.ZERO, money("3"));
            when(requests.detail(document)).thenReturn(new RequestDetail(document, null, "PR-test", null,
                    null, null, null, null, null, null, null, money("90"), money("100"), (short) 0, false,
                    null, List.of(item), null, null, false, true, true, true, null, null));
        } else {
            var item = new ApplicationItemDto(line, 1, null, null, null, null, null, null, null, BigDecimal.ONE,
                    money("3"), money("30"), money("90"), money("100"), BigDecimal.ZERO, money("4"), null, null);
            when(applications.detail(document)).thenReturn(new ApplicationDetail(document, null, "SC-test", null,
                    null, null, null, null, null, null, null, money("90"), money("100"), (short) 0, false,
                    null, List.of(item), null, null, false, true, true, true, null));
        }
    }

    private void verifyDomainRead(Resource resource) {
        if (resource.purchase()) verify(requests).detail(document);
        else verify(applications).detail(document);
    }
    private UUID recordId(Resource resource) { return resource.item ? line : document; }
    private Set<UUID> ids(Resource resource) { return Set.of(recordId(resource)); }
    private void login(boolean superAdmin, String... rights) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "reader",
                Set.of(rights), false, true, superAdmin)));
    }
    private static void forbidden(Runnable action) {
        assertThatThrownBy(action::run).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }
    private static void factsEqual(Map<String, BigDecimal> actual, Map<String, BigDecimal> expected) {
        assertThat(actual.keySet()).containsExactlyInAnyOrderElementsOf(expected.keySet());
        expected.forEach((name, value) -> assertThat(actual.get(name)).as(name).isEqualByComparingTo(value));
    }
    private static BigDecimal money(String value) { return new BigDecimal(value); }
}
