package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.DepartmentNameResolver;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.test.util.ReflectionTestUtils;

import java.time.OffsetDateTime;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Isolates the actual difference projection from restore previews; PG history tests cover entry access and restoration. */
class MasterRecordHistoryReferenceBatchTest {
    private final ObjectMapper mapper = new ObjectMapper();
    private final EntityManager em = mock(EntityManager.class);
    private final ClientAccessPolicy clients = mock(ClientAccessPolicy.class);
    private final OwnerVisibility owners = mock(OwnerVisibility.class);
    private final EmployeeNameResolver employees = mock(EmployeeNameResolver.class);
    private final DepartmentNameResolver departments = mock(DepartmentNameResolver.class);
    private final MasterRecordHistoryService service = new MasterRecordHistoryService(em, mapper, null, null,
            clients, owners, null, null, Optional.empty(), Optional.empty(), null, employees, departments);

    @BeforeEach void clientScope() {
        lenient().when(clients.evaluate()).thenReturn(new ClientAccessPolicy.ClientScope(
                new OwnerVisibility.OwnerScope(true, Set.of()), Set.of(), null, false));
        lenient().when(clients.nativeReadScope(eq("ref"), any()))
                .thenReturn(new ClientAccessPolicy.NativeReadScope("TRUE", null, Set.of(), null, null));
    }

