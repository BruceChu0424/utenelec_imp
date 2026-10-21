package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.application.port.WorkshopMaterialNoticePort;
import com.uten.imp.application.port.WorkshopMaterialSetupPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.TaskView;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Read projections use actual migrated columns and the original warehouse scope predicate. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopMaterialRequisitionLifecyclePostgresTest {
    @Test
    void materialLinesHaveIndependentScopedPaginationWithoutChangingTheirRequisition() throws Exception {
        try(var database=MigratedSchemaBaseline.openDatabase("workshop_task_lifecycle");var connection=database.openConnection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {
                statement.execute("CREATE SCHEMA workshop_task_oracle");
                statement.execute("SET LOCAL search_path=workshop_task_oracle,public");
            }
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,
                    "workshop_material_requisitions","workshop_material_requisition_lines","workshop_material_requisition_postings",
                    "workshop_material_periods","departments","warehouses","employees","users","goods");
            var jdbc=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
            UUID workshop=UUID.randomUUID(),bin=UUID.randomUUID(),warehouse=UUID.randomUUID(),outside=UUID.randomUUID(),goods=UUID.randomUUID(),secondGoods=UUID.randomUUID();
            jdbc.update("INSERT INTO departments(id,name) VALUES(:id,'注塑车间')",Map.of("id",workshop));
            jdbc.update("INSERT INTO warehouses(id,name) VALUES(:id,'注塑内料仓')",Map.of("id",bin));
            jdbc.update("INSERT INTO goods(id,code,name) VALUES(:id,'MATERIAL','物料')",Map.of("id",goods));
            jdbc.update("INSERT INTO goods(id,code,name) VALUES(:id,'MATERIAL-B','物料二')",Map.of("id",secondGoods));
            for(String state:List.of("PENDING","DONE","CANCELLED","HIDDEN")) {
                UUID id=UUID.randomUUID();
                jdbc.update("""
                        INSERT INTO workshop_material_requisitions(id,request_no,kind,origin,status,
                          workshop_department_id,bin_warehouse_id,requested_at,row_version)
                        VALUES(:id,:number,'ISSUE','WORKSHOP_REQUEST',:status,:workshop,:bin,now(),0)
                        """,Map.of("id",id,"number",state,"status",state.equals("HIDDEN")?"DONE":state,"workshop",workshop,"bin",bin));
                jdbc.update("""
                        INSERT INTO workshop_material_requisition_lines(id,requisition_id,line_no,goods_id,
                          suggested_leaf_warehouse_id,requested_qty,fulfilled_qty)
                        VALUES(:id,:request,1,:goods,:warehouse,5,0)
                        """,Map.of("id",UUID.randomUUID(),"request",id,"goods",goods,"warehouse",state.equals("HIDDEN")?outside:warehouse));
                jdbc.update("""
                        INSERT INTO workshop_material_requisition_lines(id,requisition_id,line_no,goods_id,
                          suggested_leaf_warehouse_id,requested_qty,fulfilled_qty)
                        VALUES(:id,:request,2,:goods,:warehouse,3,0)
                        """,Map.of("id",UUID.randomUUID(),"request",id,"goods",secondGoods,"warehouse",state.equals("HIDDEN")?outside:warehouse));
            }
            var current=mock(SecurityContextCurrentUser.class);
            when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"admin",Set.of(),false,true,true)));
            var scope=new WorkshopMaterialScope(jdbc,current);
            var service=new WorkshopMaterialRequisitionService(jdbc,mock(WorkshopMaterialBinSupport.class),mock(WorkshopMaterialStockGateway.class),
                    mock(WorkshopMaterialCommandLedger.class),scope,mock(WorkshopMaterialPermissions.class),mock(WorkshopMaterialCountService.class),
                    mock(DocNumberService.class),mock(WorkshopMaterialNoticePort.class),current,mock(WorkshopMaterialSetupPort.class));
            var warehouses=new WarehouseTaskScope(true,List.of(warehouse),false);
            var badgePermissions=mock(WorkshopMaterialPermissions.class);
            when(badgePermissions.has(WorkshopMaterialPermissions.ISSUE)).thenReturn(true);
            var badges=new WorkshopMaterialPositionQueryService(jdbc,null,scope,badgePermissions,null,null);
            var active=service.list(null,null,null,warehouses,1,1);
            assertThat(active.getTotal()).isEqualTo(2);
            assertThat(badges.badgeCounts(warehouses).pendingIssue()).isEqualTo(active.getTotal());
            assertThat(badges.badgeCounts(warehouses).pendingReturn()).isZero();
            assertThat(active.getTotalPages()).isEqualTo(2);
            assertThat(active.getItems().getFirst().lines()).hasSize(1);
            var activeSecond=service.list(null,null,null,warehouses,2,1);
            assertThat(activeSecond.getItems().getFirst().id()).isEqualTo(active.getItems().getFirst().id());
            assertThat(activeSecond.getItems().getFirst().lines()).hasSize(1);
            assertThat(activeSecond.getItems().getFirst().lines().getFirst().id())
                    .isNotEqualTo(active.getItems().getFirst().lines().getFirst().id());
            assertThat(active.getItems().getFirst().lines().getFirst().requestedQty()).isEqualByComparingTo("5");
            assertThat(activeSecond.getItems().getFirst().lines().getFirst().requestedQty()).isEqualByComparingTo("3");
            assertThat(service.detail(active.getItems().getFirst().id()).lines()).hasSize(2);
            assertThat(active.getItems()).extracting(WorkshopMaterialDtos.RequisitionView::status).containsExactly("PENDING");
            var history=service.list(null,null,null,warehouses,1,2,TaskView.HISTORY);
            assertThat(history.getTotal()).isEqualTo(4);
            assertThat(history.getTotalPages()).isEqualTo(2);
            assertThat(history.getItems()).noneMatch(row->row.requestNo().equals("HIDDEN"));
            var second=service.list(null,null,null,warehouses,2,2,TaskView.HISTORY);
            assertThat(java.util.stream.Stream.concat(history.getItems().stream(),second.getItems().stream()).map(WorkshopMaterialDtos.RequisitionView::status))
                    .containsExactlyInAnyOrder("DONE","DONE","CANCELLED","CANCELLED");
            assertThat(service.list("PENDING",null,null,warehouses,1,20,TaskView.HISTORY).getTotal()).isZero();
            assertThat(service.list(null,null,null,warehouses,1,1,TaskView.ACTIVE,"  pending  ").getTotal()).isEqualTo(2);
            assertThat(service.list(null,null,null,warehouses,1,1,TaskView.HISTORY,"pending").getTotal()).isZero();
            var searched=service.list(null,null,null,warehouses,2,1,TaskView.HISTORY,"物料");
            assertThat(searched.getTotal()).isEqualTo(4);
            assertThat(searched.getTotalPages()).isEqualTo(4);
            assertThat(searched.getItems()).hasSize(1);
            assertThat(service.list(null,null,null,warehouses,1,20,TaskView.HISTORY,"MATERIAL").getTotal()).isEqualTo(4);
            assertThat(service.list(null,null,null,warehouses,1,20,TaskView.ACTIVE,"注塑").getTotal()).isEqualTo(2);
            assertThat(service.list(null,null,null,warehouses,1,20,TaskView.HISTORY,"注塑").getTotal()).isEqualTo(4);
            assertThat(service.list(null,null,null,warehouses,1,20,TaskView.HISTORY,"HIDDEN").getTotal()).isZero();
            assertThat(service.list(null,null,null,warehouses,1,20,TaskView.HISTORY,"  ").getTotal()).isEqualTo(4);
            var onlyMatchingLine=service.list(null,null,null,warehouses,1,20,TaskView.ACTIVE,"物料二");
            assertThat(onlyMatchingLine.getTotal()).isEqualTo(1);
            assertThat(onlyMatchingLine.getItems().getFirst().lines()).hasSize(1);
            assertThat(onlyMatchingLine.getItems().getFirst().lines().getFirst().goodsId()).isEqualTo(secondGoods);
            jdbc.update("UPDATE workshop_material_requisitions SET kind='RETURN' WHERE status='PENDING'",Map.of());
            assertThat(badges.badgeCounts(warehouses).pendingIssue()).isZero();
            assertThat(badges.badgeCounts(warehouses).pendingReturn()).isEqualTo(2);
            assertThat(badges.badgeCounts(new WarehouseTaskScope(true,List.of(outside),false)).pendingReturn()).isZero();
            connection.rollback();
        }
    }
}
