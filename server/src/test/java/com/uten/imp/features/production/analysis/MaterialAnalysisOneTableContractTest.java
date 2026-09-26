package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-102「一张表」服务端口径守卫。
 *
 * <p>这次改动只加了两个查询期派生值和一个只读端点，没有新迁移，所以没有数据库
 * 约束替我们把关；能钉住口径的就是这几条源码断言。它们守的都是**改错了不会当场
 * 报错、只会静静算错数**的地方。
 */
class MaterialAnalysisOneTableContractTest {

    private static final Path JAVA = Path.of("src/main/java/com/uten/imp");

    @Test
    void netShortageOnlySubtractsSharedFutureWhenItIsSafeToDoSo() throws Exception {
        String service = source("features/production/analysis/MaterialAnalysisService.java");

        // 催计划/办结使用尚未落实的供给量；未认领公共候选只能减少另外新下单的展示量。
        // 先扣真实自制承诺，再在安全的路线/维度上预扣公共候选，不能反推已经截断的 net。
        assertThat(service).contains("BigDecimal planningUncovered = additionalRecommended");
        assertThat(service).contains("BigDecimal netShortage = sharedFutureDeductible");
        assertThat(service).contains("? planningUncovered.subtract(sharedFutureClaimable).max(BigDecimal.ZERO)");
        assertThat(service).contains(": planningUncovered;");
        String planning = service.substring(service.indexOf("BigDecimal planningUncovered ="),
                service.indexOf("BigDecimal netShortage ="));
        assertThat(planning).contains(
                ".subtract(committedPlanQty.max(BigDecimal.ZERO).subtract(internalCovered)");
        assertThat(planning).doesNotContain("sharedFutureClaimable");
        // 2026-09-26：同料合并共享批次的转交份额(aggregateDelegatedShare)作为尾参追加,
        // 断言放宽为前三个值按序传入即可, 契约意图不变。
        assertThat(service).contains("netShortage, sourceRequiredQty, planningUncovered,");
        // 2026-09-23：再扣掉本节点已下达自制计划里归本需求的那一份(不含公共备货产出——
        // 那份不绑需求, 锚点余量也不因它归零), 且不与已作为 INTERNAL 在途扣过的前置自制
        // 台账 / 自制任务重复; additionalRecommended 那一行原样。
        assertThat(service).contains("BigDecimal committedPlanQty() {");
        assertThat(service).contains(
                "BigDecimal internalCovered = activeFutureCoverageQty.subtract(externalFutureCoverageQty)");
        assertThat(service).contains(
                ".subtract(committedPlanQty.max(BigDecimal.ZERO).subtract(internalCovered)");
        assertThat(service).contains("committedPlan = committedPlan.max(materialSource.committedPlanQty()");
        assertThat(service).contains(".multiply(materialSource.unitRate()).setScale(4, RoundingMode.DOWN));");

        // 条件一：下达段真会自动认领。判据与那里的排除口径同源——采购恒认领；
        // 委外只有无我方供料 BOM 的纯外协件认领；自制与路线未定一律不认领。
        assertThat(service).contains("private static boolean sharedFutureDeductible(");
        assertThat(service).contains("if (\"BUY\".equals(route)) return true;");
        assertThat(service).contains("if (!\"SUBCONTRACT\".equals(route)) return false;");
        assertThat(service).contains("return !subcontractBomParentGoods.contains(row.goodsId());");

        // 条件二：这个物料维度在本分析里只有这一行。公共在途池是按维度共享的，
        // forMaterial 对同维度每一行都返回整池，而「建议下单量」是逐行可加的；
        // 同料多行时逐行扣会把同一池扣 N 次，三行各需 100、池里只有 100 时会算出
        // 三行都「不缺」，人照着填就少下 200。
        assertThat(service).contains("if (!soleRowDimensions.contains(row.materialKey())) return false;");
        assertThat(service).contains("private static Set<String> soleRowDimensions(");
    }

