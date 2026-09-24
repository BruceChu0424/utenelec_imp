package com.uten.imp.application.port;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-115 仓库范围: 「我的仓库」含未定仓的单据, 指定仓库不含; 值只绑定不拼接。 */
class WarehouseTaskScopeTest {

    private final UUID first = UUID.fromString("00000000-0000-0000-0000-00000000a001");
    private final UUID second = UUID.fromString("00000000-0000-0000-0000-00000000a002");

    @Test
    void allScopeIsInactive() {
        assertThat(WarehouseTaskScope.ALL.active()).isFalse();
        assertThat(WarehouseTaskScope.ALL.warehouseIds()).isEmpty();
    }

    @Test
    void mineScopeIncludesDocumentsWithoutAWarehouse() {
        WarehouseTaskScope mine = new WarehouseTaskScope(true, List.of(first, second), true);

        assertThat(mine.predicate("warehouse_id", ":warehouse_scope")).isEqualTo(
                "(warehouse_id IS NULL OR warehouse_id = ANY(CAST(string_to_array("
                        + "CAST(:warehouse_scope AS text), ',') AS uuid[])))");
        assertThat(mine.idsCsv()).isEqualTo(first + "," + second);
    }

    @Test
    void specificWarehouseScopeExcludesDocumentsWithoutAWarehouse() {
        WarehouseTaskScope one = new WarehouseTaskScope(true, List.of(first), false);

        assertThat(one.predicate("exception.warehouse_id", "?")).isEqualTo(
                "exception.warehouse_id = ANY(CAST(string_to_array(CAST(? AS text), ',') AS uuid[]))");
    }

    @Test
    void emptyScopeBindsAnEmptyArrayNotANull() {
        // 「我负责的仓都被删了」之类的空范围: 空串 → string_to_array 得空数组, 只剩未定仓的单据。
        WarehouseTaskScope empty = new WarehouseTaskScope(true, null, true);
        assertThat(empty.warehouseIds()).isEmpty();
        assertThat(empty.idsCsv()).isEmpty();
    }
}
