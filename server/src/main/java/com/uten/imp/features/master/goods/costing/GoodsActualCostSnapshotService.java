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
        for (var line : snapshot.inputs()) {
            if (line.goodsId() != null && checked.add(line.goodsId())) sheets.requireGoodsScope(line.goodsId());
        }
        Map<String, Object> content = json.convertValue(snapshot, new TypeReference<LinkedHashMap<String, Object>>() {});
        content.remove("capturedAt");
        var selectedRevisions = snapshot.costObjects().stream().map(GoodsActualCostQueryPort.CostObject::revisionId)
                .filter(java.util.Objects::nonNull).map(Object::toString).collect(java.util.stream.Collectors.toSet());
        if(content.get("revisions") instanceof java.util.List<?> revisions) content.put("revisions", revisions.stream()
                .filter(value -> value instanceof Map<?,?> row && selectedRevisions.contains(java.util.Objects.toString(row.get("revisionId"),""))).toList());
        removeDiagnostic(content.get("costObjects"),"historicalRevision");
        removeDiagnostic(content.get("inputs"),"laterCostRevision");
        removeDiagnostic(content.get("outputs"),"laterCostRevision");
        return new Result(snapshot, canonical.hash(content));
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
}
