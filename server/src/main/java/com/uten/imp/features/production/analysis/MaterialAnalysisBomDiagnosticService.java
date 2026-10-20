package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.RdMaterialIssuePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;

/** Read-only diagnostics share the exact guards used by the authoritative BOM snapshot. */
@Service
@RequiredArgsConstructor
public class MaterialAnalysisBomDiagnosticService {
    private final EntityManager em;
    private final MaterialAnalysisService analyses;
    private final ProductionDocumentAccessPolicy access;
    private final RdMaterialIssuePort engineering;

    @Transactional(readOnly = true)
    public BomDiagnosticView inspect(BomDiagnosticRequest request) {
        List<PreviewItem> sources = analyses.normalizePreviewItems(request.items());
        if (request.analysisId() != null) {
            List<?> makers = em.createNativeQuery("""
                    SELECT maker_id FROM production_material_analyses
                    WHERE id=:id AND is_deleted=FALSE
                    """).setParameter("id", request.analysisId()).getResultList();
            if (makers.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "物料分析不存在");
            access.requireWritable((UUID) makers.getFirst(), "只能检查本人负责的物料分析", access.scope());
        }
        List<UUID> roots = sourceGoods(sources);
        List<BomFinding> findings = new MaterialAnalysisBomSnapshotReader(em)
                .findings(roots.stream().distinct().toList());
        Set<UUID> blocked = findings.stream().map(BomFinding::rootGoodsId).collect(Collectors.toSet());
        // A manual demand number belongs to exactly one analysis (ADR-130). Never split its lines
        // across two analyses while letting unrelated sales lines and manual demand numbers continue.
        Set<String> blockedManualGroups = new LinkedHashSet<>();
        for (int i = 0; i < roots.size(); i++) {
            PreviewItem source = sources.get(i);
            if (source.salesOrderItemId() == null && blocked.contains(roots.get(i))) {
                blockedManualGroups.add(manualGroup(source));
            }
        }
        List<Integer> indexes = new ArrayList<>();
        for (int i = 0; i < roots.size(); i++) {
            PreviewItem source = sources.get(i);
            if (blocked.contains(roots.get(i)) || (source.salesOrderItemId() == null
                    && blockedManualGroups.contains(manualGroup(source)))) indexes.add(i);
        }
        Map<String, String> tasks = engineering.openTaskNos(findings.stream().map(this::target).distinct().toList());
        return new BomDiagnosticView(findings.stream()
                .map(finding -> finding.withTaskNo(tasks.get(target(finding).key()))).toList(), List.copyOf(indexes));
    }

    /** Only current, server-revalidated findings can be forwarded; client text and goods IDs have no authority. */
    @Transactional
    public BomDiagnosticView forward(BomForwardRequest request) {
        BomDiagnosticView current = inspect(request.diagnostic());
        Set<String> selected = new LinkedHashSet<>(request.findingKeys());
        Map<String, BomFinding> byKey = current.findings().stream()
                .collect(Collectors.toMap(BomFinding::key, finding -> finding));
        if (!byKey.keySet().containsAll(selected)) {
            throw new ApiException(ErrorCode.CONFLICT, "问题已变化或已修复，请重新检查后再转工程部");
        }
        Map<RdMaterialIssuePort.Target, List<BomFinding>> groups = new LinkedHashMap<>();
        for (String key : selected) {
            BomFinding finding = byKey.get(key);
            groups.computeIfAbsent(target(finding), ignored -> new ArrayList<>()).add(finding);
        }
        Map<String, String> numbers = new LinkedHashMap<>();
        for (var group : groups.entrySet()) {
            String descriptions = group.getValue().stream().map(finding ->
                    finding.rootLabel() + "：" + finding.parentLabel() + " → " + finding.componentLabel()
                            + "；" + finding.reason() + "。" + finding.fix() + "。 [" + finding.key() + "]")
                    .collect(Collectors.joining("\n"));
            String sources = request.diagnostic().items().stream().map(item ->
                    item.salesOrderItemId() != null ? "销售明细=" + item.salesOrderItemId()
                            : item.sourceType() + "/" + item.sourceRef() + "/货品=" + item.goodsId())
                    .collect(Collectors.joining("\n"));
            numbers.put(group.getKey().key(), engineering.forward(group.getKey(),
                    request.diagnostic().analysisId(), descriptions + "\n需求来源：\n" + sources));
        }
        return new BomDiagnosticView(current.findings().stream().map(finding -> finding.withTaskNo(
                numbers.getOrDefault(target(finding).key(), finding.taskNo()))).toList(), current.blockedSourceIndexes());
    }

    private RdMaterialIssuePort.Target target(BomFinding finding) {
        return new RdMaterialIssuePort.Target(finding.repairGoodsId(), finding.masterData());
    }

    private String manualGroup(PreviewItem source) {
        return source.sourceType() + ":" + source.sourceRef().strip().toLowerCase(java.util.Locale.ROOT);
    }

    /** One sales lookup and one manual lookup for the whole batch; never N requests for N products. */
    private List<UUID> sourceGoods(List<PreviewItem> sources) {
        Set<UUID> salesIds = sources.stream().map(PreviewItem::salesOrderItemId)
                .filter(java.util.Objects::nonNull).collect(Collectors.toSet());
        Map<UUID, UUID> salesGoods = new LinkedHashMap<>();
        if (!salesIds.isEmpty()) {
            for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT i.id,i.goods_id
                    FROM sales_order_items i JOIN sales_orders o ON o.id=i.order_id
                    JOIN goods g ON g.id=i.goods_id AND g.is_deleted=FALSE
                    WHERE i.id IN (:ids) AND i.is_deleted=FALSE AND o.is_deleted=FALSE
                      AND o.status=1 AND o.finance_confirmed=TRUE
                      AND COALESCE(o.is_stopped,FALSE)=FALSE AND o.is_closed=FALSE
                    """).setParameter("ids", salesIds))) salesGoods.put((UUID) row[0], (UUID) row[1]);
            if (salesGoods.size() != salesIds.size()) {
                throw new ApiException(ErrorCode.CONFLICT, "销售需求已变化，请重新加载后检查");
            }
        }
        Set<UUID> manualIds = sources.stream().filter(item -> item.salesOrderItemId() == null)
                .map(PreviewItem::goodsId).collect(Collectors.toSet());
        if (!manualIds.isEmpty()) {
            List<?> valid = em.createNativeQuery("SELECT id FROM goods WHERE id IN (:ids) AND is_deleted=FALSE")
                    .setParameter("ids", manualIds).getResultList();
            if (valid.size() != manualIds.size()) throw new ApiException(ErrorCode.CONFLICT, "手工需求的货品已变化，请重新选择");
        }
        return sources.stream().map(item -> item.salesOrderItemId() == null ? item.goodsId()
                : salesGoods.get(item.salesOrderItemId())).toList();
    }
}
