package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionFacts;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;

import java.util.Map;

/** Keeps the original workshop and warehouse boundaries when a requisition changes its navigation entry. */
final class WarehouseWorkshopMaterialTaskProjection {
    private WarehouseWorkshopMaterialTaskProjection() {}

    record Scope(boolean enabled, String predicate, Map<String, Object> parameters) {
        static final Scope NONE = new Scope(false, "FALSE", Map.of());
    }

    static Scope scope(boolean enabled, WorkshopMaterialScope materials, WarehouseTaskScope warehouses) {
        if (!enabled) return Scope.NONE;
        var parameters = new MapSqlParameterSource();
        String predicate = materials.predicate("requisition.workshop_department_id", parameters);
        String pending = materials.requisitionWarehouseFilter(warehouses, parameters);
        String posted = materials.requisitionPhysicalWarehouseFilter(warehouses, parameters,"physical.leaf_warehouse_id");
        if (!pending.isEmpty()) predicate += " AND ((physical.posting_id IS NULL AND " + pending
                + ") OR (physical.posting_id IS NOT NULL AND " + posted + "))";
        return new Scope(true, predicate, Map.copyOf(parameters.getValues()));
    }

    static String from(String kind, Scope scope) {
        return """
                FROM workshop_material_requisitions requisition
                JOIN workshop_material_requisition_lines line ON line.requisition_id=requisition.id
                %s
                JOIN goods ON goods.id=line.goods_id
                LEFT JOIN colors color ON color.id=line.color_id
                LEFT JOIN units unit ON unit.id=line.unit_id
                LEFT JOIN departments workshop ON workshop.id=requisition.workshop_department_id
                LEFT JOIN warehouses warehouse ON warehouse.id=physical.leaf_warehouse_id
                LEFT JOIN users requester_user ON requester_user.id=requisition.requested_by
                LEFT JOIN employees requester ON requester.id=requester_user.employee_id
                WHERE requisition.kind='%s' AND (%s)
                """.formatted(WorkshopMaterialRequisitionFacts.physicalJoin(), kind, scope.predicate());
    }

    static String outbound(Scope scope) {
        return """
                SELECT 'DRAW','WORKSHOP_REQUISITION',requisition.id,requisition.request_no,physical.bill_no,
                       (requisition.requested_at AT TIME ZONE 'Asia/Shanghai')::date,
                       workshop.name,COALESCE(warehouse.name,''),NULL::text,requester.full_name,1,
                       'DRAW_WORKSHOP_' || CASE WHEN line.fulfilled_qty>0 THEN 'DONE' ELSE requisition.status END,
                       concat_ws(' ',requisition.request_no,workshop.name,goods.code,goods.name,color.name),
                       NULL::uuid,NULL::int,NULL::int,requisition.row_version,requisition.id,TRUE,
                       requisition.status='PENDING' AND line.fulfilled_qty=0,ARRAY[goods.code],ARRAY[goods.name],
                       physical.line_key,physical.item_id,line.line_no,goods.code,goods.name,goods.spec,color.name,unit.name,
                       physical.quantity,NULL::numeric
                """ + from("ISSUE", scope);
    }

    static String inbound(Scope scope) {
        return """
                SELECT requisition.id,'RETURN'::text AS source_type,'WORKSHOP_REQUISITION'::text AS record_type,
                       requisition.request_no AS bill_no,physical.bill_no AS source_doc_no,
                       (requisition.requested_at AT TIME ZONE 'Asia/Shanghai')::date AS business_date,
                       workshop.name AS party_name,COALESCE(warehouse.name,'') AS warehouse_name,
                       NULL::text AS responsible_name,requester.full_name AS maker_name,1 AS line_count,
                       'RETURN_WORKSHOP_' || CASE WHEN line.fulfilled_qty>0 THEN 'DONE' ELSE requisition.status END AS workflow_status,
                       'WORKSHOP_REQUISITION'::text AS action,requisition.id AS target_id,
                       jsonb_build_object('requisitionId',requisition.id,'requisitionLineId',line.id,
                           'kind',requisition.kind,'expectedVersion',requisition.row_version) AS action_data,
                       NULL::uuid AS maker_id,TRUE AS production_linked,requisition.requested_at AS sort_time,
                       concat_ws(' ',requisition.request_no,workshop.name,goods.code,goods.name,color.name) AS search_text,
                       ARRAY[goods.code] AS goods_codes,ARRAY[goods.name] AS goods_names,
                       jsonb_build_object('key',physical.line_key,'itemId',physical.item_id,'lineNo',line.line_no,'goodsCode',goods.code,
                           'goodsName',goods.name,'specification',goods.spec,'colorName',color.name,'unitName',unit.name,
                           'quantity',physical.quantity)
                           AS line_data
                """ + from("RETURN", scope);
    }
}
