package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.CurrentAuthorityGuard;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.UUID;
import java.util.Map;
import java.util.LinkedHashMap;

@Component
@RequiredArgsConstructor
public class CostImportEvidenceGuard {
    private final JdbcTemplate db;
    private final MasterReferenceValidationPort references;
    private final ImmutableDocumentStore documents;
    public void requireReadable(UUID importId, UUID goodsId) {
        CurrentAuthorityGuard.requireAll("goods:cost:view");
        references.requireVisibleGoods(goodsId);
        var sources=db.query("SELECT storage_provider,storage_key,storage_version,storage_size,storage_sha256 FROM goods_cost_imports WHERE id=? AND goods_id=?",
                (rs,row)->new ImmutableDocumentStore.Reference(rs.getString(1),rs.getString(2),rs.getString(3),rs.getLong(4),rs.getString(5)),importId,goodsId);
        if(sources.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"成本来源文件不存在");
        documents.read(sources.getFirst());
    }

    public Map<String, String> validate(UUID goodsId, Map<String, String> fields) {
        if (fields == null || !fields.containsKey("importId")) return fields;
        UUID importId;
        try { importId = UUID.fromString(fields.get("importId")); }
        catch (RuntimeException error) { throw new ApiException(ErrorCode.VALIDATION_FAILED, "所选成本来源文件不正确，请重新选择"); }
        requireReadable(importId, goodsId);
        var evidence = db.queryForMap("SELECT source_name,storage_sha256 FROM goods_cost_imports WHERE id=?", importId);
        Map<String, String> verified = new LinkedHashMap<>(fields);
        verified.put("sourceName", (String) evidence.get("source_name"));
        verified.put("sourceHash", (String) evidence.get("storage_sha256"));
        if (fields.containsKey("importMappingId")) {
            UUID mapping;
            try { mapping = UUID.fromString(fields.get("importMappingId")); }
            catch (RuntimeException error) { throw new ApiException(ErrorCode.VALIDATION_FAILED, "所选成本匹配记录不正确，请重新操作"); }
            var hashes = db.queryForList("SELECT mapping_hash FROM goods_cost_import_mappings WHERE id=? AND import_id=? AND goods_id=?",
                    String.class, mapping, importId, goodsId);
            if (hashes.size() != 1) throw new ApiException(ErrorCode.NOT_FOUND, "成本匹配记录不存在");
            verified.put("importMappingHash", hashes.getFirst());
        } else verified.remove("importMappingHash");
        return verified;
    }
}
