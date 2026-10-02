package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.InventoryMovementCostReference.WorkshopMaterialBin;
import com.uten.imp.application.port.InventoryMovementCostReference.WorkshopMaterialBinKind;
import com.uten.imp.application.port.WorkshopMaterialSetupPort;
import com.uten.imp.application.port.WorkshopStockCountPostingPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockBalanceRepository;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.stock.weight.WeightMath;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.LinkedHashMap;
import java.util.Objects;
import java.util.UUID;

/** Approval evidence -> immutable opening/adjustment source -> stock and value, all in one transaction. */
@Component
public class WorkshopStockCountPostingAdapter implements WorkshopStockCountPostingPort {
    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialScope scope;
    private final StockService stock;
    private final StockBalanceRepository balances;
    private final WorkshopMaterialSetupPort materialSetup;
    private final SecurityContextCurrentUser currentUser;
    private final WorkshopMaterialPeriodService periods;

    public WorkshopStockCountPostingAdapter(NamedParameterJdbcTemplate db, WorkshopMaterialBinSupport bins,
            WorkshopMaterialScope scope, StockService stock, StockBalanceRepository balances,
            WorkshopMaterialSetupPort materialSetup, SecurityContextCurrentUser currentUser,
            WorkshopMaterialPeriodService periods) {
        this.db=db; this.bins=bins; this.scope=scope; this.stock=stock; this.balances=balances;
        this.materialSetup=materialSetup; this.currentUser=currentUser;
        this.periods=periods;
    }

    @Override
    @Transactional(readOnly=true)
    public boolean canAccessWarehouse(UUID warehouseId) {
        if (warehouseId==null) return false;
        var settings=bins.settingsByBin(warehouseId);
        return settings!=null && scope.canSee(settings.workshopDepartmentId());
    }

    @Override
    @Transactional(readOnly=true)
    public java.util.Set<UUID> accessibleWarehouses(List<UUID> warehouseIds) {
        if (warehouseIds.isEmpty()) return java.util.Set.of();
        var params = new MapSqlParameterSource("warehouses", warehouseIds);
        String predicate = scope.predicate("settings.workshop_department_id", params);
        // Keep settingsByBin's existence/join rules, including disabled historical bins.
        return java.util.Set.copyOf(db.queryForList("""
                SELECT settings.periodic_bin_warehouse_id
                FROM workshop_material_settings settings
                JOIN departments workshop ON workshop.id = settings.workshop_department_id
                WHERE settings.periodic_bin_warehouse_id IN (:warehouses) AND
                """ + predicate, params, UUID.class));
    }

    @Override
    @Transactional(readOnly=true)
    public boolean canAccessWarehouseForUser(UUID warehouseId, UUID userId) {
        if(warehouseId==null || userId==null) return false;
        var settings=bins.settingsByBin(warehouseId);
        return settings!=null && scope.canSeeForUser(settings.workshopDepartmentId(),userId);
    }

