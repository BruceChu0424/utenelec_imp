package com.uten.imp.support;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.UUID;

/** 直插 SQL 夹具的货品最小库存调整（与 warehouses 激活同族，见 WarehouseFixtureActivation）。 */
public final class GoodsFixtureAdjustment {
    private GoodsFixtureAdjustment() {}

    /** Complete raw-SQL fixture metadata before exercising the real master edit command. */
    public static void prepareForMasterMaintenance(org.springframework.jdbc.core.JdbcTemplate db, UUID... goodsIds) {
        UUID category = UUID.randomUUID();
        db.update("INSERT INTO material_categories(id,code,name,level) VALUES(?,?,?,0)",
                category, "MS-" + category.toString().substring(0, 8), "主档来源维护测试 " + category);
        for (UUID goodsId : goodsIds) {
            org.junit.jupiter.api.Assertions.assertEquals(1, db.update(
                    "UPDATE goods SET category_id=COALESCE(category_id,?) WHERE id=?", category, goodsId));
        }
    }

    /** A later analysis may use a new master source; existing issued supply keeps its original source. */
    public static void maintainSourceType(org.springframework.jdbc.core.JdbcTemplate db,
            com.uten.imp.features.master.goods.GoodsInlineEditService service, UUID goodsId, String sourceType) {
        long version = db.queryForObject("SELECT version FROM goods WHERE id=?", Long.class, goodsId);
        var saved = service.patch(goodsId,
                java.util.Map.of("version", com.fasterxml.jackson.databind.node.LongNode.valueOf(version)),
                java.util.Map.of("sourceType", com.fasterxml.jackson.databind.node.TextNode.valueOf(sourceType)));
        org.junit.jupiter.api.Assertions.assertEquals(sourceType, saved.getSourceType());
        org.junit.jupiter.api.Assertions.assertEquals(sourceType,
                db.queryForObject("SELECT source_type FROM goods WHERE id=?", String.class, goodsId));
    }

    public static void setMinimumQuantity(Connection connection, UUID goodsId, int minQty) throws Exception {
        String sql = "UPDATE goods SET min_qty=? WHERE id=?";
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setInt(1, minQty);
            statement.setObject(2, goodsId);
            statement.executeUpdate();
        }
    }
}
