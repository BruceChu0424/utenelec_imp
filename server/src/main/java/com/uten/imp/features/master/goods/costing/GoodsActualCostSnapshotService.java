package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.GoodsActualCostQueryPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.CurrentAuthorityGuard;
import org.springframework.stereotype.Service;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.List;
import java.util.function.Consumer;
import java.util.function.Function;
import com.uten.imp.application.port.GoodsActualCostQueryPort.*;
import com.uten.imp.common.export.*;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Isolation;

/** A download must identify the exact actual-cost result that the operator inspected. */
@Service
public class GoodsActualCostSnapshotService {
    private final GoodsActualCostQueryPort actual;
    private final GoodsCostSheetService sheets;
    private final GoodsCostJson canonical;
    private final ObjectMapper json;
    public GoodsActualCostSnapshotService(GoodsActualCostQueryPort actual, GoodsCostSheetService sheets,
                                          GoodsCostJson canonical, ObjectMapper json) {
        this.actual = actual; this.sheets = sheets; this.canonical = canonical; this.json = json;
    }
    public record Result(GoodsActualCostQueryPort.ActualCostSnapshot snapshot, String digest) {}

    public Result read(GoodsActualCostQueryPort.Query query) {
        sheets.requireGoodsScope(query.goodsId());
        var snapshot = actual.snapshot(query);
        var checked = new java.util.HashSet<java.util.UUID>();
        checked.add(query.goodsId());
        for (var line : snapshot.inputs()) if(line.goodsId()!=null)checked.add(line.goodsId());
        sheets.requireGoodsScopeBatch(checked);
        return new Result(snapshot, canonical.hash(canonicalContent(snapshot)));
    }

    private Map<String,Object> canonicalContent(ActualCostSnapshot snapshot) {
        Map<String, Object> content = json.convertValue(snapshot, new TypeReference<LinkedHashMap<String, Object>>() {});
        content.remove("capturedAt");
        var selectedRevisions = snapshot.costObjects().stream().map(GoodsActualCostQueryPort.CostObject::revisionId)
                .filter(java.util.Objects::nonNull).map(Object::toString).collect(java.util.stream.Collectors.toSet());
        if(content.get("revisions") instanceof java.util.List<?> revisions) content.put("revisions", revisions.stream()
                .filter(value -> value instanceof Map<?,?> row && selectedRevisions.contains(java.util.Objects.toString(row.get("revisionId"),""))).toList());
        removeDiagnostic(content.get("costObjects"),"historicalRevision");
        removeDiagnostic(content.get("inputs"),"laterCostRevision");
        removeDiagnostic(content.get("outputs"),"laterCostRevision");
        return content;
    }
    private static void removeDiagnostic(Object rows, String key) {
        if(rows instanceof java.util.List<?> list) for(Object row:list) if(row instanceof Map<?,?> map) map.remove(key);
    }
    public Map<String, Object> view(GoodsActualCostQueryPort.Query query) {
        Result result = read(query);
        Map<String, Object> view = json.convertValue(result.snapshot(), new TypeReference<LinkedHashMap<String, Object>>() {});
        view.put("contentDigest", result.digest());
        return view;
    }
    public Result export(GoodsActualCostQueryPort.Query query, String expectedDigest) {
        CurrentAuthorityGuard.requireAll("goods:cost:view", "goods:cost:export");
        if (expectedDigest == null || !expectedDigest.matches("[0-9a-f]{64}"))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先载入实际成本结果再下载");
        Result result = read(query);
        if (!result.digest().equals(expectedDigest)) throw new ApiException(ErrorCode.CONFLICT, "实际成本来源已变化，请刷新核对后再下载");
        return result;
    }