    @Test
    void orderQtyPrefillUsesTheGrossRecommendationNotTheNetShortage()
            throws Exception {
        String table = java.nio.file.Files.readString(
                java.nio.file.Path.of(
                        "../lib/features/production/pages/material_analysis_material_table.dart"),
                StandardCharsets.UTF_8);

        // 服务端下达时 demandQty = requested.min(delta) 之后再从中减掉自动认领的
        // 公共在途——认领是从用户填的那个数里切走的，不是在它之上另加。所以
        // 「下单数量」的预填与提交必须用毛口径；用净数会让每一行都少下一个认领量。
        // 2026-09-22 起三列都经 _tableShownQty(估算 → 模拟快照 → 权威)读数, 「还需安排」
        // 那一项(residual)仍派生自毛口径 additionalSupplyRecommendedQty; 2026-09-23 起已下过
        // 单的自制行(含顶层)改读锚点产品的剩余可排量(_tableAnchorResidual), 其余行不变。
        // 2026-09-23 同日两个函数都加了 authoritative 命名参数(只看权威快照, 自动勾选拿它当
        // 基线)并一路透传, 下面钉的原文随之更新; 守的不变量一字未动: 残量累加 .residual 不是
        // .net, residual 回落到毛量, net 取 netShortageQty。
        assertThat(table).contains(
                "  double _tableGroupResidual(\n"
                        + "    _MaterialGroup group, {\n"
                        + "    bool authoritative = false,\n"
                        + "  }) => group.paths.fold<double>(\n"
                        + "    0,\n"
                        + "    (sum, material) =>\n"
                        + "        sum + _tableShownQty(material, authoritative: authoritative).residual,\n"
                        + "  );");
        assertThat(table).contains(
                "_tableAnchorResidual(material, authoritative: authoritative) ??\n"
                        + "          shown.additionalSupplyRecommendedQty,");
        assertThat(table).contains("net: shown.netShortageQty,");
        // 残量累加不许改成净数(新旧两种签名都禁)。
        assertThat(table).doesNotContain("sum + _tableShownQty(material).net,\n  );");
        assertThat(table).doesNotContain(
                "sum + _tableShownQty(material, authoritative: authoritative).net,\n  );");

        // 跨计划调拨与公共在途认领也会投影进 downstreamReferences，算成「已下单」
        // 会让这一行的下单格被锁死、批量下单静默跳过它。
        assertThat(table).contains("'FUTURE_TRANSFER',");
        assertThat(table).contains("'SHARED_FUTURE_CLAIM',");
        assertThat(table).contains("}.contains(_supplyOperationType(target.actionId))");
    }

    @Test
    void physicalShortageAlgorithmStaysUntouched() throws Exception {
        String service = source("features/production/analysis/MaterialAnalysisService.java");

        // shortageQty 同时是 actionable、让料候选与入库齐套三处的判据。
        // 把公共量算进它会让大量行整行掉出可下达集合——与「一张表能直接下单」
        // 正好相反。新口径必须是**另一个字段**。
        assertThat(service).contains(
                "return requiredQty.signum() > 0 && (depth == 0 || shortageQty.signum() > 0);");
        assertThat(service).contains("BigDecimal additionalRecommended = demandGap.subtract(activeFutureCoverageQty)");
    }

    @Test
    void routePendingRowsDoNotFallIntoThePurchaseChain() throws Exception {
        String stages = source("features/production/analysis/MaterialAnalysisFlowStageService.java");
        String service = source("features/production/analysis/MaterialAnalysisService.java");

        // 以前空路线被 normalizeRoute 归成 BUY，于是同一行上同时写着
        // 「请先选供应方式」和「等待下发采购」。
        assertThat(stages).contains("case ROUTE_PENDING_INPUT -> result.put(lineId, ROUTE_PENDING);");
        assertThat(service).contains("boolean routePending = row.depth() > 0");
        assertThat(service).contains("&& row.confirmedRoute() == null");
        // 根供给行另有根路线冻结机制，不进这个分支。
        assertThat(service).contains("MaterialAnalysisFlowStageService.ROUTE_PENDING_INPUT");
    }

    @Test
    void transferableSummaryKeepsTheSameLineageAndExclusionsAsPerRowSources()
            throws Exception {
        String reallocation =
                source("features/production/analysis/MaterialStockReallocationService.java");

        // 批量口径必须与逐行 sources() 逐字同源，否则「按钮亮着点进去是空的」。
        assertThat(reallocation).contains("public TransferableInSummary transferableInSummary(");
        assertThat(reallocation).contains(
                "PreplanStockEntitlementService.AVAILABLE_ORIGINAL_LOTS_SQL");
        assertThat(reallocation).contains("SUM(LEAST(lendable.qty, material.allocated_available_qty))");
        // 供方与接收方两侧都要排除未了结的让料/借用：V311 规定一个物料节点
        // 不能同时参与多笔未补齐的让料。
        assertThat(reallocation).contains("relation.status IN ('OPEN', 'PARTIAL')");
        assertThat(reallocation).contains("borrow.status = 'ACTIVE'");
        // 对象级可见范围必须进查询：可调拨量随登录人变，不能做成与账号无关的缓存。
        assertThat(reallocation).contains("analysis.maker_id IN (:visibleOwners)");
        assertThat(reallocation).contains("access.requireWritable(makerId,");
    }

    @Test
    void transferableSummaryIsAReadOnlyEndpointBehindTheCrossReallocatePermission()
            throws Exception {
        String controller = source("features/production/analysis/MaterialAnalysisController.java");

        assertThat(controller).contains("@GetMapping(\"/{id}/transferable-in-summary\")");
        assertThat(controller).contains(
                "hasAuthority('production_material_analysis:cross_reallocate')");
        // 不能并进 GET /{id}：那条查询要跑供方血缘的递归 CTE，进首屏就是拖慢热路径。
        assertThat(controller).doesNotContain("transferableInSummary(id, ");
    }

    private static String source(String relative) throws Exception {
        return Files.readString(JAVA.resolve(relative), StandardCharsets.UTF_8);
    }
}
