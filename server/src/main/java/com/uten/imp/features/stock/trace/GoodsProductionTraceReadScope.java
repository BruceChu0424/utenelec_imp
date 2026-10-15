package com.uten.imp.features.stock.trace;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import java.util.HashMap;
import java.util.Map;

/** Shared physical read scope for the inventory entry and typed where-used entry. */
final class GoodsProductionTraceReadScope {
    final WarehouseTaskScope warehouses;
    final Map<String,Object> parameters=new HashMap<>();
    private final StockDocAccessPolicy stockAccess;
    private final boolean stockDocumentView;
    private final boolean warehouseParticipant;

    GoodsProductionTraceReadScope(StockDocAccessPolicy stockAccess,WarehouseTaskScope warehouses,
                                 boolean stockDocumentView,boolean warehouseParticipant) {
        this.stockAccess=stockAccess;
        // Warehouse-task responsibility narrows the warehouse pool, not an ordinary owner's or assigned worker's task authority.
        this.warehouses=!warehouseParticipant?WarehouseTaskScope.ALL:warehouses==null?WarehouseTaskScope.NONE:warehouses;
        this.stockDocumentView=stockDocumentView;
        this.warehouseParticipant=warehouseParticipant;
    }

    String warehouse(String column) {
        if(!warehouses.active())return "TRUE";
        parameters.put("traceWarehouseIds",warehouses.idsCsv());
        return warehouses.predicate(column,":traceWarehouseIds");
    }

    String document(String alias) {
        if(!stockDocumentView)return "FALSE";
        var owner=stockAccess.nativeReadScope(alias+".maker_id","traceStockOwners");
        if(owner.parameterName()!=null)parameters.put(owner.parameterName(),owner.owners());
        String predicate=owner.predicate();
        // Document type alone is never evidence that a manual document belongs to the task pool.
        return warehouseParticipant?"("+predicate+" OR fn_stock_document_has_history_provenance("+alias+".id))":predicate;
    }

    String posting() {
        return "EXISTS(SELECT 1 FROM production_material_stock_events scope_event "+
                "JOIN stock_documents scope_document ON scope_document.id=scope_event.stock_document_id "+
                "JOIN stock_document_items scope_item ON scope_item.id=posting.stock_document_item_id AND scope_item.doc_id=scope_document.id "+
                // Task facts are authorized by materialAccess in the canonical query. Document metadata has its own gate.
                "WHERE scope_event.id=posting.event_id AND "+
                warehouse("COALESCE(scope_item.warehouse_id,scope_document.warehouse_id)")+")";
    }

    String periodic() {
        return "EXISTS(SELECT 1 FROM workshop_material_close_allocations scoped_allocation "+
                "JOIN workshop_material_close_materials scoped_material ON scoped_material.id=scoped_allocation.close_material_id "+
                "JOIN workshop_material_period_closes scoped_close ON scoped_close.id=scoped_material.close_id "+
                "JOIN workshop_material_periods scoped_period ON scoped_period.id=scoped_close.period_id "+
                "WHERE scoped_allocation.id=trace.allocation_id AND "+warehouse("scoped_period.bin_warehouse_id")+")";
    }

    String receipt() {
        return warehouse("receipt.warehouse_id")+" AND EXISTS(SELECT 1 FROM production_material_stock_postings posting "+
                "WHERE posting.demand_id=allocation.demand_id AND posting.reservation_id=allocation.reservation_id "+
                "AND posting.stock_document_item_id=allocation.draw_item_id AND posting.posting_type='ISSUE' AND "+posting()+")";
    }
}
