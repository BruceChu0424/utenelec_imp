package com.uten.imp.features.warehouse.taskcenter;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.features.warehouse.materialbin.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

/** Real migrated SQL, rollback-only facts: suggestions never authorize or label completed movements. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WarehouseWorkshopMaterialHistoryPostgresTest {
    @Test void actualPostingWarehousesSplitHistoryWhileRemainingRequestsAndBadgesKeepTheirOwnScope() throws Exception {
        try(var database=MigratedSchemaBaseline.openDatabase("wm_history_actual_leaf");var connection=database.openConnection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {
                statement.execute("CREATE SCHEMA wm_history_oracle");
                statement.execute("SET LOCAL search_path=wm_history_oracle,public");
            }
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"workshop_material_requisitions",
                    "workshop_material_requisition_lines","workshop_material_requisition_postings","workshop_material_periods",
                    "stock_documents","stock_document_items","goods","departments","warehouses","users","employees","colors","units");
            var db=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
            UUID a=UUID.randomUUID(),b=UUID.randomUUID(),workshop=UUID.randomUUID(),goods=UUID.randomUUID();
            db.update("INSERT INTO warehouses(id,name) VALUES(:a,'A仓'),(:b,'B仓')",Map.of("a",a,"b",b));
            db.update("INSERT INTO warehouses(id,name) VALUES(:id,'内料仓')",Map.of("id",workshop));
            db.update("INSERT INTO departments(id,name) VALUES(:id,'注塑')",Map.of("id",workshop));
            db.update("INSERT INTO goods(id,code,name) VALUES(:id,'MAT','材料')",Map.of("id",goods));
            var current=mock(SecurityContextCurrentUser.class);
            when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),null,"warehouse",Set.of(),false,false,false)));
            var scope=new WorkshopMaterialScope(db,current);
            var permissions=mock(WorkshopMaterialPermissions.class);
            when(permissions.has(WorkshopMaterialPermissions.ISSUE)).thenReturn(true);
            var badges=new WorkshopMaterialPositionQueryService(db,null,scope,permissions,null,null);
            UUID request=UUID.randomUUID(),line=UUID.randomUUID(),remaining=UUID.randomUUID();
            db.update("""
                    INSERT INTO workshop_material_requisitions(id,request_no,kind,origin,status,workshop_department_id,
                        bin_warehouse_id,requested_at,row_version)
                    VALUES(:id,'WM-ACTUAL','ISSUE','WORKSHOP_REQUEST','PENDING',:workshop,:bin,now(),1)
                    """,Map.of("id",request,"workshop",workshop,"bin",workshop));
            db.update("""
                    INSERT INTO workshop_material_requisition_lines(id,requisition_id,line_no,goods_id,
                        suggested_leaf_warehouse_id,requested_qty,fulfilled_qty)
                    VALUES(:done,:request,1,:goods,:a,5,5),(:pending,:request,2,:goods,:b,4,0)
                    """,Map.of("done",line,"pending",remaining,"request",request,"goods",goods,"a",a,"b",b));
            UUID postingB=posting(db,line,b,"5");
            var onlyA=new WarehouseTaskScope(true,List.of(a),false);
            var onlyB=new WarehouseTaskScope(true,List.of(b),false);
            assertThat(outbound(db,scope,onlyA)).isEmpty();
            var visibleB=outbound(db,scope,onlyB);
            assertThat(visibleB).hasSize(2);
            assertThat(visibleB).filteredOn(row->row.get("status").equals("DRAW_WORKSHOP_DONE"))
                    .singleElement().satisfies(row->{
                        assertThat(row.get("warehouse_name")).isEqualTo("B仓");
                        assertThat(row.get("line_key")).isEqualTo(line+"~"+postingB);
                        assertThat(row.get("item_id")).isEqualTo(postingB);
                        assertThat(row.get("quantity").toString()).isEqualTo("5.0000");
                    });
            assertThat(badges.badgeCounts(onlyA).pendingIssue()).isZero();
            assertThat(badges.badgeCounts(onlyB).pendingIssue()).isEqualTo(1);
            var requests=new WorkshopMaterialRequisitionService(db,null,null,null,scope,permissions,null,null,null,current,null);
            assertThat(requests.list(null,null,null,onlyA,1,50,WarehouseTaskCenterContracts.TaskView.HISTORY).getItems()).isEmpty();
            var requestHistory=requests.list(null,null,null,onlyB,1,50,WarehouseTaskCenterContracts.TaskView.HISTORY);
            assertThat(requestHistory.getItems()).singleElement().satisfies(row->{
                assertThat(row.lines().getFirst().fulfilledQty()).isEqualByComparingTo("5");
                assertThat(row.documents()).singleElement().satisfies(doc->assertThat(doc.leafWarehouseId()).isEqualTo(b));
            });
            // One original line can be split over two leaves. Its history shows 2+3, never 5+5.
            db.update("UPDATE workshop_material_requisition_postings SET qty=3 WHERE id=:id",Map.of("id",postingB));
            UUID postingA=posting(db,line,a,"2");
            assertThat(outbound(db,scope,onlyA)).singleElement().satisfies(row->{
                assertThat(row.get("item_id")).isEqualTo(postingA);
                assertThat(row.get("quantity").toString()).isEqualTo("2.0000");
            });
            assertThat(requests.list(null,null,null,onlyA,1,50,WarehouseTaskCenterContracts.TaskView.HISTORY).getItems())
                    .singleElement().satisfies(row->{
                        assertThat(row.lines().getFirst().fulfilledQty()).isEqualByComparingTo("2");
                        assertThat(row.documents()).singleElement().satisfies(doc->{
                            assertThat(doc.leafWarehouseId()).isEqualTo(a);
                            assertThat(doc.qty()).isEqualByComparingTo("2");
                        });
                    });
            var both=outbound(db,scope,new WarehouseTaskScope(true,List.of(a,b),false));
            assertThat(both).hasSize(3);
            assertThat(both.stream().filter(row->row.get("status").equals("DRAW_WORKSHOP_DONE"))
                    .map(row->(java.math.BigDecimal)row.get("quantity")).reduce(java.math.BigDecimal.ZERO,java.math.BigDecimal::add))
                    .isEqualByComparingTo("5");
            // Legacy original-line deep links expand only authorized posting IDs; canonical links are exact.
            var plan=plan(scope,onlyB);
            var parameters=new MapSqlParameterSource(plan.parameters()).addValue("rowSource","DRAW")
                    .addValue("rowRecord","WORKSHOP_REQUISITION").addValue("rowId",request)
                    .addValue("identityLineKey",line.toString());
            assertThat(db.queryForList(plan.identitySql(true),parameters)).hasSize(1);
            var document=new WarehouseTaskCenterContracts.Row("",request,"DRAW","WORKSHOP_REQUISITION","WM",null,null,
                    "","","",1,"DRAW_WORKSHOP_DONE","","","HISTORY_DETAIL",request,false,Map.of());
            parameters.addValue("documentId",request).addValue("detailLineKey",line.toString());
            var detail=db.queryForList(plan.cte()+" SELECT * FROM ("+WarehouseOutboundTaskCenterQueryService.scopedPhysicalLines(document)+") detail",parameters);
            assertThat(detail).singleElement().satisfies(row->{
                assertThat(row.get("id")).isEqualTo(postingB);
                assertThat(row.get("requested_qty")).isNull();
            });
            parameters.addValue("detailLineKey",line+"~"+postingA);
            assertThat(db.queryForList(plan.cte()+" SELECT * FROM ("+WarehouseOutboundTaskCenterQueryService.scopedPhysicalLines(document)+") detail",parameters)).isEmpty();
            db.update("UPDATE workshop_material_requisitions SET kind='RETURN' WHERE id=:id",Map.of("id",request));
            var inboundScope=WarehouseWorkshopMaterialTaskProjection.scope(true,scope,onlyB);
            var inbound=db.queryForList("SELECT * FROM ("+WarehouseWorkshopMaterialTaskProjection.inbound(inboundScope)+") rows",inboundScope.parameters());
            assertThat(inbound).hasSize(2);
            assertThat(inbound).allSatisfy(row->assertThat(row.get("warehouse_name")).isEqualTo("B仓"));
            assertThat(badges.badgeCounts(onlyA).pendingReturn()).isZero();
            assertThat(badges.badgeCounts(onlyB).pendingReturn()).isEqualTo(1);
            connection.rollback();
        }
    }

    private static UUID posting(NamedParameterJdbcTemplate db,UUID line,UUID leaf,String qty) {
        UUID posting=UUID.randomUUID(),item=UUID.randomUUID(),document=UUID.randomUUID(),period=UUID.randomUUID();
        db.update("INSERT INTO workshop_material_periods(id,period_no,start_date,status,close_state)"
                + " VALUES(:id,1,'2026-10-22','OPEN','IDLE')",Map.of("id",period));
        db.update("INSERT INTO stock_documents(id,bill_no) VALUES(:id,:bill)",Map.of("id",document,"bill","POST-"+posting));
        db.update("INSERT INTO stock_document_items(id,doc_id) VALUES(:id,:doc)",Map.of("id",item,"doc",document));
        db.update("INSERT INTO workshop_material_requisition_postings(id,line_id,stock_document_item_id,leaf_warehouse_id,qty,period_id)"
                + " VALUES(:id,:line,:item,:leaf,:qty,:period)",Map.of("id",posting,"line",line,"item",item,"leaf",leaf,"qty",new java.math.BigDecimal(qty),"period",period));
        return posting;
    }
    private static WarehouseOutboundTaskCenterSql.Plan plan(WorkshopMaterialScope materials,WarehouseTaskScope warehouses) {
        var access=new WarehouseOutboundTaskCenterSql.Access(false,false,false,false,false,new OwnerScope(true,Set.of()),
                WarehouseWorkshopMaterialTaskProjection.scope(true,materials,warehouses));
        var filter=new WarehouseTaskCenterContracts.Filter("DRAW",null,null,null,null,null,null,1,50,null,null,WarehouseTaskCenterContracts.TaskView.ALL);
        return WarehouseOutboundTaskCenterSql.build(filter,access,warehouses,"");
    }
    private static List<Map<String,Object>> outbound(NamedParameterJdbcTemplate db,WorkshopMaterialScope materials,WarehouseTaskScope warehouses) {
        var plan=plan(materials,warehouses);
        return db.queryForList(plan.rowsSql(),new MapSqlParameterSource(plan.parameters()).addValue("limit",50).addValue("offset",0));
    }
}
