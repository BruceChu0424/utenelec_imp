package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.time.LocalDate;
import java.util.*;

/** Command-local reads; callers retain source locks and all discovery/verification phases. */
final class MaterialAnalysisSalesSourceReader {
    private static final int READ_BATCH_SIZE=256;
    private final EntityManager em;
    MaterialAnalysisSalesSourceReader(EntityManager em) { this.em=em; }

    /** One bounded lookup per discovery pass; this does not grant access or skip the later recheck. */
    Set<UUID> activeAnalyses(Collection<UUID> ids) {
        List<UUID> unique=ids==null?List.of():ids.stream().filter(Objects::nonNull).distinct().sorted().toList();
        Set<UUID> result=new LinkedHashSet<>();
        for(int from=0;from<unique.size();from+=READ_BATCH_SIZE) {
            List<UUID> batch=unique.subList(from,Math.min(unique.size(),from+READ_BATCH_SIZE));
            result.addAll(NativeQueryResults.typedRows(em.createNativeQuery("""
                    SELECT DISTINCT analysis.id
                    FROM production_material_analysis_items source
                    JOIN production_material_analyses analysis ON analysis.id=source.analysis_id AND analysis.is_deleted=FALSE
                    WHERE source.is_deleted=FALSE AND source.source_type='SALES_ORDER_ITEM'
                      AND source.sales_order_item_id IN (:ids) AND analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                    ORDER BY analysis.id
                    """).setParameter("ids",batch),UUID.class));
        }
        return Collections.unmodifiableSet(result);
    }

    Snapshot read(Collection<UUID> ids) {
        List<UUID> unique=ids==null?List.of():ids.stream().filter(Objects::nonNull).distinct().sorted().toList();
        Map<UUID,Object[]> rows=new HashMap<>();
        for(int from=0;from<unique.size();from+=READ_BATCH_SIZE) {
            List<UUID> batch=unique.subList(from,Math.min(unique.size(),from+READ_BATCH_SIZE));
            for(Object[] row:NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT i.id,i.goods_id,i.color_id,i.unit_id,COALESCE(i.deliver_date,o.deliver_date),
                           o.status,o.is_stopped,o.is_closed,o.is_deleted,i.is_deleted,o.finance_confirmed
                    FROM (SELECT * FROM sales_order_items archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('sales_order_items',archive_origin.id)) i JOIN (SELECT * FROM sales_orders archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('sales_orders',archive_origin.id)) o ON o.id=i.order_id
                    JOIN goods g ON g.id=i.goods_id
                    WHERE i.id IN (:ids) ORDER BY i.id
                    """).setParameter("ids",batch))) {
                rows.put((UUID)row[0],Arrays.copyOfRange(row,1,row.length));
            }
        }
        return new Snapshot(rows);
    }

    /** Validate on use, in the original request order; fetching a batch is never authorization. */
    static final class Snapshot {
        private final Map<UUID,Object[]> rows;
        private Snapshot(Map<UUID,Object[]> rows) { this.rows=Map.copyOf(rows); }
        MaterialAnalysisService.SourceMaster require(UUID id) {
            Object[] row=id==null?null:rows.get(id);
            if(row==null) throw new ApiException(ErrorCode.NOT_FOUND,"销售订单行不存在");
            if(((Number)row[4]).shortValue()!=1 || Boolean.TRUE.equals(row[5]) || Boolean.TRUE.equals(row[6])
                    || Boolean.TRUE.equals(row[7]) || Boolean.TRUE.equals(row[8])) {
                throw new ApiException(ErrorCode.CONFLICT,"销售订单未审核、已中止、已关闭或已删除");
            }
            if(!Boolean.TRUE.equals(row[9])) throw new ApiException(ErrorCode.CONFLICT,"销售订单未通过财务确认，暂不能纳入物料分析");
            if(row[2]==null) throw new ApiException(ErrorCode.CONFLICT,"销售订单行未维护有效单位");
            return new MaterialAnalysisService.SourceMaster((UUID)row[0],(UUID)row[1],(UUID)row[2],date(row[3]));
        }
        private static LocalDate date(Object value) {
            if(value==null) return null;
            return value instanceof LocalDate local?local:((java.sql.Date)value).toLocalDate();
        }
    }
}
