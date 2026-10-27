package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.GoodsActualCostQueryPort.*;
import com.uten.imp.common.export.ExportDocument;
import com.uten.imp.common.export.ExportOperationCheckpoint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.ColumnMapRowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.sql.Connection;
import java.time.OffsetDateTime;
import java.util.*;
import java.util.function.Consumer;

import static com.uten.imp.features.stock.valuation.GoodsActualCostQueryService.*;

/** Same fact projection, bounded JDBC portals and the same repeatable-read resource for every pass. */
final class GoodsActualCostStreamReader {
    private static final int FETCH=100;
    private final NamedParameterJdbcTemplate db;
    GoodsActualCostStreamReader(NamedParameterJdbcTemplate db){this.db=db;}

    StreamingRead open(Query query,int maximum,Consumer<List<InputLine>> inspector) {
        if(query==null||query.goodsId()==null)throw invalid("实际成本查询必须指定货品");
        if(query.from()!=null&&query.to()!=null&&query.from().isAfter(query.to()))throw invalid("实际成本开始日期不能晚于结束日期");
        if(maximum<1||maximum>ExportDocument.MAX_SECTION_ROWS)throw invalid("实际成本完整分表读取边界无效");
        Object resource=TransactionSynchronizationManager.getResource(Objects.requireNonNull(db.getJdbcTemplate().getDataSource()));
        if(resource==null)throw new IllegalStateException("Actual cost export requires one repeatable-read transaction");
        var args=new MapSqlParameterSource().addValue("goods",query.goodsId()).addValue("segment",query.executionSegmentId())
                .addValue("from",query.from()).addValue("to",query.to()).addValue("revision",query.revisionId())
                .addValue("zone",com.uten.imp.common.time.BusinessTime.ZONE.getId());
        var objectRows=db.queryForList(OBJECTS_SQL,args);
        if(objectRows.size()>500)throw invalid("实际成本对象超过500个，请缩小期间或选择工单");
        args.addValue("ids",objectRows.stream().map(row->uuid(row,"cost_object_id")).toList());
        var math=new ActualCostEvidenceMath(objectRows,query.goodsId(),null);
        if(!objectRows.isEmpty()) {
            // The small synchronous route rejects a complete over-limit source
            // before decoding facts, computing the digest or emitting any sheet.
            if(maximum<ExportDocument.MAX_SECTION_ROWS) {
                preflight(INDEXED_INPUTS,args,maximum,resource);
                preflight(INDEXED_OUTPUTS,args,maximum,resource);
            }
            List<InputLine> inspected=new ArrayList<>(FETCH);
            cursor(INDEXED_INPUTS,args,maximum,resource,row->{
                InputLine line=input(row);math.accept(line);inspected.add(line);
                if(math.gapCount>maximum)throw tooMany(maximum);
                if(inspected.size()==FETCH){inspect(inspector,inspected);inspected.clear();}
            });
            if(!inspected.isEmpty())inspect(inspector,inspected);
            cursor(INDEXED_OUTPUTS,args,maximum,resource,row->math.accept(output(row)));
        }
        math.finish();
        if(math.gapCount>maximum)throw tooMany(maximum);
        List<Revision> selected=List.of();
        var revisionIds=math.objects().stream().map(CostObject::revisionId).filter(Objects::nonNull).distinct().toList();
        if(!revisionIds.isEmpty()) {
            args.addValue("selectedRevisionIds",revisionIds);
            selected=db.queryForList(REVISIONS_SQL.replace("WHERE r.execution_segment_id IN (:ids)",
                    "WHERE r.execution_segment_id IN (:ids) AND r.id IN (:selectedRevisionIds)"),args)
                    .stream().map(GoodsActualCostQueryService::revision).toList();
        }
        var header=new StreamingHeader(query.goodsId(),OffsetDateTime.now(),ActualCostEvidenceMath.CURRENCY,
                ActualCostEvidenceMath.PERIOD,ActualCostEvidenceMath.INPUT_SCOPE,query,math.summary(),math.objects(),
                selected,math.inputCount,math.outputCount,math.gapCount);
        return new Read(header,args,math,maximum,resource,!objectRows.isEmpty());
    }
    private static void inspect(Consumer<List<InputLine>> inspector,List<InputLine> rows) {
        ExportOperationCheckpoint.check();
        Objects.requireNonNull(inspector,"Input authority is required").accept(List.copyOf(rows));
    }
    private void preflight(String sql,MapSqlParameterSource args,int maximum,Object resource) {
        ExportOperationCheckpoint.check();requireResource(resource);
        int order=sql.lastIndexOf("ORDER BY ");
        if(order<0)throw new IllegalStateException("Actual-cost source order is missing");
        args.addValue("preflightLimit",maximum+1);
        Long rows=db.execute("SELECT count(*) FROM (SELECT 1 FROM ("+sql.substring(0,order)+") projected LIMIT :preflightLimit) bounded",
                args,statement->{statement.setQueryTimeout(60);try(var result=statement.executeQuery()){result.next();return result.getLong(1);}});
        ExportOperationCheckpoint.check();
        if(rows!=null&&rows>maximum)throw com.uten.imp.common.export.LegacyExportBudget.tooManyRows();
    }