    @Override
    @Transactional(propagation=Propagation.MANDATORY)
    @PreAuthorize("hasAuthority('stock:count:warehouse_review')")
    public PostingResult postApproved(UUID requestId, UUID approvalEventId) {
        List<Map<String,Object>> requests=db.queryForList("""
                SELECT request.warehouse_id, request.reviewed_by, request.reason, request.row_version,
                       event.request_version
                FROM stock_count_requests request JOIN stock_count_request_events event ON event.id=request.approval_event_id
                WHERE request.id=:request AND request.status='APPROVED' AND request.review_route='WAREHOUSE'
                  AND event.id=:event AND event.action='APPROVE' AND event.request_id=request.id
                  AND event.actor_id=request.reviewed_by AND event.request_version=request.row_version
                FOR UPDATE OF request
                """, Map.of("request",requestId,"event",approvalEventId));
        if(requests.size()!=1) throw conflict("内料仓盘点缺少有效的仓库审核记录");
        Map<String,Object> request=requests.getFirst();
        UUID actor=currentUser.requireId();
        if(!actor.equals(request.get("reviewed_by"))) throw conflict("只有本次审核人可以提交盘点过账");
        UUID warehouse=(UUID)request.get("warehouse_id");
        var settings=bins.settingsByBin(warehouse);
        if(settings==null) throw conflict("此仓库不是车间内料仓");
        scope.requireWorkshop(settings.workshopDepartmentId());
        List<Map<String,Object>> lines=db.queryForList("""
                SELECT line.* FROM stock_count_request_lines line WHERE line.request_id=:request ORDER BY line.line_no,line.id
                """,Map.of("request",requestId));
        if(lines.isEmpty()) throw conflict("盘点申请没有明细");
        List<LinePosting> existing=db.query("""
                SELECT posting.line_id,posting.id,posting.movement_id FROM workshop_material_count_adjustment_postings posting
                JOIN stock_count_request_lines line ON line.id=posting.line_id
                WHERE posting.request_id=:request ORDER BY line.line_no,line.id
                """,Map.of("request",requestId),(rs,n)->new LinePosting(rs.getObject(1,UUID.class),rs.getObject(2,UUID.class),rs.getObject(3,UUID.class)));
        if(!existing.isEmpty()) {
            if(existing.size()!=lines.size()) throw conflict("盘点过账记录不完整，请核对原审核结果");
            return new PostingResult(existing);
        }
        var period=periods.openForApprovedStockCount(settings.workshopDepartmentId(),warehouse,approvalEventId);
        LocalDate today=BusinessTime.today();
        stock.lockInventory(lines.stream().map(line->new InventoryKey((UUID)line.get("goods_id"),(UUID)line.get("color_id"))).toList());
        Map<UUID,WorkshopMaterialSetupPort.Setup> setups=new LinkedHashMap<>();
        for(Map<String,Object> line:lines) {
            UUID goods=(UUID)line.get("goods_id");
            var material=bins.material(goods);
            if(!material.periodic()) {
                String basis=(String)line.get("material_setup_basis");
                if(basis==null) throw conflict("「"+material.label()+"」首次录入内料仓需在审核页确认材料用途");
                var setup=new WorkshopMaterialSetupPort.Setup(goods,((Number)line.get("goods_version")).longValue(),basis);
                var previous=setups.putIfAbsent(goods,setup);
                if(previous!=null && !previous.equals(setup)) throw conflict("同一材料的首次用途或版本不一致");
            }
        }
        if(!setups.isEmpty()) materialSetup.setup(List.copyOf(setups.values()),"WM-COUNT-"+approvalEventId);
        List<UUID> goodsIds=lines.stream().map(line->(UUID)line.get("goods_id")).distinct().toList();
        for(var goods:db.queryForList("SELECT id,status,is_deleted FROM goods WHERE id IN (:ids) ORDER BY id FOR UPDATE",Map.of("ids",goodsIds))) {
            if(!"使用".equals(goods.get("status")) || Boolean.TRUE.equals(goods.get("is_deleted"))) throw conflict("盘点材料已停用或删除");
        }
        List<LinePosting> posted=new ArrayList<>();
        for(Map<String,Object> line:lines) {
            UUID goods=(UUID)line.get("goods_id"), color=(UUID)line.get("color_id"), unit=(UUID)line.get("unit_id");
            var material=bins.periodicMaterial(goods);
            if(!Objects.equals(material.unitId(),unit)) throw conflict("材料基本单位已变化，请退回申请重新盘点");
            Map<String,Object> unitFact=db.queryForMap("""
                    SELECT unit.status,unit.is_deleted,profile.measurement_dimension,
                           fn_weight_unit_kg_factor(profile.mass_unit_code) AS factor
                    FROM units unit JOIN unit_measurement_profiles profile ON profile.unit_id=unit.id
                    WHERE unit.id=:unit FOR SHARE OF unit,profile
                    """,Map.of("unit",unit));
            if(!"使用".equals(unitFact.get("status")) || Boolean.TRUE.equals(unitFact.get("is_deleted"))
                    || !"MASS".equals(unitFact.get("measurement_dimension"))) throw conflict("材料重量单位已停用或变化");
            BigDecimal factor=number(unitFact.get("factor")), frozenFactor=number(line.get("kg_per_base_unit"));
            if(!same(factor,frozenFactor)) throw conflict("材料重量换算已变化，请退回申请重新盘点");
            BigDecimal expected=number(line.get("expected_qty")), target=number(line.get("target_qty"));
            BigDecimal expectedWeight=number(line.get("expected_weight_kg")), targetWeight=number(line.get("target_weight_kg"));
            var physical=balances.readPhysicalSnapshot(warehouse,goods,color);
            if(physical.size()>1) throw conflict("库存维度存在重复余额，请先核对");
            BigDecimal qty=physical.isEmpty()?BigDecimal.ZERO:physical.getFirst().getQty();
            BigDecimal weight=physical.isEmpty()?null:physical.getFirst().getWeight();
            boolean estimated=!physical.isEmpty() && Boolean.TRUE.equals(physical.getFirst().getWeightEstimated());
            if(!same(qty,expected) || !same(weight,expectedWeight)
                    || estimated!=Boolean.TRUE.equals(line.get("expected_weight_estimated"))) {
                throw conflict("库存数量或重量在提交后已变化，请退回申请重新盘点");
            }
            if(target==null || target.signum()<0) throw conflict("盘点目标数量无效");
            if(factor!=null && !same(WeightMath.times(target,factor),targetWeight)) {
                throw conflict("按重量计量的材料，目标重量必须与数量和单位换算一致");
            }
            if(factor==null && Boolean.TRUE.equals(line.get("weight_changed"))) {
                throw conflict("这种重量单位尚未登记换算，不能单独修改重量");
            }
            BigDecimal delta=target.subtract(expected);
            if(delta.signum()==0 && !same(weight,targetWeight)) {
                throw conflict("重量计量材料的数量没有变化，不能单独覆盖历史重量；请按实盘重量换算目标数量后重新提交");
            }
            MapSqlParameterSource params=new MapSqlParameterSource("bin",warehouse).addValue("goods",goods).addValue("color",color);
            boolean noHistory=!Boolean.TRUE.equals(db.queryForObject("""
                    SELECT EXISTS(SELECT 1 FROM v_workshop_material_bin_ledger WHERE bin_warehouse_id=:bin
                        AND goods_id=:goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                        UNION ALL SELECT 1 FROM stock_movements WHERE warehouse_id=:bin
                        AND goods_id=:goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid))
                    """,params,Boolean.class));
            String kind=period.no()==1 && expected.signum()==0 && target.signum()>0 && noHistory?"OPENING":"ADJUSTMENT";
            UUID posting=UUID.randomUUID(), lineId=(UUID)line.get("id");
            params.addValue("id",posting).addValue("request",requestId).addValue("line",lineId)
                    .addValue("event",approvalEventId).addValue("period",period.id()).addValue("unit",unit)
                    .addValue("kind",kind).addValue("before",expected).addValue("target",target).addValue("date",today).addValue("actor",actor);
            db.update("""
                    INSERT INTO workshop_material_count_adjustment_postings(id,request_id,line_id,approval_event_id,
                        period_id,bin_warehouse_id,goods_id,color_id,unit_id,kind,before_qty,target_qty,business_date,created_by)
                    VALUES (:id,:request,:line,:event,:period,:bin,:goods,:color,:unit,:kind,:before,:target,:date,:actor)
                    """,params);
            UUID movement=null;
            if(delta.signum()!=0) {
                WorkshopMaterialBinKind reference="OPENING".equals(kind)?WorkshopMaterialBinKind.COUNT_OPENING
                        :delta.signum()>0?WorkshopMaterialBinKind.COUNT_ADJUSTMENT_IN:WorkshopMaterialBinKind.COUNT_ADJUSTMENT_OUT;
                movement=stock.recordMovement(new StockService.MovementRequest(BusinessTime.startOfDay(today),
                        StockService.TYPE_WORKSHOP_APPROVED_COUNT,"STOCK_COUNT_REQUEST",requestId,lineId,goods,color,warehouse,
                        delta.signum()>0?StockService.DIR_IN:StockService.DIR_OUT,delta.abs(),unit,BigDecimal.ONE,null,
                        "OPENING".equals(kind)?"批准盘点：上线实物期初":"批准盘点：库存账面修正",null,
                        new WorkshopMaterialBin(posting,reference))).movementId();
                db.update("UPDATE workshop_material_count_adjustment_postings SET movement_id=:movement WHERE id=:id",
                        Map.of("movement",movement,"id",posting));
            }
            posted.add(new LinePosting(lineId,posting,movement));
        }
        return new PostingResult(List.copyOf(posted));
    }

    private static BigDecimal number(Object value) { return value==null?null:value instanceof BigDecimal b?b:new BigDecimal(value.toString()); }
    private static boolean same(BigDecimal a,BigDecimal b) { return a==null?b==null:b!=null&&a.compareTo(b)==0; }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT,message); }
}
