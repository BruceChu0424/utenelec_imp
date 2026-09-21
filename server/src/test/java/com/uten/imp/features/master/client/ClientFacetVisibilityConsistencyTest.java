package com.uten.imp.features.master.client;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ClientFacetVisibilityConsistencyTest {

    @Test
    void everyFacetBucketAndNullCountUsesTheSameStubAndVisibilityPredicate() {
        UUID categoryId = UUID.randomUUID();
        ClientCategory category = new ClientCategory();
        category.setId(categoryId);
        ClientCategoryRepository categories = mock(ClientCategoryRepository.class);
        when(categories.findSubtree(categoryId)).thenReturn(List.of(category));
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(0L);
        ClientAccessPolicy access = mock(ClientAccessPolicy.class);
        ClientAccessPolicy.ClientScope scope = mock(ClientAccessPolicy.ClientScope.class);
        when(access.evaluate()).thenReturn(scope);
        when(access.nativeReadScope("", scope)).thenReturn(
                new ClientAccessPolicy.NativeReadScope(
                        "clients.owner_employee_id = :owners",
                        "owners", Set.of(UUID.randomUUID()), null, null));
        ClientService service = new ClientService(
                mock(ClientRepository.class), categories, mock(TxSessionVars.class), em,
                mock(CategoryDrivenCodeService.class), access,
                mock(EmployeeRepository.class), mock(EmployeeNameResolver.class));

        service.facets(categoryId, true);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        // 21 个白名单 facet 字段(V630 起不含 salesPaymentType；empId 走专用 JOIN 聚合)各发一条桶查询 + 一条空值计数，
        // 加上负责人(empId)的 JOIN 桶查询与空值计数，共 44 条。
        org.mockito.Mockito.verify(em, org.mockito.Mockito.times(44))
                .createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).allSatisfy(statement -> assertThat(statement)
                .contains("legacy-fin-cl-%")
                .contains("clients.owner_employee_id = :owners"));
        // 负责人（empId）桶：JOIN employees 按 owner_employee_id 分组、label 出人名；
        // 空值计数按 owner_employee_id is null（= 前端列「未分配」）。
        assertThat(sql.getAllValues()).anySatisfy(statement -> {
            assertThat(statement)
                    .contains("join employees on employees.id = clients.owner_employee_id")
                    .contains("group by employees.id, employees.full_name");
        });
        assertThat(sql.getAllValues()).anySatisfy(statement -> {
            assertThat(statement)
                    .contains("owner_employee_id is null")
                    .doesNotContain("join employees");
        });
    }
}
