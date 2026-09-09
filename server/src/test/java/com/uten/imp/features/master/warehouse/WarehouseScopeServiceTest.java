package com.uten.imp.features.master.warehouse;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * V476 主/子层级：查询范围展开 + 叶子仓落库红线的纯单元测试。
 *
 * <p>父仓=自身+全部后代聚合；叶子仓=单元素集合（旧精确匹配语义）；
 * 单据保存遇到父仓必须拒绝（货品/物料必须落到具体子仓库）。
 */
class WarehouseScopeServiceTest {

    private final WarehouseRepository repo = mock(WarehouseRepository.class);
    private final WarehouseScopeService service = new WarehouseScopeService(repo);

    @org.junit.jupiter.api.BeforeEach
    void unlockedHierarchyMatchesLockedRowsUnlessExplicitlyOverridden() {
        org.mockito.Mockito.lenient().when(repo.findAll()).thenAnswer(invocation ->
                repo.findAllForNewSelection(java.util.List.of()));
    }

    private static Warehouse wh(String id, String parentId) {
        Warehouse w = new Warehouse();
        ReflectionTestUtils.setField(w, "id", UUID.fromString(id));
        w.setParentId(parentId == null ? null : UUID.fromString(parentId));
        return w;
    }

    // 主仓库（14年版）→ [成品仓库, 原材料不良仓, 轨道车间]；成品仓库又有自己的子仓。
    private static final String MAIN = "e05a00b5-0b91-4c5e-8622-42a9ddb28d5b";
    private static final String FINISHED = "f0cd7dc0-f27e-4fa7-bc7e-5af92afbe4ac";
    private static final String DEFECTIVE = "1fda5b20-8279-48f1-8987-bcdaf98d3f0f";
    private static final String TRACK = "ace34783-4957-45cb-95e6-14b1c74f2f0b";
    private static final String FINISHED_SUB = "a231d4ff-66aa-4d07-b33f-13f50bb0aeed";

    private void givenHierarchy() {
        when(repo.findAll()).thenReturn(List.of(
                wh(MAIN, null),
                wh(FINISHED, MAIN),
                wh(FINISHED_SUB, FINISHED),
                wh(DEFECTIVE, MAIN),
                wh(TRACK, MAIN)));
    }

    @Test
    void parentWarehouseScopeIncludesSelfAndAllDescendants() {
        givenHierarchy();
        Set<UUID> scope = service.scopeOf(UUID.fromString(MAIN));
        assertThat(scope).containsExactlyInAnyOrder(
                UUID.fromString(MAIN), UUID.fromString(FINISHED),
                UUID.fromString(FINISHED_SUB), UUID.fromString(DEFECTIVE),
                UUID.fromString(TRACK));
    }

    @Test
    void midLevelScopeCoversOwnSubtreeOnly() {
        givenHierarchy();
        Set<UUID> scope = service.scopeOf(UUID.fromString(FINISHED));
        assertThat(scope).containsExactlyInAnyOrder(
                UUID.fromString(FINISHED), UUID.fromString(FINISHED_SUB));
    }

    @Test
    void leafWarehouseScopeStaysExactMatch() {
        givenHierarchy();
        assertThat(service.scopeOf(UUID.fromString(TRACK)))
                .containsExactly(UUID.fromString(TRACK));
    }

    @Test
    void softDeletedOrUnknownWarehouseDegradesToExactMatch() {
        Warehouse deleted = wh(MAIN, null);
        deleted.setDeleted(true);
        when(repo.findAll()).thenReturn(List.of(deleted));
        assertThat(service.scopeOf(UUID.fromString(MAIN)))
                .containsExactly(UUID.fromString(MAIN));
    }

    @Test
    void operationalSaveRejectsParentWarehouse() {
        givenHierarchy();
        assertThatThrownBy(() ->
                service.requireLeafWarehouse(UUID.fromString(MAIN), "仓库"))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("具体子仓库");
    }

    @Test
    void operationalSaveAcceptsLeafWarehouseAndNull() {
        givenHierarchy();
        assertThatCode(() ->
                service.requireLeafWarehouse(UUID.fromString(TRACK), "仓库"))
                .doesNotThrowAnyException();
        assertThatCode(() -> service.requireLeafWarehouse(null, "仓库"))
                .doesNotThrowAnyException();
    }

    @Test
    void parentCycleInDataDoesNotLoopForever() {
        // 防御：异常数据（A→B→A）不得让 scopeOf 死循环。
        Warehouse a = wh(MAIN, FINISHED);
        Warehouse b = wh(FINISHED, MAIN);
        when(repo.findAll()).thenReturn(List.of(a, b));
        assertThat(service.scopeOf(UUID.fromString(MAIN)))
                .containsExactlyInAnyOrder(UUID.fromString(MAIN), UUID.fromString(FINISHED));
    }

