package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class WarehouseTaskHeaderQueryTest {
    @Test void jsonSortsResolveToFixedPhysicalExpressionsForBothTaskRelations() {
        Map.of("goodsName","goods_name","goodsCode","goods_code","colorName","color_name",
                "specification","specification").forEach((key,column)->{
            assertEquals("line_data->>'"+key+"'",WarehouseTaskHeaderQuery.orderExpression(new String(key.toCharArray()),true));
            assertEquals(column,WarehouseTaskHeaderQuery.orderExpression(new String(key.toCharArray()),false));
        });
        assertEquals("CAST(line_data->>'quantity' AS numeric)",WarehouseTaskHeaderQuery.orderExpression("quantity",true));
        assertEquals("quantity",WarehouseTaskHeaderQuery.orderExpression("quantity",false));
        for(String value:new String[]{"goodsName' DESC; DROP TABLE goods --","line_data","__proto__"}) {
            assertThrows(ApiException.class,()->WarehouseTaskHeaderQuery.orderExpression(value,true));
        }
    }
    @Test void procurementProgressSortsUseOnlyFixedNumericExpressions() {
        Map.of("stockedQty","CAST(action_data->>'stockedQty' AS numeric)",
                "pendingStockInQty","CAST(action_data->>'pendingStockInQty' AS numeric)",
                "pendingReturnQty","CAST(action_data->>'pendingReturnQty' AS numeric)").forEach((key,sql)->{
            assertEquals(sql,WarehouseTaskHeaderQuery.orderExpression(new String(key.toCharArray()),true));
            assertThrows(ApiException.class,()->WarehouseTaskHeaderQuery.orderExpression(key,false));
            assertThrows(ApiException.class,()->WarehouseTaskHeaderQuery.orderExpression(key+"' AS numeric);SELECT 1 --",true));
        });
    }
}
