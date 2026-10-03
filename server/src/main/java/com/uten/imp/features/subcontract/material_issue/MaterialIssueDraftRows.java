package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** 草稿保存复用原明细身份, 防止行 UUID 变化导致本地草稿、扩展字段及来源链断开。 */
final class MaterialIssueDraftRows {

    private MaterialIssueDraftRows() {
    }

    record Reconciled(List<SubcontractMaterialIssueItem> targets, List<SubcontractMaterialIssueItem> removed) {
    }

    static Reconciled reconcile(UUID issueId, List<SubcontractMaterialIssueItem> existing,
                                List<MaterialIssueItemLine> requested) {
        Map<UUID, SubcontractMaterialIssueItem> byId = new HashMap<>();
        Map<UUID, SubcontractMaterialIssueItem> byPlan = new HashMap<>();
        for (SubcontractMaterialIssueItem item : existing) {
            if (!Objects.equals(issueId, item.getIssueId())) throw conflict("出仓明细不属于当前单据");
            byId.put(item.getId(), item);
            if (item.getPlanItemId() != null && byPlan.put(item.getPlanItemId(), item) != null) {
                throw conflict("出仓单存在重复计划行，请刷新后核对");
            }
        }
        Set<UUID> retained = new HashSet<>();
        List<SubcontractMaterialIssueItem> targets = new ArrayList<>(requested.size());
        for (MaterialIssueItemLine line : requested) {
            UUID source = line.getPlatformFields() == null ? null : line.getPlatformFields().sourceRecordId();
            if (line.getId() != null && source != null && !line.getId().equals(source)) {
                throw conflict("出仓明细与扩展字段来源不一致");
            }
            UUID id = line.getId() != null ? line.getId() : source;
            SubcontractMaterialIssueItem target = id == null ? null : byId.get(id);
            if (id != null && target == null) throw conflict("出仓明细已变化或不属于当前单据，请刷新后重试");
            if (target == null && line.getPlanItemId() != null) target = byPlan.get(line.getPlanItemId());
            if (target == null && line.getPlanItemId() != null) {
                throw conflict("出仓明细不可新增或替换发料计划行绑定");
            }
            if (target != null) {
                if (!Objects.equals(target.getPlanItemId(), line.getPlanItemId())) {
                    throw conflict("出仓明细不可替换发料计划行绑定");
                }
                if (!retained.add(target.getId())) throw conflict("同一出仓明细不可重复提交");
            } else {
                // 无计划、无既有明细引用的旧客户端行仍按新行处理, 不猜测同货品行的来源。
                target = new SubcontractMaterialIssueItem();
            }
            targets.add(target);
        }
        List<SubcontractMaterialIssueItem> removed = existing.stream()
                .filter(item -> !retained.contains(item.getId())).toList();
        return new Reconciled(List.copyOf(targets), removed);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
