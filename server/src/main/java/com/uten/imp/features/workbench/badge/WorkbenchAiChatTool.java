package com.uten.imp.features.workbench.badge;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AiChatAccessPolicy;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

/** Queries the live badge catalog, without copying its workflow arithmetic or exposing record contents. */
@Component
public class WorkbenchAiChatTool implements AiChatToolPort {
    private static final Set<String> MODULES = Set.of("ALL","SELF","HR","FINANCE","PRODUCTION","RD","WAREHOUSE","PURCHASE","SUBCONTRACT","QUALITY","SALES","ADMIN");
    private static final DateTimeFormatter TIME=DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss").withZone(BusinessTime.ZONE);
    private final AiChatAccessPolicy access;
    private final WorkbenchBadgeService badges;
    private final ObjectMapper json;
    public WorkbenchAiChatTool(AiChatAccessPolicy access,WorkbenchBadgeService badges,ObjectMapper json) {
        this.access=access; this.badges=badges; this.json=json;
    }
    @Override public String name() { return "workbench_tasks"; }
    @Override public String title() { return "查询各业务待办和在办"; }
    @Override public String domain() { return "SELF"; }
    @Override public boolean rememberQueryArguments() { return true; }
    @Override public String description() { return "读取本人当前部门和功能权限允许的工作台任务计数，覆盖销售、采购、委外、生产、品质、仓库、财务、人事、研发。module不填查所有当前允许模块；仅返回当前各入口待办/进行中数量，不能列出具体任务或单号、供应商、货品、数量等单据明细，也没有历史日期筛选。不查工资、报销、通知正文，不认领或处理任务。"; }
    @Override public Map<String,Object> parameters() {
        Set<String> domains;
        try { domains=access.domains(); } catch(ApiException denied) { domains=Set.of(); }
        Set<String> allowed=domains;
        return Map.of("type","object","additionalProperties",false,"properties",Map.of("module",Map.of("type","string","enum",
                MODULES.stream().filter(value->"ALL".equals(value)||allowed.contains(value)).sorted().toList())),"required",List.of());
    }
    @Override public boolean available() { try { access.requireChat(); return true; } catch(ApiException denied) { return false; } }
    @Override public Map<String,Object> execute(Map<String,Object> arguments) {
        access.requireChat(); String module=module(arguments); var snapshot=read(module);
        return Map.of("reply",render(snapshot,false),"detailReply",render(snapshot,true),"actions",List.of(),
                "_toolEvidence",Map.of("module",module,"snapshot",signature(snapshot.rows())));
    }
    private static String render(Snapshot snapshot,boolean detailed) {
        if(snapshot.rows().isEmpty()) return "暂时没有可显示的待办。";
        List<Row> active=snapshot.rows().stream().filter(row->row.stale()||row.todo()>0||row.inProgress()>0)
                .sorted(Comparator.comparingInt((Row row)->row.todo()>0?0:row.inProgress()>0?1:2)
                        .thenComparing(Comparator.comparingLong(Row::todo).reversed())
                        .thenComparing(Comparator.comparingLong(Row::inProgress).reversed()).thenComparing(Row::entry)).toList();
        if(active.isEmpty()) return "目前没有待办或进行中的任务。";
        StringBuilder text=new StringBuilder("目前需要关注：");
        int shown=detailed?active.size():Math.min(5,active.size());
        for(Row row:active.subList(0,shown)) {
            text.append("\n• ").append(label(row.entry())).append("：");
            if(row.stale()) text.append("暂时查不到数量");
            else {
                if(row.todo()>0) text.append("待办 ").append(row.todo()).append(" 项");
                if(row.todo()>0&&row.inProgress()>0) text.append("，");
                if(row.inProgress()>0) text.append("进行中 ").append(row.inProgress()).append(" 项");
            }
            text.append("。");
        }
        if(active.size()>shown) text.append("\n另有 ").append(active.size()-shown).append(" 项，回复“展开”可看更多。");
        if(detailed) text.append("\n更新于 ").append(TIME.format(snapshot.generatedAt())).append("。");
        return text.toString();
    }
    @Override public void authorizeResultRead(Map<String,Object> evidence) {
        access.requireChat();
        if(evidence==null||!evidence.keySet().equals(Set.of("module","snapshot"))||!(evidence.get("module") instanceof String module)
                ||!(evidence.get("snapshot") instanceof String digest)||!MODULES.contains(module)) throw changed();
        if(!digest.equals(signature(read(module).rows()))) throw changed();
    }
    private Snapshot read(String module) {
        Set<String> domains=access.domains();
        if(!"ALL".equals(module)&&!domains.contains(module)) throw new ApiException(ErrorCode.FORBIDDEN,"这个业务模块不在你的当前部门和权限范围内");
        Set<String> wanted=Arrays.stream(WorkbenchBadgeCatalog.values())
                .filter(entry->!entry.name().startsWith("expense"))
                .filter(entry->domains.contains(entryDomain(entry)))
                .filter(entry->"ALL".equals(module)||entryDomain(entry).equals(module))
                .map(Enum::name).collect(Collectors.toSet());
        WorkbenchBadgeSummary summary=badges.summary(wanted);
        List<Row> rows=new ArrayList<>();
        for(String entry:summary.entries().keySet().stream().sorted().toList()) {
            if(!wanted.contains(entry)) throw changed();
            boolean stale=summary.staleEntries().contains(entry);
            var counts=summary.entries().get(entry);
            if(counts==null||counts.todo()<0||counts.inProgress()<0) throw changed();
            rows.add(new Row(entry,stale?0:counts.todo(),stale?0:counts.inProgress(),stale));
        }
        return new Snapshot(summary.generatedAt(),List.copyOf(rows));
    }
    private static String entryDomain(WorkbenchBadgeCatalog entry) {
        if(entry==WorkbenchBadgeCatalog.visitorHost) return "SELF";
        return switch(entry.module()) {
            case people->"HR"; case finance->"FINANCE"; case production,workshop->"PRODUCTION";
            case rd->"RD"; case warehouse->"WAREHOUSE"; case purchase->"PURCHASE";
            case subcontract->"SUBCONTRACT"; case quality->"QUALITY"; case sales->"SALES"; case system->"ADMIN";
        };
    }
    private static String module(Map<String,Object> args) {
        if(args==null||!Set.of("module").containsAll(args.keySet())) throw invalid();
        if(!args.containsKey("module")) return "ALL";
        if(!(args.get("module") instanceof String value)||!MODULES.contains(value)) throw invalid();
        return value;
    }
    private String signature(List<Row> value) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(json.writeValueAsString(value).getBytes(StandardCharsets.UTF_8))); }
        catch(JsonProcessingException|NoSuchAlgorithmException failed) { throw new IllegalStateException("Cannot fingerprint task counts",failed); }
    }
    private record Row(String entry,long todo,long inProgress,boolean stale) {}
    private record Snapshot(java.time.Instant generatedAt,List<Row> rows) {}
    private static String label(String entry) {
        return switch(WorkbenchBadgeCatalog.valueOf(entry)) {
            case visitorHost->"我的访客"; case visitorApproval->"访客审批"; case hrProfileReview->"员工资料变更审核"; case hrTaskCenter->"人事任务";
            case financeAuditCenter->"业务财务审核"; case financeQuoteReview->"报价财务核价"; case financeStockCountReview->"财务盘点审核"; case financeDrafts->"财务单据草稿";
            case productionSchedule->"待排产"; case productionRateApprovals->"生产超产比例审批"; case productionMaterialIncrementApprovals->"生产补料审批";
            case productionPlanningUrges->"车间催计划"; case productionBatches->"生产批次"; case productionDrafts->"生产单据草稿"; case productionWorkshop->"我的车间任务";
            case rdTaskCenter->"研发任务"; case warehouseOutboundCenter->"仓库出库任务"; case warehouseInboundCenter->"仓库入库任务";
            case warehouseDrawCenter->"生产领退料"; case warehouseWorkshopMaterial->"车间内料仓"; case warehouseStockCountReview->"仓库盘点审核";
            case warehouseQualityResult->"品质结果仓库处理"; case warehouseDrafts->"仓库单据草稿";
            case purchaseTaskCenter->"采购任务"; case purchaseSupplierReturn->"采购退回供应商"; case purchaseDrafts->"采购单据草稿";
            case subcontractTaskCenter->"委外任务"; case subcontractSupplierReturn->"委外退回供应商"; case subcontractDrafts->"委外单据草稿";
            case qualityIqcPending->"来料待检"; case qualityFqcPending->"产成品待检"; case salesAttention->"销售待处理";
            case salesOrderInFlight->"销售在途订单"; case salesShipmentFinanceRejected->"发货财务退回"; case salesQuoteFinanceRejected->"报价财务退回";
            case salesQuoteAwaitingCustomerConfirmation->"报价待客户确认"; case salesQuoteAwaitingConversion->"报价待转订货"; case salesDrafts->"销售单据草稿";
            case serverStatusAlert->"服务器告警"; case expenseMine,expenseFinance->throw invalid();
        };
    }
    private static ApiException invalid() { return new ApiException(ErrorCode.VALIDATION_FAILED,"任务查询只能选择已登记业务模块"); }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN,"工作台任务或可见范围已变化，请重新查询"); }
}
