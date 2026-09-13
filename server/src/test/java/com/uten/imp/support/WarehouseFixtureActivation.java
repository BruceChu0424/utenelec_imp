package com.uten.imp.support;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.UUID;

/**
 * V563 起 IQC 实际入库仓必须是「使用」状态的记账叶子仓；
 * 直插 SQL 夹具创建的仓库默认没有状态，统一在此对齐生产行为。
 */
public final class WarehouseFixtureActivation {
    private WarehouseFixtureActivation() {}

    public static void activate(Connection connection, UUID warehouseId) throws Exception {
        String sql = "UPDATE warehouses SET is_accountable=TRUE, status='使用' WHERE id=?";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, warehouseId);
            statement.executeUpdate();
        }
    }
}
