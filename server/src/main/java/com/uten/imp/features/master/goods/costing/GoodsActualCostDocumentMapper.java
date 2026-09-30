package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.GoodsActualCostQueryPort.ActualCostSnapshot;
import com.uten.imp.common.export.ExportDocument;
import com.uten.imp.common.export.ExportColumn;
import java.util.List;
import java.util.Map;
import java.util.LinkedHashMap;
import static com.uten.imp.features.master.goods.costing.GoodsCostDocumentMapper.*;

public final class GoodsActualCostDocumentMapper {
    private GoodsActualCostDocumentMapper() {}
    public static ExportDocument map(ActualCostSnapshot s, String digest) {
        var t = s.summary();
        var totals = new ExportDocument.Section("实际归集汇总", List.of(textCol("name", "项目"), numberCol("value", "金额或数量")), List.of(
                row("name", "成本范围已知投入(完整工单范围)", "value", t.knownInputCostLocal()),
                row("name", "完整成本范围累计已分配", "value", t.scopeAllocatedOutputCostLocal()),
                row("name", "所选产出已分配成本", "value", t.allocatedOutputCostLocal()),
                row("name", "筛选范围外产出已分配成本", "value", t.excludedOutputCostLocal()),
                row("name", "所选有效产量", "value", t.outputQtyBase()),
                row("name", "所选产出单位实际成本", "value", t.actualUnitCostLocal()),
                row("name", "在制保留", "value", t.heldWipLocal()),
                row("name", "待重分配", "value", t.pendingReallocationLocal()),
                row("name", "待分类", "value", t.unclassifiedLocal()), row("name", "待核来源数", "value", t.pendingSourceCount())));
        var inputs = new ExportDocument.Section("物料及费用来源", List.of(textCol("code", "货品编号"), textCol("name", "货品名称"),
                textCol("unit", "单位"), textCol("kind", "投入类型"), textCol("basis", "用量依据"), numberCol("issued", "领入数量"),
                numberCol("returned", "退回数量"), numberCol("net", "净耗数量"), numberCol("known", "已知金额"),
                numberCol("allocated", "已分配金额"), numberCol("held", "在制金额"), textCol("pending", "来源状态"),
                textCol("revision", "成本修订"), textCol("source", "来源类型"), textCol("sourceId", "来源单据"), textCol("itemId", "来源行")),
                s.inputs().stream().map(i -> row("code", i.goodsCode(), "name", i.goodsName(), "unit", i.unitName(), "kind", i.inputKind(),
                        "basis", i.quantityBasis(), "issued", i.grossQtyBase(), "returned", i.returnedQtyBase(), "net", i.netQtyBase(),
                        "known", i.knownAmountLocal(), "allocated", i.allocatedAmountLocal(), "held", i.heldAmountLocal(),
                        "pending", i.pending() ? "待核清" : "已归集", "revision", i.revisionId(),
                        "source", i.sourceDocType(), "sourceId", i.sourceDocId(), "itemId", i.sourceItemId())).toList());
        var outputs = new ExportDocument.Section("产出与撤回", List.of(textCol("date", "业务日期"), textCol("sourceDocType", "来源类型"),textCol("source", "来源单据"),
                textCol("item", "来源行"), numberCol("original", "原始产量"), numberCol("effective", "有效产量"),
                numberCol("amount", "已分配成本"), textCol("status", "状态"), textCol("revision", "修订")),
                s.outputs().stream().map(o -> row("date", o.businessDate(), "sourceDocType",o.sourceDocType(), "source", o.sourceDocId(), "item", o.sourceItemId(),
                        "original", o.originalQtyBase(), "effective", o.effectiveQtyBase(), "amount", o.knownAmountLocal(),
                        "status", o.withdrawn() ? "已撤回" : o.pending() ? "待核清" : "已归集", "revision", o.revisionId())).toList());
        var gaps = new ExportDocument.Section("未归集项目", List.of(textCol("code", "原因"), textCol("scope", "成本对象"),
                textCol("source", "来源"), textCol("component", "成本项目")), s.gaps().stream().map(g -> row(
                        "code", g.code(), "scope", g.costObjectId(), "source", g.sourceId(), "component", g.component())).toList());
        var selectedRevisions=s.costObjects().stream().map(com.uten.imp.application.port.GoodsActualCostQueryPort.CostObject::revisionId)
                .filter(java.util.Objects::nonNull).collect(java.util.stream.Collectors.toSet());
        var revisions = new ExportDocument.Section("冻结修订", List.of(textCol("scope", "成本对象"), textCol("revision", "修订标识"),
                numberCol("version", "版本"), textCol("time", "修订时间"), textCol("complete", "范围核清"), numberCol("pending", "待处理任务")),
                s.revisions().stream().filter(r -> selectedRevisions.contains(r.revisionId())).map(r -> row("scope", r.costObjectId(), "revision", r.revisionId(), "version", r.version(),
                        "time", r.occurredAt(), "complete", r.scopeComplete() ? "是" : "否", "pending", r.pendingTaskCount())).toList());
        var objects = new ExportDocument.Section("成本对象", List.of(textCol("executionNo", "工单编号"), textCol("scopeKind", "成本范围"),
                numberCol("revisionVersion", "版本"), textCol("revisionId", "修订标识"), textCol("state", "状态"),
                numberCol("scopeOutputQtyBase", "范围产量"), numberCol("allocatedOutputCostLocal", "已分配成本"),
                numberCol("heldWipLocal", "在制金额")), s.costObjects().stream().map(o -> row("executionNo", o.executionNo(),
                        "scopeKind", o.scopeKind(), "revisionVersion", o.revisionVersion(), "revisionId", o.revisionId(), "state", stateLabel(o.state()),
                        "scopeOutputQtyBase", o.scopeOutputQtyBase(), "allocatedOutputCostLocal", o.allocatedOutputCostLocal(), "heldWipLocal", o.heldWipLocal())).toList());
        return new ExportDocument("货品实际成本核对", List.of("货品: " + s.goodsId(), "币种口径: " + s.currencyBasis(),
                "日期口径: " + s.periodBasis(), "来源范围: " + s.inputScope(), "查询条件: " + s.filter(),
                "读取时间: " + s.capturedAt(), "内容摘要: " + digest, "全成本归集完整: " + (t.fullCostComplete() ? "是" : "否"),
                "对比预算时使用所选产出的已分配成本与有效产量，不用全工单投入除期间产量。",
                "空金额表示尚不能确定；单位成本是展示投影，不能回乘形成财务金额。"), List.of(totals,
                rename(inputs, Map.ofEntries(Map.entry("code","goodsCode"),Map.entry("name","goodsName"),Map.entry("unit","unitName"),
                        Map.entry("kind","inputKind"),Map.entry("basis","quantityBasis"),Map.entry("issued","grossQtyBase"),
                        Map.entry("returned","returnedQtyBase"),Map.entry("net","netQtyBase"),Map.entry("known","knownAmountLocal"),
                        Map.entry("allocated","allocatedAmountLocal"),Map.entry("held","heldAmountLocal"),Map.entry("revision","revisionId"),
                        Map.entry("source","sourceDocType"),Map.entry("sourceId","sourceDocId"),Map.entry("itemId","sourceItemId"))),
                rename(outputs, Map.of("date","businessDate","source","sourceDocId","item","sourceItemId",
                        "original","originalQtyBase","effective","effectiveQtyBase","amount","knownAmountLocal","revision","revisionId","status","pending")),
                objects, gaps, revisions));
    }
    private static ExportDocument.Section rename(ExportDocument.Section section, Map<String,String> names) {
        var columns=section.columns().stream().map(c->new ExportColumn(names.getOrDefault(c.key(),c.key()),c.label(),c.type(),c.width())).toList();
        var rows=section.rows().stream().map(row->{
            Map<String,Object> result=new LinkedHashMap<>(); row.forEach((key,value)->result.put(names.getOrDefault(key,key),value));return result;
        }).toList();
        return new ExportDocument.Section(section.name(),columns,rows);
    }
}
