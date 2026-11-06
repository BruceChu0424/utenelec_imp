package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.web.*;
import com.uten.imp.security.CurrentAuthorityGuard;
import org.springframework.jdbc.core.namedparam.*;
import org.springframework.stereotype.Service;
import java.util.*;

/** Product-level recognition is shared across all selected workshops, never first-workshop ownership. */
@Service
public class WorkshopPendingSummaryService {
    public record ProductSummary(UUID productGoodsId,String productCode,String productName,
                                 List<UUID> workshopIds,List<String> workshopNames,int segmentCount,
                                 boolean choiceRequired,boolean alsoOrderMaterialsAllowed) { }
    private final NamedParameterJdbcTemplate db;
    private final VersionedSummaryPages pages;
    private final WorkshopMaterialChoiceAdapter choices;
    private final WorkshopMaterialScope scope;
    public WorkshopPendingSummaryService(NamedParameterJdbcTemplate db,VersionedSummaryPages pages,
                                         WorkshopMaterialChoiceAdapter choices,WorkshopMaterialScope scope) {
        this.db=db;this.pages=pages;this.choices=choices;this.scope=scope;
    }
    private List<UUID> ids(List<UUID> input) {
        if(input==null||input.isEmpty()||input.size()>WorkshopMaterialSettingsService.BATCH_LIMIT||input.stream().anyMatch(Objects::isNull))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择最多50个车间");
        return input.stream().distinct().sorted().toList();
    }
    private void authorize(List<UUID> ids) {
        CurrentAuthorityGuard.requireAll("workshop_material:setup");
        for(UUID id:ids) {
            var names=db.queryForList("SELECT workshop.name FROM departments workshop JOIN departments production ON production.id=workshop.parent_id AND production.code='DEPT_PROD' WHERE workshop.id=:id AND NOT workshop.is_deleted",Map.of("id",id),String.class);
            if(names.size()!=1)throw new ApiException(ErrorCode.VALIDATION_FAILED,"内料仓只能给生产部下的有效车间开通");
            scope.requireWorkshop(id);
        }
    }
    private static String pendingSql() {
        String source=WorkshopMaterialChoiceAdapter.IN_PROGRESS_NEED_CHOICE_SQL;
        return source.substring(0,source.lastIndexOf("ORDER BY"))
                .replace("SELECT segment.id, segment.product_goods_id","SELECT segment.id,segment.product_goods_id,segment.workshop_department_id")
                .replace("segment.workshop_department_id = :workshop","segment.workshop_department_id IN (:workshops)");
    }
    private VersionedSummaryPages.Request request(List<UUID> ids,int page,int size,String revision) {
        return new VersionedSummaryPages.Request("periodic-pending","native_workshop_tasks",Map.of("workshopIds",ids),"all",page,size,1000,revision);
    }
    public VersionedSummaryPages.Page<ProductSummary> summaries(List<UUID> input,int page,int size,String revision) {
        List<UUID> ids=ids(input);var params=new MapSqlParameterSource("workshops",ids);
        return pages.page(request(ids,page,size,revision),()->authorize(ids),
                ()->db.queryForObject("SELECT count(DISTINCT product_goods_id) FROM ("+pendingSql()+") pending",params,Long.class),
                (p,n)-> {
                    params.addValue("limit",n).addValue("offset",Math.multiplyExact((long)p-1,n));
                    return db.query("WITH pending AS("+pendingSql()+"""
                            ), grouped AS(SELECT product_goods_id,count(*)::int AS segment_count FROM pending GROUP BY product_goods_id)
                            SELECT product.id,product.code,product.name,grouped.segment_count,NOT fn_goods_has_bom(product.id) AS also_order,
                              ARRAY(SELECT DISTINCT row.workshop_department_id FROM pending row WHERE row.product_goods_id=product.id ORDER BY row.workshop_department_id) AS workshops,
                              ARRAY(SELECT department.name FROM (SELECT DISTINCT row.workshop_department_id FROM pending row WHERE row.product_goods_id=product.id) selected JOIN departments department ON department.id=selected.workshop_department_id ORDER BY selected.workshop_department_id) AS workshop_names
                            FROM grouped JOIN goods product ON product.id=grouped.product_goods_id
                            ORDER BY product.code,product.id LIMIT :limit OFFSET :offset
                            """,params,(rs,row)->new ProductSummary(rs.getObject("id",UUID.class),rs.getString("code"),rs.getString("name"),
                                    Arrays.stream((Object[])rs.getArray("workshops").getArray()).map(v->UUID.fromString(v.toString())).toList(),
                                    Arrays.stream((Object[])rs.getArray("workshop_names").getArray()).map(Object::toString).toList(),
                                    rs.getInt("segment_count"),true,rs.getBoolean("also_order")));
                });
    }
    public VersionedSummaryPages.Snapshot<WorkshopMaterialDtos.PendingProduct> product(List<UUID> input,UUID product,int summarySize,String revision) {
        List<UUID> ids=ids(input);
        return pages.read(request(ids,1,summarySize,revision),()->authorize(ids),()-> {
            var rows=db.queryForList("SELECT pending.*,department.name AS workshop_name FROM ("+pendingSql()+") pending JOIN departments department ON department.id=pending.workshop_department_id WHERE pending.product_goods_id=:product ORDER BY pending.workshop_department_id,pending.id",
                    new MapSqlParameterSource("workshops",ids).addValue("product",product));
            if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"产品不在当前车间待认料范围");
            var names=new LinkedHashMap<UUID,String>();var segments=new ArrayList<UUID>();
            for(var row:rows) { names.put((UUID)row.get("workshop_department_id"),(String)row.get("workshop_name"));segments.add((UUID)row.get("id")); }
            var first=names.keySet().iterator().next();
            WorkshopMaterialChoicePort.PendingChoice original=choices.pendingRow(first,product,segments,true,false);
            return new WorkshopMaterialDtos.PendingProduct(original,List.copyOf(names.keySet()),List.copyOf(names.values()));
        });
    }
}