    @ParameterizedTest @CsvSource({
            "goods,component_goods_id,goods", "goods,client_id,clients", "goods,default_supplier_id,suppliers",
            "goods,color_id,colors", "goods,unit_id,units", "goods,mould_id,moulds", "goods,currency_id,currencies",
            "goods,owning_warehouse_id,warehouses", "goods,linked_account_id,accounts", "goods,style_id,payment_styles",
            "goods,default_settlement_method_id,settlement_methods", "goods,category_id,material_categories",
            "clients,category_id,client_categories", "suppliers,category_id,supplier_categories", "moulds,category_id,mould_categories"})
    void everySupportedReferenceKeepsItsLabelAndDeletedMarkerWithoutLoadingPayloads(String entity, String field, String table) throws Exception {
        UUID id = UUID.randomUUID();
        Query query = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{id, "001", "历史标签", true, null, true}));
        // Upper-case textual UUIDs still use the same canonical identity in the batch map.
        var changes = changes(user(true), List.of(fact(entity, mapper.createObjectNode(),
                mapper.createObjectNode().put(field, id.toString().toUpperCase(Locale.ROOT)))));
        assertThat(changes).hasSize(1);
        assertThat(changes.getFirst().beforeValue()).isEmpty();
        assertThat(changes.getFirst().afterValue()).isEqualTo("001 历史标签（已删除）");
        verify(query).setParameter("ids", List.of(id));
        verify(em).createNativeQuery(argThat(sql -> sql.contains("FROM " + table + " ref")
                && !sql.contains("fn_goods_history_snapshot") && !sql.contains("to_jsonb") && !sql.contains("image")));
        verifyNoInteractions(employees, departments);
    }

    @Test void threeHundredDistinctChangedReferencesUseTwoQueriesAndNeverLoadUnchangedOnes() throws Exception {
        Map<UUID, Object[]> rows = new LinkedHashMap<>(); List<Object> facts = new ArrayList<>();
        UUID unchanged = UUID.randomUUID();
        for (int i = 0; i < 300; i++) {
            UUID id = UUID.randomUUID(); rows.put(id, new Object[]{id, "C" + i, "颜色" + i, false, null, true});
            facts.add(fact("goods", mapper.createObjectNode().put("unit_id", unchanged.toString()),
                    mapper.createObjectNode().put("unit_id", unchanged.toString()).put("color_id", id.toString())));
        }
        List<Integer> batchSizes = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            Query query = mock(Query.class, RETURNS_SELF); AtomicReference<List<UUID>> batch = new AtomicReference<>();
            when(query.setParameter(eq("ids"), any())).thenAnswer(binding -> {
                List<UUID> ids = binding.getArgument(1); batch.set(ids); batchSizes.add(ids.size()); return query;
            });
            when(query.getResultList()).thenAnswer(ignored -> batch.get().stream().map(rows::get).toList());
            return query;
        });
        var result = changes(user(true), facts);
        assertThat(result).hasSize(300).allSatisfy(change -> {
            assertThat(change.field()).isEqualTo("color_id");
            assertThat(change.afterValue()).startsWith("C");
        });
        assertThat(batchSizes).containsExactly(256, 44);
        verify(em, times(2)).createNativeQuery(anyString());
    }

    @Test void clientAndGoodsObjectAuthorizationStillFiltersEachResolvedLabel() throws Exception {
        UUID readable = UUID.randomUUID(), hidden = UUID.randomUUID(), shared = UUID.randomUUID(), owner = UUID.randomUUID();
        when(clients.evaluate()).thenReturn(new ClientAccessPolicy.ClientScope(
                new OwnerVisibility.OwnerScope(false, Set.of(owner)), Set.of(shared), null, false));
        when(clients.nativeReadScope(eq("ref"), any())).thenReturn(new ClientAccessPolicy.NativeReadScope(
                "ref.owner_employee_id IN (:owners)", "owners", Set.of(owner), null, null));
        Query query = mock(Query.class, RETURNS_SELF); when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(new Object[]{readable, "A", "可读", false, owner, true},
                new Object[]{hidden, "B", "隐藏", false, UUID.randomUUID(), false},
                new Object[]{shared, "C", "分享", false, UUID.randomUUID(), false}));
        List<Object> facts = List.of(fact("goods", null, mapper.createObjectNode().put("client_id", readable.toString())),
                fact("goods", null, mapper.createObjectNode().put("client_id", hidden.toString())),
                fact("goods", null, mapper.createObjectNode().put("client_id", shared.toString())));
        assertThat(changes(user(false, "client:view"), facts)).extracting(MasterRecordHistoryService.Change::afterValue)
                .containsExactly("A 可读", "关联资料（无名称查看权限）", "C 分享");
        verify(query).setParameter("owners", Set.of(owner));
        verify(clients, never()).canRead(any(UUID.class), any(), any());

        ReflectionTestUtils.setField(service, "goodsOwnerScopeEnabled", true);
        when(owners.evaluate("goods", "goods:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(owner)));
        when(query.getResultList()).thenReturn(List.of(new Object[]{readable, "A", "本人", false, owner, true},
                new Object[]{hidden, "B", "隐藏", false, UUID.randomUUID(), true},
                new Object[]{shared, "C", "空归属", false, null, true}));
        var goodsFacts = List.of(fact("goods", null, mapper.createObjectNode().put("component_goods_id", readable.toString())),
                fact("goods", null, mapper.createObjectNode().put("component_goods_id", hidden.toString())),
                fact("goods", null, mapper.createObjectNode().put("component_goods_id", shared.toString())));
        assertThat(changes(user(false, "goods:view"), goodsFacts)).extracting(MasterRecordHistoryService.Change::afterValue)
                .containsExactly("A 本人", "关联资料（无名称查看权限）", "C 空归属");
    }

    @Test void unresolvedPeopleAndDepartmentsAreBatchedOnceAndKeepDistinctUnavailableMessages() throws Exception {
        UUID employee = UUID.randomUUID(), department = UUID.randomUUID();
        when(employees.namesWithCodeOf(anyCollection())).thenReturn(Map.of());
        when(departments.namesOf(anyCollection())).thenReturn(Map.of());
        var after = mapper.createObjectNode().put("owner_employee_id", employee.toString()).put("department_id", department.toString());
        var result = changes(user(true), List.of(fact("goods", null, after), fact("goods", null, after)));
        assertThat(result).extracting(MasterRecordHistoryService.Change::afterValue)
                .containsExactly("关联部门已删除或不可解析", "关联员工不可解析", "关联部门已删除或不可解析", "关联员工不可解析");
        verify(employees).namesWithCodeOf(List.of(employee)); verify(departments).namesOf(List.of(department));
        verifyNoInteractions(em);
    }

    @Test void revokedReferencePermissionsAndAccountCurrencyExceptionsAreOperationLocal() throws Exception {
        UUID currency = UUID.randomUUID(); Query query = mock(Query.class, RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(Collections.singletonList(new Object[]{currency, "USD", "美元", false, null, true}));
        Object goods = fact("goods", null, mapper.createObjectNode().put("currency_id", currency.toString()));
        assertThat(changes(user(false, "currency:view"), List.of(goods)).getFirst().afterValue()).isEqualTo("USD 美元");
        assertThat(changes(user(false), List.of(goods)).getFirst().afterValue()).isEqualTo("关联资料（无名称查看权限）");
        assertThat(changes(user(false, "currency:view"), List.of(goods)).getFirst().afterValue()).isEqualTo("USD 美元");
        Object account = fact("accounts", null, mapper.createObjectNode().put("currency_id", currency.toString()));
        assertThat(changes(user(false, "account:view"), List.of(account)).getFirst().afterValue()).isEqualTo("USD 美元");
        verify(em, times(3)).createNativeQuery(anyString());
    }

    @SuppressWarnings("unchecked") private List<MasterRecordHistoryService.Change> changes(AuthUser user, List<?> facts) {
        return ReflectionTestUtils.invokeMethod(service, "changes", user, facts);
    }
    private Object fact(String entity, JsonNode before, JsonNode after) throws Exception {
        Class<?> type = Class.forName(MasterRecordHistoryService.class.getName() + "$Fact");
        var constructor = type.getDeclaredConstructors()[0]; constructor.setAccessible(true);
        String table = entity.equals("payment-styles") ? "payment_styles" : entity;
        return constructor.newInstance(1L, entity, table, UUID.randomUUID(), UUID.randomUUID(), before, after,
                "EDIT", "原始操作人", OffsetDateTime.parse("2026-01-01T00:00:00Z"), 1L, null, UUID.randomUUID());
    }
    private static AuthUser user(boolean admin, String... permissions) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "reader", Set.of(permissions), false, true, admin);
    }
}
