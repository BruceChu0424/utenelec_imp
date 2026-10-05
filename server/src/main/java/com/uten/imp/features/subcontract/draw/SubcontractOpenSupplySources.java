package com.uten.imp.features.subcontract.draw;

import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 一种直属物料(货 + 色)的在途供应来源唯一读口(ADR-143 §三.5): 委外任务详情的物料表与委外订货单
 * 进度的物料段共用同一条 SQL({@link SubcontractDrawSql#openSupplySources}), 两处「还缺」行的
 * 供应来源逐张单据一致。每张单据一行, open_qty 为基本单位的未到量; 按 (kind, 单号) 排序, 最多
 * {@link #MAX_SOURCES} 张。只读, 不加锁, 由调用方的只读事务承载。
 */
public final class SubcontractOpenSupplySources {

    /** 每种物料最多列出的来源单据张数。 */
    public static final int MAX_SOURCES = 20;

    /** kind: PURCHASE / SUBCONTRACT / PRODUCTION。 */
    public record OpenSupply(String kind, UUID docId, String docNo, BigDecimal openQty) {
    }

    private SubcontractOpenSupplySources() {
    }

    public static List<OpenSupply> read(EntityManager em, UUID goodsId, UUID colorId) {
        if (goodsId == null) return List.of();
        String colorExpression = colorId == null ? "CAST(NULL AS uuid)" : "CAST(:supplyColor AS uuid)";
        Query query = em.createNativeQuery("SELECT source.kind, source.doc_id, source.doc_no, source.open_qty FROM ("
                + SubcontractDrawSql.openSupplySources("CAST(:supplyGoods AS uuid)", colorExpression)
                + ") source ORDER BY source.kind, source.doc_no LIMIT " + MAX_SOURCES);
        query.setParameter("supplyGoods", goodsId);
        if (colorId != null) {
            query.setParameter("supplyColor", colorId);
        }
        List<OpenSupply> sources = new ArrayList<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            sources.add(new OpenSupply(SubcontractDrawQueryService.str(row[0]),
                    SubcontractDrawQueryService.uuid(row[1]), SubcontractDrawQueryService.str(row[2]),
                    SubcontractDrawQueryService.decimal(row[3])));
        }
        return List.copyOf(sources);
    }
}
