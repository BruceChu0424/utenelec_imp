package com.uten.imp.features.master.history;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/** Rebuild numbering from today's identity and policy, never from historical allocation metadata. */
@Service
@RequiredArgsConstructor
public class MasterIdentifierVersionRestorer {
    private final EntityManager em;
    private final CategoryDrivenCodeService categoryCodes;
    private final MasterCodeService fixedCodes;
    private final MasterIdentifierAvailabilityService availability;

    private static final Map<String, MasterIdentifierAvailabilityService.Domain> DOMAINS = Map.ofEntries(
            Map.entry("goods", MasterIdentifierAvailabilityService.Domain.GOODS),
            Map.entry("clients", MasterIdentifierAvailabilityService.Domain.CLIENT),
            Map.entry("suppliers", MasterIdentifierAvailabilityService.Domain.SUPPLIER),
            Map.entry("moulds", MasterIdentifierAvailabilityService.Domain.MOULD),
            Map.entry("colors", MasterIdentifierAvailabilityService.Domain.COLOR),
            Map.entry("units", MasterIdentifierAvailabilityService.Domain.UNIT),
            Map.entry("currencies", MasterIdentifierAvailabilityService.Domain.CURRENCY),
            Map.entry("warehouses", MasterIdentifierAvailabilityService.Domain.WAREHOUSE),
            Map.entry("accounts", MasterIdentifierAvailabilityService.Domain.ACCOUNT));
    private static final List<String> ALLOCATION = List.of("code_sequence", "code_managed", "code_prefix_category_id");

    /** Normal creation locks this row before writing a master. Acquire it before history table locks too. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void lockForRestore(String entity) {
        var domain = DOMAINS.get(entity);
        if (domain == null || !categoryDriven(domain)) return;
        List<?> rows = em.createNativeQuery("SELECT last_seq FROM category_master_code_sequences WHERE master_type=:type FOR UPDATE NOWAIT")
                .setParameter("type", domain.name()).getResultList();
        if (rows.size() != 1) throw conflict("资料编号序列不可核对，请联系管理员");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public List<MasterVersionRow> prepare(List<MasterVersionRow> rows) {
        List<MasterVersionRow> prepared = new ArrayList<>(rows.size());
        for (MasterVersionRow row : rows) {
            var domain = DOMAINS.get(row.table());
            if (domain == null || row.current() == null || row.target() == null) {
                prepared.add(row);
                continue;
            }
            ObjectNode target = row.target().deepCopy();
            String retired = retiredGoodsReason(row);
            if (retired != null) throw conflict(retired);
            preserveAllocation(row.current(), target);
            String requested = normalized(row.target().get("code"));
            if (Objects.equals(normalized(row.current().get("code")), requested)) {
                copy(row.current(), target, "code");
            } else {
                String problem = policyProblem(row, domain);
                if (problem != null) throw conflict(problem);
                if (categoryDriven(domain)) {
                    if (!Objects.equals(row.current().get("category_id"), row.target().get("category_id")))
                        throw conflict("编号恢复不能同时改变分类，请先通过分类维护流程调整");
                    JsonNode sequence = row.current().get("code_sequence");
                    if (sequence == null || !sequence.canConvertToLong() || sequence.asLong() <= 0)
                        throw conflict("当前编号序号不可核对，不能用历史序号覆盖");
                    var current = new CategoryCodeAllocation(row.current().path("code").asText(), sequence.asLong(),
                            uuid(row.current().get("code_prefix_category_id")), row.current().path("code_managed").asBoolean());
                    var next = categoryCodes.allocateForUpdate(CategoryDrivenCodeService.MasterType.valueOf(domain.name()),
                            row.id(), uuid(row.current().get("category_id")), requested, current);
                    target.put("code", next.code());
                    target.put("code_sequence", next.sequence());
                    target.put("code_managed", next.managed());
                    if (next.prefixCategoryId() == null) target.putNull("code_prefix_category_id");
                    else target.put("code_prefix_category_id", next.prefixCategoryId().toString());
                } else {
                    MasterCodePrefix prefix = MasterCodePrefix.valueOf(domain.name());
                    target.put("code", row.current().path("is_deleted").asBoolean()
                            ? fixedCodes.resolveMutableCodeForRestore(prefix, requested, row.id(), row.current().path("code").asText())
                            : fixedCodes.resolveMutableCode(prefix, requested, row.id(), row.current().path("code").asText()));
                }
            }
            prepared.add(new MasterVersionRow(row.table(), row.id(), row.current(), target));
        }
        return List.copyOf(prepared);
    }

    /** Capability preview only: no claim, sequence advance, or lock. Saving repeats the authoritative allocation. */
    @Transactional(readOnly = true)
    public String blockedReason(MasterVersionRow row) {
        String retired = retiredGoodsReason(row);
        if (retired != null) return retired;
        var domain = DOMAINS.get(row.table());
        if (domain == null || row.current() == null || row.target() == null
                || Objects.equals(normalized(row.current().get("code")), normalized(row.target().get("code")))) return null;
        String problem = policyProblem(row, domain);
        if (problem != null) return problem;
        if (categoryDriven(domain) && !Objects.equals(row.current().get("category_id"), row.target().get("category_id")))
            return "编号恢复不能同时改变分类，请先通过分类维护流程调整";
        try {
            UUID category = categoryDriven(domain) ? uuid(row.current().get("category_id")) : null;
            var result = row.current().path("is_deleted").asBoolean()
                    ? availability.checkForRestore(domain, normalized(row.target().get("code")), row.id(), category)
                    : availability.check(domain, normalized(row.target().get("code")), row.id(), category);
            return result.available() ? null : result.message();
        } catch (ApiException failure) {
            return failure.getMessage();
        }
    }