    private final class Read implements StreamingRead {
        private final StreamingHeader header;
        private final MapSqlParameterSource args;
        private final ActualCostEvidenceMath math;
        private final int maximum;
        private final Object resource;
        private final boolean hasObjects;
        private final Thread owner=Thread.currentThread();
        private boolean closed;
        Read(StreamingHeader header,MapSqlParameterSource args,ActualCostEvidenceMath math,int maximum,Object resource,boolean hasObjects){
            this.header=header;this.args=args;this.math=math;this.maximum=maximum;this.resource=resource;this.hasObjects=hasObjects;
        }
        @Override public StreamingHeader header(){return header;}
        private void check(){
            if(closed||owner!=Thread.currentThread())throw new IllegalStateException("Actual-cost source scope has retired");
            requireResource(resource);ExportOperationCheckpoint.check();
        }
        @Override public void inputs(Consumer<InputLine> consumer){check();if(hasObjects)cursor(INDEXED_INPUTS,args,maximum,resource,row->consumer.accept(input(row)));}
        @Override public void outputs(Consumer<OutputLine> consumer){check();if(hasObjects)cursor(INDEXED_OUTPUTS,args,maximum,resource,row->consumer.accept(output(row)));}
        @Override public void gaps(Consumer<Gap> consumer){
            check();math.baseGaps.forEach(consumer);
            if(hasObjects)cursor(INDEXED_INPUTS,args,maximum,resource,row->ActualCostEvidenceMath.inputGaps(input(row)).forEach(consumer));
            math.objectGaps.forEach(consumer);
        }
        @Override public void close(){closed=true;}
    }

    private void requireResource(Object expected){
        if(expected!=TransactionSynchronizationManager.getResource(db.getJdbcTemplate().getDataSource()))
            throw new IllegalStateException("Actual-cost source cannot change its transaction snapshot");
    }
    private void cursor(String sql,MapSqlParameterSource args,int maximum,Object resource,Consumer<Map<String,Object>> consumer){
        requireResource(resource);ExportOperationCheckpoint.check();
        db.execute(sql,args,statement->{
            if(statement.getConnection().getAutoCommit()||statement.getConnection().getTransactionIsolation()!=Connection.TRANSACTION_REPEATABLE_READ)
                throw new IllegalStateException("Actual-cost cursors require a live repeatable-read portal");
            statement.setFetchSize(FETCH);statement.setMaxRows(maximum+1);statement.setQueryTimeout(60);
            var mapper=new ColumnMapRowMapper();int count=0;
            try(var rows=statement.executeQuery()){
                while(rows.next()){
                    if(++count>maximum)throw tooMany(maximum);
                    consumer.accept(mapper.mapRow(rows,count-1));
                    if(count%FETCH==0)ExportOperationCheckpoint.check();
                }
            }
            ExportOperationCheckpoint.check();return null;
        });
    }

    // Derive from the authoritative projection. Snapshot arrays are indexed once
    // per selected revision; ordinal preserves the original first-match rule.
    private static String indexed(String source,boolean input){
        String field=input?"input_snapshot":"output_snapshot",key=input?"node":"source";
        String table=input?"stock_value_production_cost_inputs":"stock_value_production_cost_outputs";
        String reference=input?"i.input_node_id":"output.source_node_id";
        var matcher=java.util.regex.Pattern.compile("LEFT JOIN LATERAL \\(SELECT value FROM jsonb_array_elements\\(r\\."
                +field+"\\) value\\s+WHERE \\(value->>'"+key+"'\\)::uuid="+java.util.regex.Pattern.quote(reference)+" LIMIT 1\\) snap ON true").matcher(source);
        if(!matcher.find())throw new IllegalStateException("Actual-cost snapshot projection anchor changed");
        String anchor=matcher.group();
        if(matcher.find())throw new IllegalStateException("Ambiguous actual-cost snapshot projection anchor");
        String index="""
                WITH frozen_snapshot_index AS MATERIALIZED (
                    SELECT DISTINCT ON (r.id,(entry.value->>'%1$s')::uuid)
                           r.id AS revision_id,(entry.value->>'%1$s')::uuid AS node_id,entry.value
                    FROM stock_value_production_cost_objects selected
                    JOIN stock_value_production_cost_revisions r ON r.execution_segment_id=selected.execution_segment_id
                      AND r.id=COALESCE(CAST(:revision AS uuid),selected.current_revision_id)
                    CROSS JOIN LATERAL jsonb_array_elements(r.%2$s) WITH ORDINALITY entry(value,ordinal)
                    WHERE selected.execution_segment_id IN (:ids)
                      AND EXISTS(SELECT 1 FROM %3$s present WHERE present.execution_segment_id=selected.execution_segment_id)
                    ORDER BY r.id,(entry.value->>'%1$s')::uuid,entry.ordinal
                )
                """.formatted(key,field,table);
        return index+source.replace(anchor,"LEFT JOIN frozen_snapshot_index snap ON snap.revision_id=r.id AND snap.node_id="+reference);
    }
    static final String INDEXED_INPUTS=indexed(INPUTS_SQL,true),INDEXED_OUTPUTS=indexed(OUTPUTS_SQL,false);
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException tooMany(int maximum){return maximum<ExportDocument.MAX_SECTION_ROWS?com.uten.imp.common.export.LegacyExportBudget.tooManyRows():invalid("实际成本单个分表超过50000行完整文件边界，请缩小期间或选择工单");}
}
