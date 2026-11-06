package com.uten.imp.features.master.goods;

import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.common.util.DecimalText;
import com.uten.imp.common.web.*;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationView;
import com.uten.imp.security.CurrentAuthorityGuard;
import org.springframework.jdbc.core.namedparam.*;
import org.springframework.stereotype.Service;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.*;

/** Lean all-product summaries; only explicitly opened products create detailed editors. */
@Service
public class PeriodicPreparationSummaryService {
    public record Summary(@com.fasterxml.jackson.annotation.JsonUnwrapped VersionedSummaryPages.Page<Map<String,Object>> page,Instant windowAsOf) { }
    public record Detail(@com.fasterxml.jackson.annotation.JsonUnwrapped VersionedSummaryPages.Snapshot<PreparationView> snapshot,Instant windowAsOf) { }
    private final NamedParameterJdbcTemplate db;
    private final VersionedSummaryPages pages;
    private final GoodsPeriodicBomPreparationService detail;
    public PeriodicPreparationSummaryService(NamedParameterJdbcTemplate db,VersionedSummaryPages pages,
                                             GoodsPeriodicBomPreparationService detail) {
        this.db=db;this.pages=pages;this.detail=detail;
    }
    private void authorize(UUID workshop) {
        CurrentAuthorityGuard.requireAll("goods:view","workshop_material:setup");
        if(workshop==null||db.queryForList("SELECT id FROM departments WHERE id=:id AND NOT is_deleted",Map.of("id",workshop),UUID.class).size()!=1)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择有效车间");
    }
    private VersionedSummaryPages.Request request(UUID workshop,int page,int size,String revision,Instant windowAsOf) {
        if(workshop==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择车间");
        return new VersionedSummaryPages.Request("periodic-preparation","master_goods",Map.of("workshopId",workshop,"windowAsOf",windowAsOf.toString()),"all",page,size,1000,revision);
    }
    private static Instant window(String revision,String raw) {
        if(revision==null) {
            if(raw!=null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"首批时间由服务端确定");
            return Instant.now();
        }
        try { return Instant.parse(Objects.requireNonNull(raw)); }
        catch(RuntimeException invalid) { throw new ApiException(ErrorCode.VALIDATION_FAILED,"请保留首批准备范围时间"); }
    }
    public Summary summaries(UUID workshop,int page,int size,String revision,String rawWindow) {
        Instant asOf=window(revision,rawWindow);
        var params=new MapSqlParameterSource("workshop",workshop).addValue("windowAsOf",java.sql.Timestamp.from(asOf));
        var result=pages.page(request(workshop,page,size,revision,asOf),()->authorize(workshop),
                ()->db.queryForObject(PeriodicPreparationReadSql.UNIVERSE+" SELECT count(*) "+PeriodicPreparationReadSql.ELIGIBLE,params,Long.class),
                (p,n)->{
                    params.addValue("limit",n).addValue("offset",Math.multiplyExact((long)p-1,n));
                    List<Map<String,Object>> items=db.queryForList(PeriodicPreparationReadSql.UNIVERSE+"""
                            SELECT product.id AS "productGoodsId",product.code AS "productCode",product.name AS "productName",
                                   product.spec AS "productSpec",product.material AS "legacyMaterial",products.runs AS "recentRuns",
                                   product.m_weight,weight_unit.name AS weight_unit_name,
                                   fn_goods_has_order_bom(product.id) AS "hasOrderBom",
                                   (SELECT count(*) FROM goods_bom_items edge JOIN goods material ON material.id=edge.component_goods_id
                                    WHERE edge.goods_id=product.id AND NOT edge.is_deleted AND material.issue_method='PERIODIC') AS "bomRowCount",
                                   (SELECT count(*) FROM goods_periodic_material_choices choice WHERE choice.product_goods_id=product.id AND choice.superseded_at IS NULL) AS "choiceRowCount",
                                   CASE WHEN fn_goods_has_periodic_bom(product.id) THEN 'WEIGHED'
                                        WHEN EXISTS(SELECT 1 FROM goods_periodic_material_choices choice WHERE choice.product_goods_id=product.id AND choice.superseded_at IS NULL AND choice.kind='MATERIAL') THEN 'CHOSEN'
                                        WHEN EXISTS(SELECT 1 FROM goods_periodic_material_choices choice WHERE choice.product_goods_id=product.id AND choice.superseded_at IS NULL) THEN 'NOT_FROM_STORE'
                                        ELSE 'PENDING' END AS status
                            FROM products JOIN goods product ON product.id=products.goods_id
                            LEFT JOIN units weight_unit ON weight_unit.id=product.m_weight_unit_id AND NOT weight_unit.is_deleted
                            WHERE NOT product.is_deleted AND NOT product.auto_created AND product.issue_method<>'PERIODIC'
                            ORDER BY products.runs DESC,product.code,product.id LIMIT :limit OFFSET :offset
                            """,params);
                    for(var item:items) {
                        BigDecimal grams=GoodsPeriodicMaterialRules.toGrams((BigDecimal)item.remove("m_weight"),
                                GoodsPeriodicMaterialRules.gramsPerUnit((String)item.remove("weight_unit_name")));
                        item.put("goodsWeightGramsExact",DecimalText.of(grams!=null&&grams.signum()>0?grams:null));
                    }
                    return items;
                });
        return new Summary(result,asOf);
    }
    public Detail product(UUID workshop,UUID product,int summarySize,String revision,String rawWindow) {
        Instant asOf=window(revision,rawWindow);
        return new Detail(pages.read(request(workshop,1,summarySize,revision,asOf),()->authorize(workshop),()->detail.selectedProduct(workshop,product,asOf)),asOf);
    }
}
