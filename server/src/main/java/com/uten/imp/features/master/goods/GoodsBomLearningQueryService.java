package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.UUID;

/** Bounded master aggregates, never a scan of historical production samples. */
@Service
@RequiredArgsConstructor
public class GoodsBomLearningQueryService {
    private final EntityManager em;
    private final MasterReferenceValidationPort references;
    private final MasterObjectAccess access;

    public record Material(UUID goodsId,String goodsCode,String goodsName,UUID colorId,String colorName,
                           UUID unitId,String unitName,BigDecimal totalNetQty,BigDecimal averageQty) { }
    public record Summary(boolean active,boolean enabled,BigDecimal totalOutputQty,long sampleCount,
                          String blockedReason,String unitName,List<Material> materials) { }

    @Transactional(readOnly=true)
    public Summary summary(UUID goodsId) {
        references.requireVisibleGoods(goodsId);
        var profiles=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT profile.enabled,profile.total_output_qty,profile.sample_count,profile.blocked_reason,unit.name
                FROM goods_bom_learning_profiles profile LEFT JOIN units unit ON unit.id=profile.output_unit_id
                WHERE profile.goods_id=:goods
                """).setParameter("goods",goodsId));
        if(profiles.isEmpty())return new Summary(false,false,BigDecimal.ZERO,0,null,null,List.of());
        Object[] profile=profiles.getFirst();
        BigDecimal output=(BigDecimal)profile[1];
        var visible=access.visibleGoodsOwner();
        var materials=NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT total.component_goods_id,goods.code,goods.name,total.color_id,color.name,total.unit_id,unit.name,total.net_qty,goods.owner_employee_id
                FROM goods_bom_learning_material_totals total JOIN goods ON goods.id=total.component_goods_id
                LEFT JOIN colors color ON color.id=total.color_id LEFT JOIN units unit ON unit.id=total.unit_id
                WHERE total.goods_id=:goods AND total.net_qty>0 ORDER BY goods.code,total.component_goods_id,total.color_id,total.unit_id
                """).setParameter("goods",goodsId)).stream()
                .filter(row->visible.test((UUID)row[8]))
                .map(row->new Material((UUID)row[0],(String)row[1],(String)row[2],(UUID)row[3],(String)row[4],(UUID)row[5],(String)row[6],
                        (BigDecimal)row[7],output.signum()>0?((BigDecimal)row[7]).divide(output,8,RoundingMode.HALF_UP):BigDecimal.ZERO))
                .toList();
        return new Summary(true,Boolean.TRUE.equals(profile[0]),output,((Number)profile[2]).longValue(),(String)profile[3],(String)profile[4],materials);
    }
}
