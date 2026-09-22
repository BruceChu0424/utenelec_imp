package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.OrganizationReferencePort;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.warehouse.dto.WarehouseListItem;
import com.uten.imp.features.master.warehouse.dto.WarehouseQueryFilter;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 整页都是顶层仓库时列表不能 500(2026-09-22 实机踩到)。
 *
 * <p>上级仓名是按本页出现过的 parentId 一次性载入的：本页没有任何一行带上级时，
 * 载入结果是 Map.of() 这种不可变空 Map，再拿 null 的 parentId 去 get 就抛 NPE，
 * 整个仓库列表变成 500。页里只要混进一行带上级的就换成 HashMap，get(null) 合法——
 * 所以平时翻不出来，只在「筛选顶层仓」或「小页恰好只有顶层仓」时现形。</p>
 */
class WarehouseListTopLevelOnlyPageTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void pageWithoutAnyParentedRowStillMapsToListItems() {
        Warehouse top = new Warehouse();
        top.setCode("C01");
        top.setName("成品仓");
        // parentId 与 workshopDepartmentId 都留 null：这就是顶层、非车间仓的常态。

        WarehouseRepository repository = mock(WarehouseRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(top)));
        OrganizationReferencePort organizations = mock(OrganizationReferencePort.class);
        when(organizations.findActiveDepartmentNames(any())).thenReturn(Map.of());

        WarehouseService service = new WarehouseService(
                repository,
                mock(TxSessionVars.class),
                mock(EntityManager.class),
                mock(MasterCodeService.class),
                organizations);

        PageResponse<WarehouseListItem> page = service.list(
                new WarehouseQueryFilter(null, null, null, null, null, null, null, null), 1, 20);

        assertThat(page.getItems()).singleElement().satisfies(item -> {
            assertThat(item.getCode()).isEqualTo("C01");
            assertThat(item.getParentId()).isNull();
            assertThat(item.getParentName()).isNull();
            assertThat(item.getWorkshopDepartmentName()).isNull();
        });
    }
}
