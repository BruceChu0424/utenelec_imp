package com.uten.imp.support;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.UUID;

/** 直插 SQL 夹具的货品最小库存调整（与 warehouses 激活同族，见 WarehouseFixtureActivation）。 */
public final class GoodsFixtureAdjustment {
    private GoodsFixtureAdjustment() {}

    public static void setMinimumQuantity(Connection connection, UUID goodsId, int minQty) throws Exception {
        String sql = "UPDATE goods SET min_qty=? WHERE id=?";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setInt(1, minQty);
            statement.setObject(2, goodsId);
            statement.executeUpdate();
        }
    }
}
