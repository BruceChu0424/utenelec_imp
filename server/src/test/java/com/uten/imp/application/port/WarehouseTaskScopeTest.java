package com.uten.imp.application.port;

import com.uten.imp.application.port.WarehouseTaskScopePort.Role;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseAccess;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-149 仓库数据范围: 只有「其他人」的默认范围含未定仓的单据; 子仓负责人与所选仓不含;
 * 多仓任务任一仓在范围内即算; 值只绑定不拼接。
 */
class WarehouseTaskScopeTest {

    private final UUID first = UUID.fromString("00000000-0000-0000-0000-00000000a001");
    private final UUID second = UUID.fromString("00000000-0000-0000-0000-00000000a002");

    @Test
    void allScopeIsInactive() {
        assertThat(WarehouseTaskScope.ALL.active()).isFalse();
        assertThat(WarehouseTaskScope.ALL.warehouseIds()).isEmpty();
        assertThat(WarehouseTaskScope.NONE.active()).isTrue();
        assertThat(WarehouseTaskScope.NONE.includeUnassigned()).isFalse();
    }

    @Test
    void otherRoleScopeIncludesDocumentsWithoutAWarehouse() {
        WarehouseTaskScope uncovered = new WarehouseTaskScope(true, List.of(first, second), true);

        assertThat(uncovered.predicate("warehouse_id", ":warehouse_scope")).isEqualTo(
                "(warehouse_id IS NULL OR warehouse_id = ANY(CAST(string_to_array(NULLIF("
                        + "CAST(:warehouse_scope AS text), ''), ',') AS uuid[])))");
        assertThat(uncovered.idsCsv()).isEqualTo(first + "," + second);
    }

    @Test
    void keeperOrSelectedWarehouseScopeExcludesDocumentsWithoutAWarehouse() {
        WarehouseTaskScope one = new WarehouseTaskScope(true, List.of(first), false);

        assertThat(one.predicate("exception.warehouse_id", "?")).isEqualTo(
                "exception.warehouse_id = ANY(CAST(string_to_array(NULLIF(CAST(? AS text), ''), ',') AS uuid[]))");
    }

    @Test
    void multiWarehouseTasksMatchWhenAnyWarehouseIsInScope() {
        WarehouseTaskScope keeper = new WarehouseTaskScope(true, List.of(first), false);
        WarehouseTaskScope other = new WarehouseTaskScope(true, List.of(first), true);

        assertThat(keeper.predicateAny("ARRAY[d.warehouse_id, d.to_warehouse_id]", ":p")).isEqualTo(
                "((ARRAY[d.warehouse_id, d.to_warehouse_id]) && "
                        + "CAST(string_to_array(NULLIF(CAST(:p AS text), ''), ',') AS uuid[]))");
        // 未定仓 = 一个仓都没有(数组去掉 NULL 后为空), 只有「其他人」的默认范围才算。
        assertThat(other.predicateAny("ARRAY[d.warehouse_id, d.to_warehouse_id]", ":p")).endsWith(
                " OR cardinality(array_remove(ARRAY[d.warehouse_id, d.to_warehouse_id], NULL)) = 0)");
    }

    @Test
    void emptyScopeBindsNullSoNothingMatchesButUnassignedRules() {
        // 「我负责的仓都被删了」之类的空范围: 空串 → NULLIF 得 NULL, 任何仓都不匹配, 只剩未定仓规则。
        WarehouseTaskScope empty = new WarehouseTaskScope(true, null, true);
        assertThat(empty.warehouseIds()).isEmpty();
        assertThat(empty.idsCsv()).isEmpty();
    }

    @Test
    void participantsAreSupervisorsKeepersOrWarehouseMembers() {
        assertThat(new WarehouseAccess(Role.SUPERVISOR, List.of(), WarehouseTaskScope.ALL, false)
                .warehouseParticipant()).isTrue();
        assertThat(new WarehouseAccess(Role.KEEPER, List.of(first), null, false).warehouseParticipant()).isTrue();
        assertThat(new WarehouseAccess(Role.OTHER, List.of(), null, true).warehouseParticipant()).isTrue();
        WarehouseAccess outsider = new WarehouseAccess(Role.OTHER, null, null, false);
        assertThat(outsider.warehouseParticipant()).isFalse();
        assertThat(outsider.defaultScope()).isEqualTo(WarehouseTaskScope.NONE);
        assertThat(outsider.keeperWarehouseIds()).isEmpty();
    }
}
