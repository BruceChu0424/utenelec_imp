package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.annotation.*;

import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ReadScopeVersionAuthorityTest {
    private final UUID actor = UUID.randomUUID(), employee = UUID.randomUUID(), granted = UUID.randomUUID();
    private final NamedParameterJdbcTemplate jdbc = mock(NamedParameterJdbcTemplate.class);
    private final SubmitterPrincipalRestorer restorer = mock(SubmitterPrincipalRestorer.class);
    private final OwnerVisibility owners = mock(OwnerVisibility.class);
    private final ReadScopeVersionAuthority authority = new ReadScopeVersionAuthority(jdbc, restorer, owners);
    private AuthUser subject;

    @BeforeEach void setup() {
        subject = user(Set.of("sales_report:view", "sales_report:export"));
        when(restorer.currentStamps(actor)).thenReturn(Optional.of(new SubmitterPrincipalRestorer.AuthorizationStamps(1, 7)));
        lenient().when(restorer.restore(actor, 1, 7L)).thenAnswer(call -> subject);
        lenient().when(jdbc.queryForObject(anyString(), anyMap(), eq(Long.class))).thenReturn(0L);
        lenient().when(jdbc.queryForObject(contains("business_dataset_id"),anyMap(),org.mockito.ArgumentMatchers.<org.springframework.jdbc.core.RowMapper<ReadScopeVersionAuthority.DatasetRealm>>notNull()))
                .thenReturn(new ReadScopeVersionAuthority.DatasetRealm(UUID.fromString("00000000-0000-0000-0000-000000000935"),0));
    }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void costVersionsBindBothGoodsAndCustomerGenerationsAndOwnerScopes() {
        subject=user(Set.of("goods:view","goods:cost:view"));
        var goodsPolicy=mock(GoodsReadScopePolicy.class);
        when(goodsPolicy.versionedReadScope()).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(employee)));
        when(owners.evaluate("client","client:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(employee)));
        var goodsGeneration=new java.util.concurrent.atomic.AtomicLong();
        var clientGeneration=new java.util.concurrent.atomic.AtomicLong();
        when(jdbc.queryForObject(contains("read_scope_generations"),anyMap(),eq(Long.class))).thenAnswer(call->
                "client".equals(((Map<?,?>)call.getArgument(1)).get("domain"))?clientGeneration.get():goodsGeneration.get());
        var costs=new ReadScopeVersionAuthority(jdbc,restorer,owners,goodsPolicy);
        String first=costs.scopeFor("master_goods_cost",subject);
        clientGeneration.incrementAndGet();String changedClient=costs.scopeFor("master_goods_cost",subject);
        goodsGeneration.incrementAndGet();String changedGoods=costs.scopeFor("master_goods_cost",subject);
        assertThat(first).isNotEqualTo(changedClient);assertThat(changedClient).isNotEqualTo(changedGoods);
        when(owners.evaluate("client","client:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(granted)));
        assertThat(costs.scopeFor("master_goods_cost",subject)).isNotEqualTo(changedGoods);
    }
    @Test void missingCustomerGenerationCannotBorrowTheGoodsVersionForCosts() {
        when(jdbc.queryForObject(contains("read_scope_generations"),org.mockito.ArgumentMatchers.<Map<String,?>>argThat(parameters->"client".equals(parameters.get("domain"))),eq(Long.class))).thenReturn(null);
        assertThatThrownBy(()->authority.scopeFor("master_goods_cost",subject)).isInstanceOfSatisfying(ApiException.class,
                failure->assertThat(failure.getCode()).isEqualTo(ErrorCode.PRIMARY_UNAVAILABLE));
    }

    @Test void unknownOrNoncanonicalDomainCannotSelectAnAuthorizationPolicy() {
        for (String domain : Arrays.asList(null, "sales ", "SALES", "native_unknown", "sales/../stock")) {
            assertThatThrownBy(() -> authority.scopeFor(domain, subject)).isInstanceOfSatisfying(ApiException.class,
                    failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        }
        verifyNoInteractions(jdbc, restorer, owners);
    }

    @Test void independentDatasetRealmsCannotShareMetadataEvenWhenRolesOwnersAndCountersMatch() {
        UUID a=UUID.randomUUID(),b=UUID.randomUUID();
        when(jdbc.queryForObject(contains("business_dataset_id"),anyMap(),org.mockito.ArgumentMatchers.<org.springframework.jdbc.core.RowMapper<ReadScopeVersionAuthority.DatasetRealm>>notNull()))
                .thenReturn(new ReadScopeVersionAuthority.DatasetRealm(a,7),new ReadScopeVersionAuthority.DatasetRealm(b,7),
                        new ReadScopeVersionAuthority.DatasetRealm(b,8));
        String first=authority.scopeFor("stock",subject),second=authority.scopeFor("stock",subject),third=authority.scopeFor("stock",subject);
        assertThat(first).isNotEqualTo(second);assertThat(second).isNotEqualTo(third);
        verifyNoInteractions(owners);
    }
    @Test void absentOrMalformedDatasetMetadataFailsClosedInsteadOfBorrowingAnEmptyRealm() {
        for(ReadScopeVersionAuthority.DatasetRealm realm:Arrays.asList(null,new ReadScopeVersionAuthority.DatasetRealm(null,0),
                new ReadScopeVersionAuthority.DatasetRealm(UUID.randomUUID(),-1))){
            when(jdbc.queryForObject(contains("business_dataset_id"),anyMap(),org.mockito.ArgumentMatchers.<org.springframework.jdbc.core.RowMapper<ReadScopeVersionAuthority.DatasetRealm>>notNull())).thenReturn(realm);
            assertThatThrownBy(()->authority.scopeFor("stock",subject)).isInstanceOfSatisfying(ApiException.class,
                    failure->assertThat(failure.getCode()).isEqualTo(ErrorCode.PRIMARY_UNAVAILABLE));
        }
        verifyNoInteractions(restorer,owners);
    }

    @Test void canonicalizationUsesOnlyReadOwnersAndRestoresTheOriginalSecurityContext() {
        var original = SecurityContextHolder.createEmptyContext();
        original.setAuthentication(new UsernamePasswordAuthenticationToken("outer", "unused", List.of()));
        SecurityContextHolder.setContext(original);
        when(owners.evaluate("sales", "sales:view:all")).thenAnswer(call -> {
            assertThat(SecurityContextHolder.getContext().getAuthentication().getPrincipal()).isSameAs(subject);
            return new OwnerVisibility.OwnerScope(false, Set.of(employee, granted), Set.of(employee));
        });
        String first = authority.scopeFor("sales", subject);
        doReturn(new OwnerVisibility.OwnerScope(false, new LinkedHashSet<>(List.of(granted, employee)), Set.of(granted)))
                .when(owners).evaluate("sales", "sales:view:all");
        assertThat(authority.scopeFor("sales", subject)).isEqualTo(first).matches("[0-9a-f]{64}");
        assertThat(SecurityContextHolder.getContext()).isSameAs(original);
        verify(restorer, times(2)).currentStamps(actor);
    }

    @Test void committedScopeAbaCannotReviveAnEarlierStampEvenWithIdenticalRoleVersions() {
        when(jdbc.queryForObject(anyString(), anyMap(), eq(Long.class))).thenReturn(0L, 1L, 2L);
        when(owners.evaluate("sales", "sales:view:all")).thenReturn(
                new OwnerVisibility.OwnerScope(false, Set.of(employee, granted)),
                new OwnerVisibility.OwnerScope(false, Set.of(employee)),
                new OwnerVisibility.OwnerScope(false, Set.of(employee, granted)));
        String a = authority.scopeFor("sales", subject), b = authority.scopeFor("sales", subject), a2 = authority.scopeFor("sales", subject);
        assertThat(a).isNotEqualTo(b).isNotEqualTo(a2);
    }

    @Test void delegationExpiryChangesTheStampWithoutAnyDatabaseWriteOrRoleEpochChange() {
        AuthUser wide = user(Set.of("sales_report:view", "sales_report:export", "sales:view:all"));
        when(restorer.restore(actor, 1, 7L)).thenReturn(wide);
        when(owners.evaluate("sales", "sales:view:all")).thenReturn(new OwnerVisibility.OwnerScope(true, Set.of()));
        String before = authority.scopeFor("sales", wide);
        when(restorer.restore(actor, 1, 7L)).thenReturn(subject);
        when(owners.evaluate("sales", "sales:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(employee)));
        assertThat(authority.scopeFor("sales", subject)).isNotEqualTo(before);
        assertThatThrownBy(() -> authority.scopeFor("sales", wide)).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.READ_SCOPE_CHANGED));
    }

    @Test void aLegalRestrictedSubjectNeverInheritsNewlyWiderPermissionsInsideTheVersionProbe() {
        AuthUser actual = user(Set.of("sales_report:view", "sales_report:export", "sales:view:all"));
        when(restorer.restore(actor, 1, 7L)).thenReturn(actual);
        when(owners.evaluate("sales", "sales:view:all")).thenAnswer(call -> {
            AuthUser bound = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
            assertThat(bound.getPermissions()).doesNotContain("sales:view:all");
            return new OwnerVisibility.OwnerScope(false, Set.of(employee));
        });
        assertThat(authority.scopeFor("sales", subject)).matches("[0-9a-f]{64}");
    }

    @Test void employeeBindingDriftFailsBeforeCallingAnyDomainAuthority() {
        when(restorer.restore(actor, 1, 7L)).thenReturn(new AuthUser(actor, UUID.randomUUID(), "other-binding",
                subject.getPermissions(), false, true, false));
        assertThatThrownBy(() -> authority.scopeFor("sales", subject)).isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.getCode()).isEqualTo(ErrorCode.READ_SCOPE_CHANGED));
        verifyNoInteractions(owners);
    }

    @ParameterizedTest @ValueSource(strings = {"purchase", "subcontract", "production", "stock", "supplier"})
    void existingCompanyLevelContractsDoNotAcquireUnrelatedOwnerOrWarehouseRestrictions(String domain) {
        subject = user(Set.of(domain.equals("supplier") ? "supplier:view" : domain + "_report:view"));
        assertThat(authority.scopeFor(domain, subject)).matches("[0-9a-f]{64}"); verifyNoInteractions(owners);
    }

    @Test void independentFeatureFamiliesCanBeVersionedWithoutAcquiringAnotherFeaturesPermissions() throws Exception {
        subject = user(Set.of("account:view", "account:balance:view", "account:flow:view", "finance:view:all"));
        when(owners.evaluate("finance", "finance:view:all")).thenReturn(new OwnerVisibility.OwnerScope(true, Set.of()));
        assertThat(authority.scopeFor("finance", subject)).matches("[0-9a-f]{64}");
        subject = user(Set.of("production_where_used:view"));
        assertThat(authority.scopeFor("production", subject)).matches("[0-9a-f]{64}");
        String accountGuard = com.uten.imp.features.finance.report.FinanceReportController.class.getMethod("accountStatement",
                UUID.class, java.time.LocalDate.class, java.time.LocalDate.class, String.class, int.class, int.class, String.class, Map.class)
                .getAnnotation(org.springframework.security.access.prepost.PreAuthorize.class).value();
        assertThat(accountGuard).contains("account:view", "account:balance:view", "account:flow:view").doesNotContain("finance_report:view");
        String whereUsedGuard = com.uten.imp.features.production.report.ProductionReportController.class.getMethod("whereUsed",
                UUID.class, String.class, java.time.LocalDate.class, java.time.LocalDate.class, int.class, int.class, String.class, String.class)
                .getAnnotation(org.springframework.security.access.prepost.PreAuthorize.class).value();
        assertThat(whereUsedGuard).contains("production_where_used:view").doesNotContain("production_report:view", "goods:view");
    }

    @Test void thePublicProbeAlwaysStartsAFreshReadOnlyRepeatableTransaction() throws Exception {
        var tx = ReadScopeVersionAuthority.class.getMethod("scopeFor", String.class, AuthUser.class).getAnnotation(Transactional.class);
        assertThat(tx.readOnly()).isTrue(); assertThat(tx.propagation()).isEqualTo(Propagation.REQUIRES_NEW);
        assertThat(tx.isolation()).isEqualTo(Isolation.REPEATABLE_READ);
    }
    private AuthUser user(Set<String> permissions) { return new AuthUser(actor, employee, "reader", permissions, false, true, false); }
}
