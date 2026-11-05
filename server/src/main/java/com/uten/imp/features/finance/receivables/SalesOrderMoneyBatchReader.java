package com.uten.imp.features.finance.receivables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import java.util.*;

/** Run the owning single-order SQL for one bounded visible page in one round trip. */
final class SalesOrderMoneyBatchReader {
    private SalesOrderMoneyBatchReader() { }

    static List<UUID> ids(Collection<UUID> source) {
        List<UUID> ids = source == null ? List.of() : source.stream().filter(Objects::nonNull).distinct().toList();
        if (ids.size() > 200) throw new ApiException(ErrorCode.VALIDATION_FAILED, "订单资金汇总每批最多查询 200 笔");
        return ids;
    }

    static Map<UUID, List<Object[]>> rows(EntityManager em, String singleOrderSql, Collection<UUID> source) {
        List<UUID> ids = ids(source);
        if (ids.isEmpty()) return Map.of();
        String sql = "SELECT money_order_input.id AS money_batch_order_id,money_value.* FROM sales_orders money_order_input "
                + "CROSS JOIN LATERAL (" + singleOrderSql.replace(":orderId", "money_order_input.id")
                + ") money_value WHERE money_order_input.id IN (:orderIds) AND NOT money_order_input.is_deleted";
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(sql).setParameter("orderIds", ids));
        Map<UUID, List<Object[]>> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            UUID id = row[0] instanceof UUID value ? value : UUID.fromString(row[0].toString());
            result.computeIfAbsent(id, ignored -> new ArrayList<>()).add(Arrays.copyOfRange(row, 1, row.length));
        }
        return result;
    }
}