    /** Bounded source; the exact canonical digest is checked before any sheet is emitted. */
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public void streamExport(GoodsActualCostQueryPort.Query query,String expectedDigest,int perSectionLimit) {
        CurrentAuthorityGuard.requireAll("goods:cost:view","goods:cost:export");
        if(expectedDigest==null||!expectedDigest.matches("[0-9a-f]{64}"))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请先载入实际成本结果再下载");
        sheets.requireGoodsScope(query.goodsId());
        var sink=java.util.Objects.requireNonNull(DocumentPageSink.current(),"Actual-cost export needs a document sink");
        try(var source=actual.openStream(query,perSectionLimit,rows->{
            var ids=rows.stream().map(InputLine::goodsId).filter(java.util.Objects::nonNull).distinct().toList();
            sheets.requireGoodsScopeBatch(ids);
        })) {
            var h=source.header();
            var metadata=new ActualCostSnapshot(h.goodsId(),h.capturedAt(),h.currencyBasis(),h.periodBasis(),h.inputScope(),
                    h.filter(),h.summary(),h.costObjects(),List.of(),List.of(),h.selectedRevisions(),List.of());
            Map<String,Object> content=canonicalContent(metadata);
            if(h.inputRows()>0)content.put("inputs",new StreamArray<InputLine>(source::inputs,line->canonicalRow(line,"laterCostRevision")));
            if(h.outputRows()>0)content.put("outputs",new StreamArray<OutputLine>(source::outputs,line->canonicalRow(line,"laterCostRevision")));
            if(h.gapRows()>0)content.put("gaps",new StreamArray<Gap>(source::gaps,line->canonicalRow(line,null)));
            String digest=canonical.hashStreaming(content);
            if(!digest.equals(expectedDigest))throw new ApiException(ErrorCode.CONFLICT,"实际成本来源已变化，请刷新核对后再下载");
            ExportOperationCheckpoint.check();
            var template=GoodsActualCostDocumentMapper.map(metadata,digest);
            var sections=new java.util.ArrayList<DocumentPageSink.Section>();
            for(int index=0;index<template.sections().size();index++) {
                var section=template.sections().get(index);
                sections.add(new DocumentPageSink.Section("actual-"+index,section.name(),section.columns(),index==1,false));
            }
            sink.begin(new DocumentPageSink.Header(template.title(),template.metadata(),sections,h.inputRows()));
            emit(sink,"actual-0",template.sections().get(0).rows(),perSectionLimit);
            var inputs=new Pages(sink,"actual-1",perSectionLimit,h.inputRows());
            source.inputs(line->inputs.accept(GoodsActualCostDocumentMapper.inputRow(line)));inputs.finish();
            var outputs=new Pages(sink,"actual-2",perSectionLimit,h.outputRows());
            source.outputs(line->outputs.accept(GoodsActualCostDocumentMapper.outputRow(line)));outputs.finish();
            emit(sink,"actual-3",template.sections().get(3).rows(),perSectionLimit);
            var gaps=new Pages(sink,"actual-4",perSectionLimit,h.gapRows());
            source.gaps(line->gaps.accept(GoodsActualCostDocumentMapper.gapRow(line)));gaps.finish();
            emit(sink,"actual-5",template.sections().get(5).rows(),perSectionLimit);
        }
    }

    private Map<String,Object> canonicalRow(Object value,String diagnostic) {
        Map<String,Object> row=json.convertValue(value,new TypeReference<LinkedHashMap<String,Object>>(){});
        if(diagnostic!=null)row.remove(diagnostic);
        return row;
    }
    private static final class StreamArray<T> extends com.fasterxml.jackson.databind.JsonSerializable.Base {
        private final Consumer<Consumer<T>> source;
        private final Function<T,Object> mapper;
        private StreamArray(Consumer<Consumer<T>> source,Function<T,Object> mapper){this.source=source;this.mapper=mapper;}
        @Override public void serialize(com.fasterxml.jackson.core.JsonGenerator generator,
                com.fasterxml.jackson.databind.SerializerProvider provider) throws java.io.IOException {
            generator.writeStartArray();
            elements(generator,provider);
            generator.writeEndArray();
        }
        private void elements(com.fasterxml.jackson.core.JsonGenerator generator,
                com.fasterxml.jackson.databind.SerializerProvider provider) {
            source.accept(value->{
                ExportOperationCheckpoint.check();
                try {provider.defaultSerializeValue(mapper.apply(value),generator);}
                catch(java.io.IOException error){throw new java.io.UncheckedIOException(error);}
            });
        }
        @Override public void serializeWithType(com.fasterxml.jackson.core.JsonGenerator generator,
                com.fasterxml.jackson.databind.SerializerProvider provider,
                com.fasterxml.jackson.databind.jsontype.TypeSerializer types) throws java.io.IOException {
            var id=types.writeTypePrefix(generator,types.typeId(this,com.fasterxml.jackson.core.JsonToken.START_ARRAY));
            elements(generator,provider);
            types.writeTypeSuffix(generator,id);
        }
    }
    private static void emit(DocumentPageSink.Consumer sink,String id,List<Map<String,Object>> rows,int limit) {
        var pages=new Pages(sink,id,limit,rows.size());rows.forEach(pages);pages.finish();
    }
    private static final class Pages implements Consumer<Map<String,Object>> {
        private final DocumentPageSink.Consumer sink;private final String id;private final int maximum;private final long expected;
        private final java.util.ArrayList<Map<String,Object>> batch=new java.util.ArrayList<>(100);private long seen;
        private Pages(DocumentPageSink.Consumer sink,String id,int maximum,long expected){this.sink=sink;this.id=id;this.maximum=maximum;this.expected=expected;}
        @Override public void accept(Map<String,Object> row){
            if(++seen>maximum)throw new ApiException(ErrorCode.VALIDATION_FAILED,"实际成本单个分表超过50000行完整文件边界，请缩小期间或选择工单");
            batch.add(row);if(batch.size()==100)flush();
        }
        private void flush(){ExportOperationCheckpoint.check();sink.accept(new DocumentPageSink.Page(id,List.copyOf(batch)));batch.clear();}
        private void finish(){
            if(seen!=expected)throw new ApiException(ErrorCode.CONFLICT,"实际成本来源在读取中变化，未生成文件");
            if(!batch.isEmpty()||seen==0)flush();
        }
    }
}