    @Test
    void operationalScopeIncludesSiblingLeavesButNeverAnotherMainWarehouse() {
        givenHierarchy();
        assertThat(service.operationalLeafIds(UUID.fromString(FINISHED_SUB)))
                .containsExactlyInAnyOrder(UUID.fromString(FINISHED_SUB),
                        UUID.fromString(DEFECTIVE), UUID.fromString(TRACK));
        assertThat(service.sameMainWarehouse(UUID.fromString(FINISHED_SUB),
                UUID.fromString(TRACK))).isTrue();
        assertThat(service.sameMainWarehouse(UUID.fromString(TRACK), UUID.randomUUID()))
                .isFalse();
    }

    @Test
    void cyclicOrMissingAncestryDoesNotJoinDifferentWarehouses() {
        when(repo.findAll()).thenReturn(List.of(wh(MAIN, FINISHED), wh(FINISHED, MAIN)));
        assertThat(service.sameMainWarehouse(UUID.fromString(MAIN), UUID.fromString(FINISHED)))
                .isFalse();
        assertThat(service.operationalLeafIds(UUID.fromString(MAIN)))
                .containsExactly(UUID.fromString(MAIN));
        assertThat(service.sameMainWarehouse(null, UUID.fromString(MAIN))).isFalse();
    }

    @Test
    void newSelectionAllowsAccountingLeafUnderNonAccountingMain() {
        Warehouse main = wh(MAIN, null);
        main.setAccountable(false);
        when(repo.findAllForNewSelection(org.mockito.ArgumentMatchers.anyCollection())).thenReturn(List.of(main, wh(TRACK, MAIN)));
        assertThatCode(() -> service.requireNewLeafSelection(null, UUID.fromString(TRACK), "仓库"))
                .doesNotThrowAnyException();
        assertThatThrownBy(() -> service.requireActiveLeafWarehouse(UUID.fromString(MAIN), "仓库"))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void disabledPhysicalStockRemainsVisibleButCannotBeNewlySelected() {
        Warehouse leaf = wh(TRACK, MAIN);
        leaf.setStatus("禁用");
        List<Warehouse> rows = List.of(wh(MAIN, null), leaf);
        when(repo.findAll()).thenReturn(rows);
        when(repo.findAllForNewSelection(org.mockito.ArgumentMatchers.anyCollection())).thenReturn(rows);
        UUID id = UUID.fromString(TRACK);
        assertThat(service.operationalLeafIds(UUID.fromString(MAIN))).contains(id);
        assertThatCode(() -> service.requireNewLeafSelection(id, id, "仓库"))
                .doesNotThrowAnyException();
        assertThatThrownBy(() -> service.requireNewLeafSelection(null, id, "仓库"))
                .isInstanceOf(ApiException.class).hasMessageContaining("停用");
        assertThatThrownBy(() -> service.requireActiveLeafWarehouse(id, "入库仓库"))
                .isInstanceOf(ApiException.class).hasMessageContaining("停用");
    }

    @Test
    void disabledOrMissingAncestorAndUnaccountableLeafCannotBeBypassed() {
        UUID id = UUID.fromString(TRACK);
        Warehouse main = wh(MAIN, null);
        Warehouse leaf = wh(TRACK, MAIN);
        main.setStatus("禁用");
        when(repo.findAllForNewSelection(org.mockito.ArgumentMatchers.anyCollection())).thenReturn(List.of(main, leaf));
        assertThatThrownBy(() -> service.requireActiveLeafWarehouse(id, "仓库"))
                .isInstanceOf(ApiException.class).hasMessageContaining("停用");
        when(repo.findAllForNewSelection(org.mockito.ArgumentMatchers.anyCollection())).thenReturn(List.of(leaf));
        assertThatThrownBy(() -> service.requireActiveLeafWarehouse(id, "仓库"))
                .isInstanceOf(ApiException.class).hasMessageContaining("不完整");
        main.setStatus("使用");
        leaf.setAccountable(false);
        when(repo.findAllForNewSelection(org.mockito.ArgumentMatchers.anyCollection())).thenReturn(List.of(main, leaf));
        assertThatThrownBy(() -> service.requireActiveLeafWarehouse(id, "仓库"))
                .isInstanceOf(ApiException.class).hasMessageContaining("记账");
        leaf.setAccountable(true);
        leaf.setDeleted(true);
        assertThatThrownBy(() -> service.requireActiveLeafWarehouse(id, "仓库"))
                .isInstanceOf(ApiException.class).hasMessageContaining("删除");
    }

    @Test
    void activeSelectionRejectsCyclesAndUnknownIds() {
        when(repo.findAllForNewSelection(org.mockito.ArgumentMatchers.anyCollection())).thenReturn(List.of(
                wh(MAIN, FINISHED), wh(FINISHED, MAIN), wh(TRACK, MAIN)));
        assertThatThrownBy(() -> service.requireActiveLeafWarehouse(UUID.fromString(TRACK), "仓库"))
                .isInstanceOf(ApiException.class).hasMessageContaining("不完整");
        assertThatThrownBy(() -> service.requireActiveLeafWarehouse(UUID.randomUUID(), "仓库"))
                .isInstanceOf(ApiException.class).hasMessageContaining("不存在");
    }
}
