package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.Validator;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Merges a narrow table draft on the server, retaining exact persisted decimals. */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('goods:view') and hasAnyAuthority('goods:edit', 'goods:purchase:edit', 'goods:sales:edit', 'goods:price:edit', 'goods:name_en:edit')")
public class GoodsInlineEditService {
    private final GoodsService goods;
    private final GoodsRepository repository;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper mapper;
    private final Validator validator;

    private static final Set<String> EDITABLE = Set.of(
            "name", "clientGoodsName", "nameEn", "model", "spec", "series", "cNumber", "material", "paper",
            "rearInsertCode", "stockPlace", "sourceType", "colorId", "unitId", "mouldId",
            "owningWarehouseId", "minOrderQty", "orderMultipleQty", "price", "discount", "status");
    // Existing full-form apply() assigns these scalars unconditionally. All
    // references and nameEn are deliberately omitted unless explicitly changed.
    private static final Set<String> BASELINE = Set.of(
            "code", "categoryId", "name", "clientGoodsName", "shortName", "model", "cNumber", "spec", "series",
            "stockPlace", "material", "thickness", "mWeight", "pack", "pieces", "status",
            "sourceType", "rearInsertCode", "paper", "minOrderQty", "orderMultipleQty",
            "price", "discount", "sourceE", "machiningE", "incidentalE", "lacquerE",
            "platingE", "casingE", "polishE", "total", "workRate", "workE", "lostRate",
            "lostE", "rentRate", "rentE", "makeRate", "makeE", "cTotal", "gTotal");

    @Transactional
    public GoodsDetail patch(UUID id, Map<String, JsonNode> expected, Map<String, JsonNode> changes) {
        CurrentAuthorityGuard.requireAll("goods:view");
        var user = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED, "当前登录状态无效"));
        if (user.getEmployeeId() == null || user.isVisitor() || !user.isAccountNonLocked()
                || user.isMustChangePassword() || user.getImpersonatedBy() != null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号不能编辑货品，请核对登录状态");
        }
        JsonNode version = expected == null ? null : expected.get("version");
        if (version == null || !version.isIntegralNumber() || !version.canConvertToLong()
                || changes == null || changes.isEmpty() || !EDITABLE.containsAll(changes.keySet())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "须提供原货品版本，且只能编辑允许的资料字段");
        }
        // Resolve both permission decisions from the principal alone; the edited
        // keys below only decide whether each permission is required.
        boolean priceEditAllowed = CurrentAuthorityGuard.hasAll("goods:price:edit");
        boolean discountViewAllowed = CurrentAuthorityGuard.hasAll("goods:discount:view");
        if ((changes.containsKey("price") || changes.containsKey("discount")) && !priceEditAllowed)
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少操作权限：goods:price:edit");
        if (changes.containsKey("discount") && !discountViewAllowed)
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少操作权限：goods:discount:view");
        tx.bind();
        // Resolve visibility before locking; a foreign object's existence is
        // never disclosed by the lock result. The locked read below is current.
        Goods existing = repository.findById(id).filter(row -> !row.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "货品不存在"));
        goods.requireVisible(existing);
        goods.requireWritable(existing);
        try {
            if (em.createNativeQuery("SELECT id FROM goods WHERE id=:id AND NOT is_deleted FOR UPDATE NOWAIT")
                    .setParameter("id", id).getResultList().isEmpty()) {
                throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
            }
        } catch (ApiException failure) {
            throw failure;
        } catch (RuntimeException failure) {
            var conflict = new ApiException(ErrorCode.CONFLICT, "货品正在更新，请稍后刷新重试；未覆盖任何修改");
            conflict.initCause(failure);
            throw conflict;
        }
        // The pre-lock visibility read may have populated the persistence
        // context before a concurrent writer committed. Read the locked row.
        em.clear();
        GoodsDetail detail = goods.detail(id);
        if (!detail.isWritable()) throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        if (detail.getVersion() == null || detail.getVersion() != version.longValue()) {
            throw new ApiException(ErrorCode.CONFLICT, "货品已有后续修改，请刷新后重新编辑；未覆盖任何修改");
        }
        ObjectNode current = mapper.valueToTree(detail);
        ObjectNode merged = mapper.createObjectNode();
        for (String key : BASELINE) if (current.has(key)) merged.set(key, current.get(key));
        changes.forEach(merged::set);
        merged.put("version", version.longValue());
        GoodsSaveRequest request;
        try {
            request = mapper.treeToValue(merged, GoodsSaveRequest.class);
        } catch (Exception failure) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "输入值格式不正确，请核对数值或选择项");
        }
        var violations = validator.validate(request);
        if (!violations.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, violations.iterator().next().getMessage());
        }
        return goods.update(id, request);
    }
}
