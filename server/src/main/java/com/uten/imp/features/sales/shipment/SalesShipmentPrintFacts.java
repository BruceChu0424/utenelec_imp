package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import java.util.*;

/** One original-paper description snapshot, keyed by immutable shipment line UUID. */
final class SalesShipmentPrintFacts {
    private SalesShipmentPrintFacts() { }
    static Map<String,Map<String,String>> capture(EntityManager em,UUID shipmentId){
        Map<String,Map<String,String>> lines=new LinkedHashMap<>();for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT i.id,g.model,g.series,color.name,unit.name FROM sales_shipment_items i
                LEFT JOIN goods g ON g.id=i.goods_id LEFT JOIN colors color ON color.id=i.color_id
                LEFT JOIN units unit ON unit.id=i.unit_id WHERE i.shipment_id=:id AND NOT i.is_deleted ORDER BY i.line_no,i.id
                """).setParameter("id",shipmentId)))lines.put(row[0].toString(),Map.of("model",Objects.toString(row[1],""),"series",Objects.toString(row[2],""),"color",Objects.toString(row[3],""),"unit",Objects.toString(row[4],"")));
        return Collections.unmodifiableMap(lines);
    }
}