    private String retiredGoodsReason(MasterVersionRow row) {
        if (!"goods".equals(row.table()) || row.current() == null || !row.current().path("is_deleted").asBoolean()
                || row.target() == null || row.target().path("is_deleted").asBoolean()) return null;
        return Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS(SELECT 1 FROM goods_code_reuse_releases WHERE old_goods_id=:id)")
                .setParameter("id", row.id()).getSingleResult())
                ? "原编号已回用于新 UUID 的货品，不能通过历史恢复旧货品；请核对当前货品" : null;
    }

    private String policyProblem(MasterVersionRow row, MasterIdentifierAvailabilityService.Domain domain) {
        String code = normalized(row.target().get("code"));
        if (code == null) return "历史版本未登记有效编号，不能通过恢复重新生成身份编号";
        if (domain == MasterIdentifierAvailabilityService.Domain.WAREHOUSE) {
            if (row.current().path("is_line_side").asBoolean() || row.target().path("is_line_side").asBoolean())
                return "车间内料仓编号由开通流程管理，不能通过历史修改";
            Object root = em.createNativeQuery("SELECT fn_warehouse_root_id()").getSingleResult();
            if (row.id().equals(root) || "001".equals(normalized(row.current().get("code"))) || "001".equals(code))
                return "主仓编号由仓库层级规则保护，不能通过历史修改";
        }
        boolean owned = Boolean.TRUE.equals(em.createNativeQuery("""
                SELECT EXISTS (SELECT 1 FROM business_identifier_reservation_members
                  WHERE normalized_identifier=:code COLLATE "C" AND owner_domain=:domain AND entity_id=:id)
                """)
                .setParameter("code", code).setParameter("domain", domain.name()).setParameter("id", row.id())
                .getSingleResult());
        if (!owned) return "历史编号未登记为此资料的正式编号，不能将内部中间态或其他身份编号恢复到资料";
        return null;
    }

    private static boolean categoryDriven(MasterIdentifierAvailabilityService.Domain domain) {
        return domain == MasterIdentifierAvailabilityService.Domain.GOODS || domain == MasterIdentifierAvailabilityService.Domain.CLIENT
                || domain == MasterIdentifierAvailabilityService.Domain.SUPPLIER || domain == MasterIdentifierAvailabilityService.Domain.MOULD;
    }
    private static void preserveAllocation(JsonNode current, ObjectNode target) { for (String key : ALLOCATION) copy(current, target, key); }
    private static void copy(JsonNode current, ObjectNode target, String key) {
        if (current.has(key)) target.set(key, current.get(key)); else target.remove(key);
    }
    private static String normalized(JsonNode code) { return code == null || code.isNull() || code.asText().isBlank() ? null : code.asText().strip().toUpperCase(Locale.ROOT); }
    private static UUID uuid(JsonNode value) { return value == null || value.isNull() || value.asText().isBlank() ? null : UUID.fromString(value.asText()); }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
}
