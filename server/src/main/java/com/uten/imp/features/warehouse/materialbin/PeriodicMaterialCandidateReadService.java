package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.web.*;
import com.uten.imp.common.inventory.PeriodicMaterialCandidateSql;
import com.uten.imp.common.inventory.PeriodicMaterialUnits;
import com.uten.imp.security.CurrentAuthorityGuard;
import org.springframework.jdbc.core.namedparam.*;
import org.springframework.stereotype.Service;
import java.util.*;

/** All legal candidate summaries once per query; options are never repeated for every product summary. */
@Service
public class PeriodicMaterialCandidateReadService {
    public record Candidate(UUID goodsId,String code,String name,UUID colorId,String colorName,String unitName,boolean gramsConvertible,boolean used) { }
    private final NamedParameterJdbcTemplate db;
    private final VersionedSummaryPages pages;
    private final WorkshopMaterialScope scope;
    public PeriodicMaterialCandidateReadService(NamedParameterJdbcTemplate db,VersionedSummaryPages pages,WorkshopMaterialScope scope) {
        this.db=db;this.pages=pages;this.scope=scope;
    }
    public VersionedSummaryPages.Page<Candidate> candidates(List<UUID> input,boolean preparation,int page,int size,String revision) {
        if(input==null||input.isEmpty()||input.size()>50||input.stream().anyMatch(Objects::isNull))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择完整车间范围");
        List<UUID> ids=input.stream().distinct().sorted().toList();
        Runnable authorize=()-> {
            if(preparation)CurrentAuthorityGuard.requireAll("goods:view","workshop_material:setup");
            else if(!CurrentAuthorityGuard.hasAll("workshop_material:setup"))CurrentAuthorityGuard.requireAll("workshop_material:view");
            for(UUID workshop:ids) {
                if(db.queryForList("SELECT id FROM departments WHERE id=:id AND NOT is_deleted",Map.of("id",workshop),UUID.class).size()!=1)
                    throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择有效车间");
                if(!preparation)scope.requireWorkshop(workshop);
            }
        };
        var request=new VersionedSummaryPages.Request(preparation?"periodic-candidate-catalog":"periodic-material-candidates",preparation?"master_goods":"native_workshop_tasks",
                Map.of("workshopIds",ids,"preparation",preparation),"all",page,size,1000,revision);
        var params=new MapSqlParameterSource("workshops",ids);
        String from=PeriodicMaterialCandidateSql.FROM;
        return pages.page(request,authorize,()->db.queryForObject("SELECT count(*) "+from,params,Long.class),
                (p,n)->db.query("SELECT material.id,material.code,material.name,material.color_id,color.name AS color_name,unit.name AS unit_name,"
                        +(preparation?"FALSE AS used ":"EXISTS(SELECT 1 FROM v_workshop_material_bin_ledger ledger JOIN workshop_material_settings settings ON settings.periodic_bin_warehouse_id=ledger.bin_warehouse_id WHERE settings.workshop_department_id IN (:workshops) AND ledger.goods_id=material.id) AS used ")
                        +from+(preparation?" ORDER BY material.code,material.id":" ORDER BY used DESC,material.code,material.id")+" LIMIT :limit OFFSET :offset",
                        params.addValue("limit",n).addValue("offset",Math.multiplyExact((long)p-1,n)),(rs,row)->new Candidate(rs.getObject("id",UUID.class),rs.getString("code"),rs.getString("name"),rs.getObject("color_id",UUID.class),rs.getString("color_name"),rs.getString("unit_name"),PeriodicMaterialUnits.gramsPerUnit(rs.getString("unit_name"))!=null,rs.getBoolean("used"))));
    }
}
