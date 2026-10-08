package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.Goods;
import com.uten.imp.features.master.goods.GoodsBomPasteService;
import com.uten.imp.features.master.goods.GoodsBomFileLimits;
import com.uten.imp.features.master.goods.GoodsPeriodicMaterialRules;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.dto.BomPasteResult;
import com.uten.imp.security.CurrentAuthorityGuard;
import lombok.RequiredArgsConstructor;
import org.apache.poi.EncryptedDocumentException;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellType;
import org.apache.poi.ss.usermodel.DataFormatter;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.apache.poi.util.RecordFormatException;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * 组装信息导入（goods:bom:create，与「粘贴组件信息」同一权限口径；替换模式另需
 * goods:bom:delete，与粘贴命令一致）。
 *
 * <p>格式 = 配件清单导出的 14 列；序号列的级联段(1 / 2 / 2.1)表达层级。检测只读，
 * 提交前重新解析并全量复检（导入是原子事务：任何一层写入被数据库拒绝，整体回滚），
 * 所以不需要货品导入那种「计划 TTL」——所有校验都以提交时刻的库内状态为准。</p>
 *
 * <p>写入按层复用 {@link GoodsBomPasteService#paste}（ADR-111 原子命令）：第 1 层
 * 粘到目标货品，第 2 层起按父序号分组粘到对应组件货品；同一层内重复、成环、组件
 * 停用等校验全部由粘贴命令承担，这里只补「文件侧」的校验（序号合法/唯一、父序号
 * 存在、编号能匹配到货品、数值可解析、目标货品自身不能出现在文件里）。</p>
 *
 * <p>「真实使用数量」列只读(ADR-129：由学习引擎按实物净耗算，人只能「重新学习」)，导入时认得、
 * 但不读；写入的是「设计使用数量」(旧表头「数量」同义)，留空按错误报，不再静默按 1。
 * 数值单元格按存的值读，不按显示格式读：导出的文件原样导回，数量一位不差(学习边不会因此变成人工边)。</p>
 */
@Service
@RequiredArgsConstructor
public class GoodsBomImportService {

    private final GoodsRepository goodsRepo;
    private final GoodsBomPasteService pasteService;

    /** 文件侧硬上限：BOM 是树平铺，2000 行远超真实使用；防误传大文件撑爆内存。 */
    private static final int MAX_ROWS = GoodsBomFileLimits.MAX_ROWS;

    private static final Pattern SEQ_PATTERN = Pattern.compile("^\\d+(\\.\\d+)*$");
    private static final Pattern NUMBER_PATTERN = Pattern.compile(
            "[+-]?(?:(?:\\d+|\\d{1,3}(?:,\\d{3})+)(?:\\.\\d*)?|\\.\\d+)(?:[eE][+-]?\\d+)?");

    /** 表头别名（与导出列名一致，另认几个顺手的叫法）。 */
    private static final Map<String, String> HEADER_ALIASES = new HashMap<>();

    static {
        for (String a : new String[]{"序号", "级联序号"}) putAlias(a, "seq");
        for (String a : new String[]{"物料编号", "编号", "组件编号"}) putAlias(a, "code");
        for (String a : new String[]{"物料名称", "名称", "组件名称"}) putAlias(a, "name");
        putAlias("型号", "model");
        putAlias("规格", "spec");
        putAlias("单位", "unit");
        putAlias("颜色", "color");
        putAlias("来源", "source");
        putAlias("计量方式", "consumptionBasis");
        putAlias("基准产量", "basisOutputQty");
        putAlias("尾包", "allowPartialPackage");
        for (String a : new String[]{"设计使用数量", "数量"}) putAlias(a, "qty");
        putAlias("真实使用数量", "actualQty"); // 只读列：导出带出，导入不读
        for (String a : new String[]{"备注", "摘要"}) putAlias(a, "summary");
    }

    private static void putAlias(String alias, String key) {
        HEADER_ALIASES.put(normKey(alias), key);
    }

    /** 与货品导入同一归一键（全角→半角、去空白）。 */
    private static String normKey(String raw) {
        if (raw == null) return "";
        return raw.replace("\u3000", " ").replaceAll("\\s+", "")
                .replace('（', '(').replace('）', ')')
                .toLowerCase();
    }

    private static final Map<String, String> BASIS_LABELS = Map.of(
            "按每件", "PER_UNIT", "按包装", "PER_PACKAGE", "固定批耗", "FIXED_BATCH");

    private static final Set<String> TOTAL_KEYWORDS = Set.of("合计", "总计", "小计");

    // ============================================================
    // 检测（只读）
    // ============================================================

    @PreAuthorize("hasAuthority('goods:bom:create')")
    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public BomImportReport detect(UUID goodsId, byte[] xlsx) {
        Parsed parsed = parseAndValidate(goodsId, xlsx);
        BomImportReport report = parsed.report();
        return new BomImportReport(report.totalRows(), report.errors(), report.warnings(), report.levelCounts(),
                report.readyToImport(), report.hasErrors() ? null : fingerprint(goodsId, xlsx, parsed));
    }

    // ============================================================
    // 提交（一个事务按层写入）
    // ============================================================

    @PreAuthorize("hasAuthority('goods:bom:create')")
    @Transactional
    public BomImportResult commit(UUID goodsId, byte[] xlsx, BomPasteRequest.Mode mode, String stateFingerprint) {
        if (stateFingerprint == null || !stateFingerprint.startsWith("v1:")) {
            throw new ApiException(ErrorCode.CONFLICT, "缺少有效的导入检测记录，请重新检测文件后提交（旧版客户端请先升级）");
        }
        if (mode == BomPasteRequest.Mode.REPLACE) {
            // 替换会删掉文件外的现有组件，与粘贴命令同口径要删除权(paste 内也会再查)。
            CurrentAuthorityGuard.requireAll("goods:bom:delete");
        }
        Parsed parsed = parseAndValidate(goodsId, xlsx);
        if (!parsed.errors().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "文件仍有 " + parsed.errors().size() + " 个未修正的问题，请先按检测报告修改后重试");
        }
        // 先按 id 顺序一次锁住本次要写的所有父件，再写任何一行：与粘贴命令、学习引擎同一锁序
        // (父件行在前、组装图锁在后)，多层导入不会与报工审核的学习发布互相等待。
        Set<UUID> parents = parentsOf(goodsId, parsed);
        goodsRepo.lockBomParents(parents);
        Set<UUID> involved = new LinkedHashSet<>(parents);
        for (ParsedRow row : parsed.rows()) involved.add(row.goodsId);
        pasteService.prepareImportReferences(involved);
        parsed = parseAndValidate(goodsId, xlsx);
        if (!parsed.errors().isEmpty() || !parents.equals(parentsOf(goodsId, parsed))) {
            throw new ApiException(ErrorCode.CONFLICT, "相关货品或组件结构在检测后已变化，请重新检测文件");
        }
        if (!stateFingerprint.equals(fingerprint(goodsId, xlsx, parsed))) {
            throw new ApiException(ErrorCode.CONFLICT, "BOM、学习用量或相关货品资料已变化，或文件与检测时不同；现有BOM未改动，请重新检测后提交");
        }
        int targets = 0;
        int added = 0;
        int removed = 0;
        List<String> warnings = new ArrayList<>();
        Set<UUID> writtenParents = new HashSet<>();
        // 按层写入：层 0 粘到目标货品；层 L(≥1) 按父序号分组粘到对应组件货品。
        // 父行一定在更浅的层（校验保证父序号存在），所以按层序写入时父货品 id 已解析。
        for (int level = 0; level < parsed.levels.size(); level++) {
            Map<String, List<ParsedRow>> byParent = new LinkedHashMap<>();
            for (ParsedRow row : parsed.levels.get(level)) {
                byParent.computeIfAbsent(row.parentSeq, ignored -> new ArrayList<>()).add(row);
            }
            for (Map.Entry<String, List<ParsedRow>> group : byParent.entrySet()) {
                UUID parentId = level == 0
                        ? goodsId
                        : parsed.bySeq().get(group.getKey()).goodsId;
                // BOM 是共享有向图，导出按路径展开。同一父件的相同子表只写一次。
                if (!writtenParents.add(parentId)) continue;
                List<BomItemSaveRequest> items = new ArrayList<>();
                Map<UUID, String> colorNames = new HashMap<>();
                for (ParsedRow row : group.getValue()) {
                    BomItemSaveRequest item = new BomItemSaveRequest();
                    item.setComponentGoodsId(row.goodsId);
                    item.setQty(row.qty);
                    if (parsed.columns().contains("consumptionBasis")) item.setConsumptionBasis(row.basisCode);
                    if (parsed.columns().contains("basisOutputQty")) item.setBasisOutputQty(row.basisOutputQty);
                    if (parsed.columns().contains("allowPartialPackage") && row.allowPartialPackage != null) {
                        item.setAllowPartialPackage(row.allowPartialPackage);
                    }
                    item.setSummary(row.summary);
                    colorNames.put(row.goodsId, row.colorName);
                    // 整批领料的料的异常单重、双料已在检测报告里逐行提醒, 提交即确认 (ADR-131)。
                    item.setConfirmUnusualWeight(true);
                    item.setConfirmSecondPeriodicMaterial(true);
                    items.add(item);
                }
                BomPasteResult result = pasteService.pasteImported(new BomPasteRequest(
                        mode,
                        List.of(new BomPasteRequest.Target(parentId, null)),
                        items), parsed.columns(), colorNames);
                targets += result.targets();
                added += result.added();
                removed += result.removed();
                warnings.addAll(result.warnings());
            }
        }
        pasteService.markImportApplied(parents);
        return new BomImportResult(targets, added, removed, parsed.levels.size(), List.copyOf(warnings));
    }

    private Set<UUID> parentsOf(UUID goodsId, Parsed parsed) {
        Set<UUID> parents = new LinkedHashSet<>();
        parents.add(goodsId);
        for (int level = 1; level < parsed.levels.size(); level++) {
            for (ParsedRow row : parsed.levels.get(level)) parents.add(parsed.bySeq().get(row.parentSeq).goodsId);
        }
        return parents;
    }

    private String fingerprint(UUID goodsId, byte[] xlsx, Parsed parsed) {
        Set<UUID> parents = parentsOf(goodsId, parsed);
        Set<UUID> involved = new LinkedHashSet<>(parents);
        Set<String> colors = new LinkedHashSet<>();
        for (ParsedRow row : parsed.rows()) if (row.goodsId != null) involved.add(row.goodsId);
        for (ParsedRow row : parsed.rows()) {
            if (row.colorName != null && !row.colorName.isBlank()) colors.add(row.colorName.trim().toLowerCase(java.util.Locale.ROOT));
        }
        try {
            String fileHash = java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(xlsx));
            return "v1:" + com.uten.imp.common.util.HashUtil.sha256(goodsId + "\n" + fileHash + "\n"
                    + pasteService.importStateSnapshot(parents, involved, colors));
        } catch (java.security.NoSuchAlgorithmException impossible) {
            throw new IllegalStateException(impossible);
        }
    }

    // ============================================================
    // 解析 + 校验（detect / commit 同一条路径，commit 以提交时刻状态复检）
    // ============================================================

    private Parsed parseAndValidate(UUID goodsId, byte[] xlsx) {
        Goods target = goodsRepo.findById(goodsId)
                .filter(g -> !g.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "货品不存在"));
        if (xlsx == null || xlsx.length == 0) {
            throw invalidWorkbook("所选 Excel 文件为空，请重新选择");
        }
        if (xlsx.length < 4 || xlsx[0] != 0x50 || xlsx[1] != 0x4B) {
            throw invalidWorkbook("文件为旧版 .xls、已加密或内容损坏，请另存为未加密的 .xlsx 后重试");
        }
        GoodsImportWorkbookSecurity.inspectArchive(xlsx);
        List<GoodsImportError> errors = new ArrayList<>();
        List<GoodsImportError> warnings = new ArrayList<>();
        List<ParsedRow> rows = new ArrayList<>();
        Set<String> columns = new HashSet<>();
        try (Workbook wb = WorkbookFactory.create(new ByteArrayInputStream(xlsx))) {
            GoodsImportWorkbookSecurity.inspectWorkbook(wb);
            if (wb.getNumberOfSheets() == 0) {
                throw invalidWorkbook("Excel 文件不包含工作表，请使用「导出组件」的格式后重试");
            }
            Sheet sheet = wb.getSheetAt(0);
            Row header = sheet.getRow(0);
            if (header == null) {
                errors.add(new GoodsImportError(1, "表头", "首个工作表无表头行"));
                return parsedOf(rows, errors, warnings, columns);
            }
            Map<String, Integer> col = mapHeaders(header);
            columns.addAll(col.keySet());
            for (String required : new String[]{"seq", "code", "qty"}) {
                if (!col.containsKey(required)) {
                    errors.add(new GoodsImportError(1, "表头", "缺少必填列：" + labelOf(required)));
                }
            }
            if (!errors.isEmpty()) {
                return parsedOf(rows, errors, warnings, columns);
            }
            DataFormatter df = new DataFormatter();
            for (int ri = 1; ri <= sheet.getLastRowNum(); ri++) {
                Row row = sheet.getRow(ri);
                if (row == null) continue;
                String seq = trim(df, row, col, "seq");
                String code = trim(df, row, col, "code");
                String name = trim(df, row, col, "name");
                if (isBlank(seq) && isBlank(code)) continue;
                if (TOTAL_KEYWORDS.contains(code) || TOTAL_KEYWORDS.contains(name)) continue;
                ParsedRow parsed = parseRow(ri + 1, seq, code, row, col, df, errors);
                if (parsed != null) rows.add(parsed);
                if (rows.size() > MAX_ROWS) {
                    errors.add(new GoodsImportError(ri + 1, "行数",
                            "组装清单超过 " + MAX_ROWS + " 行上限，请拆分后导入"));
                    break;
                }
            }
        } catch (ApiException e) {
            throw e;
        } catch (EncryptedDocumentException e) {
            throw invalidWorkbook("Excel 已设置打开密码，请另存为未加密的 .xlsx 后重试");
        } catch (org.apache.poi.openxml4j.exceptions.OpenXML4JRuntimeException
                 | RecordFormatException | IllegalArgumentException e) {
            throw invalidWorkbook("无法解析 Excel 文件，请确认文件未损坏且为未加密的 .xlsx");
        } catch (IOException e) {
            throw invalidWorkbook("无法读取 Excel 文件，请确认文件未损坏且为未加密的 .xlsx");
        }

        // ---- 树与匹配校验 ----
        validateTree(target, rows, errors, warnings);
        if (columns.contains("color")) validateColors(goodsId, rows, errors);
        return parsedOf(rows, errors, warnings, columns);
    }

    private void validateColors(UUID goodsId, List<ParsedRow> rows, List<GoodsImportError> errors) {
        Map<String, ParsedRow> bySeq = new HashMap<>();
        for (ParsedRow row : rows) bySeq.putIfAbsent(row.seq, row);
        Map<UUID, List<ParsedRow>> byParent = new LinkedHashMap<>();
        for (ParsedRow row : rows) {
            ParsedRow parent = bySeq.get(row.parentSeq);
            UUID parentId = row.parentSeq == null ? goodsId : parent == null ? null : parent.goodsId;
            if (row.goodsId != null && parentId != null) {
                byParent.computeIfAbsent(parentId, ignored -> new ArrayList<>()).add(row);
            }
        }
        for (var entry : byParent.entrySet()) {
            Map<UUID, String> names = new HashMap<>();
            for (ParsedRow row : entry.getValue()) names.put(row.goodsId, row.colorName);
            Map<UUID, String> problems = pasteService.importedColorProblems(entry.getKey(), names);
            for (ParsedRow row : entry.getValue()) {
                if (problems.containsKey(row.goodsId)) {
                    errors.add(new GoodsImportError(row.rowNum, "颜色", problems.get(row.goodsId)));
                }
            }
        }
    }

    /** 组装中间态：按序号索引供按层写入时找父行（序号重复时以首行为准，错误已另行报出）。 */
    private Parsed parsedOf(List<ParsedRow> rows, List<GoodsImportError> errors,
                            List<GoodsImportError> warnings, Set<String> columns) {
        Map<String, ParsedRow> bySeq = new LinkedHashMap<>();
        for (ParsedRow row : rows) {
            if (row.seq != null) bySeq.putIfAbsent(row.seq, row);
        }
        List<List<ParsedRow>> levels = groupByLevel(rows);
        return new Parsed(rows, errors, warnings, levels, bySeq, Set.copyOf(columns),
                reportOf(rows, errors, warnings));
    }

    private ParsedRow parseRow(int rowNum, String seq, String code, Row row,
                               Map<String, Integer> col, DataFormatter df,
                               List<GoodsImportError> errors) {
        ParsedRow parsed = new ParsedRow();
        parsed.rowNum = rowNum;
        parsed.seq = seq;
        parsed.code = code;
        if (isBlank(code)) {
            errors.add(new GoodsImportError(rowNum, "物料编号", "物料编号不能为空"));
        }
        if (isBlank(seq) || !SEQ_PATTERN.matcher(seq).matches()) {
            errors.add(new GoodsImportError(rowNum, "序号",
                    "序号「" + seq + "」不是有效的级联序号（应为 1 / 2 / 2.1 这样的编号）"));
        } else {
            parsed.level = seq.split("\\.").length - 1;
            if (parsed.level >= GoodsBomFileLimits.MAX_LEVELS) {
                errors.add(new GoodsImportError(rowNum, "序号", "BOM 文件最多支持 "
                        + GoodsBomFileLimits.MAX_LEVELS + " 层，请从下层组件分别导入"));
            }
            parsed.parentSeq = parsed.level == 0
                    ? null : seq.substring(0, seq.lastIndexOf('.'));
        }
        String qtyLabel = labelOf("qty");
        try {
            parsed.qty = number(df, row, col, "qty");
            if (parsed.qty == null) {
                errors.add(new GoodsImportError(rowNum, qtyLabel, qtyLabel + "不能为空"));
            } else if (parsed.qty.signum() <= 0) {
                errors.add(new GoodsImportError(rowNum, qtyLabel, qtyLabel + "必须大于 0"));
            }
        } catch (NumericRangeException e) {
            errors.add(new GoodsImportError(rowNum, qtyLabel, qtyLabel + e.getMessage()));
        } catch (NumberFormatException e) {
            errors.add(new GoodsImportError(rowNum, qtyLabel,
                    qtyLabel + "「" + trim(df, row, col, "qty") + "」不是有效数字"));
        }
        String basisRaw = normKey(trim(df, row, col, "consumptionBasis"));
        if (isBlank(basisRaw)) {
            parsed.basisCode = "PER_UNIT";
        } else if (BASIS_LABELS.containsKey(basisRaw)) {
            parsed.basisCode = BASIS_LABELS.get(basisRaw);
        } else {
            errors.add(new GoodsImportError(rowNum, "计量方式",
                    "计量方式必须为 按每件/按包装/固定批耗（当前「" + basisRaw + "」）"));
            parsed.basisCode = "PER_UNIT";
        }
        try {
            BigDecimal basisOutputQty = number(df, row, col, "basisOutputQty");
            parsed.basisOutputQty = basisOutputQty == null ? BigDecimal.ONE : basisOutputQty;
        } catch (NumericRangeException e) {
            errors.add(new GoodsImportError(rowNum, "基准产量", "基准产量" + e.getMessage()));
            parsed.basisOutputQty = BigDecimal.ONE;
        } catch (NumberFormatException e) {
            errors.add(new GoodsImportError(rowNum, "基准产量",
                    "基准产量「" + trim(df, row, col, "basisOutputQty") + "」不是有效数字"));
            parsed.basisOutputQty = BigDecimal.ONE;
        }
        if (parsed.basisOutputQty.signum() <= 0) {
            errors.add(new GoodsImportError(rowNum, "基准产量", "基准产量必须大于 0"));
        }
        String partialRaw = trim(df, row, col, "allowPartialPackage");
        if (isBlank(partialRaw) || "—".equals(partialRaw) || "-".equals(partialRaw)) {
            parsed.allowPartialPackage = null;
        } else if ("允许".equals(partialRaw)) {
            parsed.allowPartialPackage = true;
        } else if ("整包".equals(partialRaw)) {
            parsed.allowPartialPackage = false;
        } else {
            errors.add(new GoodsImportError(rowNum, "尾包", "尾包必须为 允许/整包"));
        }
        parsed.summary = blankToNull(trim(df, row, col, "summary"));
        parsed.name = blankToNull(trim(df, row, col, "name"));
        parsed.colorName = trim(df, row, col, "color");
        return parsed;
    }

    /** 树结构与货品匹配校验：序号唯一、父序号存在、编号可解析、同层不重复、不含目标自身。 */
    private void validateTree(Goods target, List<ParsedRow> rows,
                              List<GoodsImportError> errors,
                              List<GoodsImportError> warnings) {
        Map<String, ParsedRow> bySeq = new LinkedHashMap<>();
        Set<String> seenSeq = new HashSet<>();
        Map<String, Goods> codeIndex = new LinkedHashMap<>();
        Set<String> missingCodes = new HashSet<>();
        for (ParsedRow row : rows) {
            if (row.seq != null && !seenSeq.add(row.seq)) {
                errors.add(new GoodsImportError(row.rowNum, "序号",
                        "序号「" + row.seq + "」在文件内重复"));
            } else if (row.seq != null) {
                bySeq.put(row.seq, row);
            }
            if (!isBlank(row.code) && !codeIndex.containsKey(row.code) && !missingCodes.contains(row.code)) {
                goodsRepo.findByCodeAndDeletedFalse(row.code)
                        .ifPresentOrElse(g -> codeIndex.put(row.code, g),
                                () -> missingCodes.add(row.code));
            }
        }
        for (ParsedRow row : rows) {
            if (row.parentSeq != null && !bySeq.containsKey(row.parentSeq)) {
                errors.add(new GoodsImportError(row.rowNum, "序号",
                        "序号「" + row.seq + "」的上级「" + row.parentSeq + "」不在文件里"));
            }
            Goods component = codeIndex.get(row.code);
            if (isBlank(row.code)) continue;
            if (component == null) {
                errors.add(new GoodsImportError(row.rowNum, "物料编号",
                        "物料编号「" + row.code + "」在系统里不存在"));
            } else {
                row.goodsId = component.getId();
                if (row.name != null && component.getName() != null
                        && !row.name.isBlank() && !row.name.equals(component.getName())) {
                    warnings.add(new GoodsImportError(row.rowNum, "物料名称",
                            "「" + row.code + "」文件名称为「" + row.name
                                    + "」，系统货品名为「" + component.getName() + "」，按编号导入"));
                }
                if (component.getId().equals(target.getId())) {
                    errors.add(new GoodsImportError(row.rowNum, "物料编号",
                            "不能把货品自己装配成自己的组件（" + row.code + " 就是本货品）"));
                }
            }
        }
        // 同一父级下组件编号重复：粘贴命令会整批拒，这里在检测期就报行号。
        Map<String, Set<UUID>> perParent = new HashMap<>();
        for (ParsedRow row : rows) {
            if (row.goodsId == null) continue;
            String parent = row.parentSeq == null ? "" : row.parentSeq;
            if (!perParent.computeIfAbsent(parent, ignored -> new HashSet<>()).add(row.goodsId)) {
                errors.add(new GoodsImportError(row.rowNum, "物料编号",
                        "物料编号「" + row.code + "」在同一层级重复出现"));
            }
        }
        validatePeriodicEdges(target, rows, bySeq, codeIndex, errors, warnings);
        validateSharedParents(rows, errors);
    }

    /** 不同展开路径指向同一货品时，只能描述同一套直接组件，不能按最后一条路径静默覆盖。 */
    private void validateSharedParents(List<ParsedRow> rows, List<GoodsImportError> errors) {
        Map<String, List<ParsedRow>> children = new HashMap<>();
        for (ParsedRow row : rows) {
            if (row.parentSeq != null) children.computeIfAbsent(row.parentSeq, ignored -> new ArrayList<>()).add(row);
        }
        Map<UUID, List<List<Object>>> definitions = new HashMap<>();
        for (ParsedRow parent : rows) {
            if (parent.goodsId == null) continue;
            List<List<Object>> definition = children.getOrDefault(parent.seq, List.of()).stream()
                    .map(row -> java.util.Arrays.<Object>asList(row.goodsId, normalized(row.qty), row.basisCode,
                            normalized(row.basisOutputQty), row.allowPartialPackage, row.colorName, row.summary))
                    .toList();
            List<List<Object>> previous = definitions.putIfAbsent(parent.goodsId, definition);
            if (previous != null && !previous.equals(definition)) {
                errors.add(new GoodsImportError(parent.rowNum, "序号", "共享组件「" + parent.code
                        + "」在不同层级路径中的子组件、顺序或用量不一致，或文件缺少一处完整子表，请统一后导入"));
            }
        }
    }

    private static BigDecimal normalized(BigDecimal value) {
        return value == null ? null : value.stripTrailingZeros();
    }

    /**
     * 整批领料的料 (期间边, ADR-131 §3.2): 在 BOM 里只填单个重量, 形状由写入时自动归一 (开工前、按每件、
     * 基准产量 1、不设齐套门槛), 数量按"数量 / 基准产量"折成每件用量; 辅料 (色母) 不写进 BOM;
     * 按包装或固定批耗计量的拒绝。异常单重、与货品资料单重相差 20% 以上、同一产品两种料逐行提醒,
     * 提交即按此写入。
     */
    private void validatePeriodicEdges(Goods target, List<ParsedRow> rows, Map<String, ParsedRow> bySeq,
                                       Map<String, Goods> codeIndex, List<GoodsImportError> errors,
                                       List<GoodsImportError> warnings) {
        Map<String, Integer> periodicPerParent = new HashMap<>();
        for (ParsedRow row : rows) {
            Goods component = row.goodsId == null ? null : codeIndex.get(row.code);
            if (!GoodsPeriodicMaterialRules.isPeriodic(component)) continue;
            if (GoodsPeriodicMaterialRules.isSharedBasis(component.getPeriodicCostBasis())) {
                errors.add(new GoodsImportError(row.rowNum, "物料编号",
                        "「" + row.code + "」: " + GoodsPeriodicMaterialRules.SHARED_NOT_IN_BOM));
                continue;
            }
            if (!"PER_UNIT".equals(row.basisCode)) {
                errors.add(new GoodsImportError(row.rowNum, "计量方式",
                        "「" + row.code + "」是整批领到车间内料仓的料, 在 BOM 里只填单个重量, 计量方式请填 按每件"));
                continue;
            }
            Goods parent = row.parentSeq == null ? target
                    : bySeq.get(row.parentSeq) == null ? null : codeIndex.get(bySeq.get(row.parentSeq).code);
            String parentKey = row.parentSeq == null ? "" : row.parentSeq;
            if (periodicPerParent.merge(parentKey, 1, Integer::sum) == 2) {
                warnings.add(new GoodsImportError(row.rowNum, "物料编号",
                        GoodsPeriodicMaterialRules.secondMaterialMessage(GoodsPeriodicMaterialRules.label(parent))
                                + " (提交即按两种料写入)"));
            }
            if (row.qty == null || row.qty.signum() <= 0 || row.basisOutputQty == null
                    || row.basisOutputQty.signum() <= 0) continue;
            BigDecimal perUnit = row.qty.divide(row.basisOutputQty, GoodsPeriodicMaterialRules.QTY_SCALE,
                    RoundingMode.HALF_UP);
            if (perUnit.precision() - perUnit.scale() > 13) {
                errors.add(new GoodsImportError(row.rowNum, "数量", "折算后的每件用量超出可保存范围"));
                continue;
            }
            BigDecimal grams = GoodsPeriodicMaterialRules.toGrams(perUnit,
                    GoodsPeriodicMaterialRules.gramsPerUnit(component.getUnit()));
            if (perUnit.signum() <= 0) {
                errors.add(new GoodsImportError(row.rowNum, "数量", "「" + row.code + "」的单个重量太小, 最少 0.01 克"));
                continue;
            }
            if (GoodsPeriodicMaterialRules.unusual(grams)) {
                warnings.add(new GoodsImportError(row.rowNum, "数量",
                        "「" + row.code + "」的单个重量 " + GoodsPeriodicMaterialRules.gramsText(grams)
                                + " 克看起来不太对, 请核对; 提交即按此写入"));
            }
            String difference = GoodsPeriodicMaterialRules.differenceWarning(
                    GoodsPeriodicMaterialRules.label(parent), grams, GoodsPeriodicMaterialRules.goodsWeightGrams(parent));
            if (difference != null) {
                warnings.add(new GoodsImportError(row.rowNum, "数量", difference));
            }
        }
    }

    /** 按层分桶（层 0 = 顶层），供按层写入与报告里的 levelCounts。 */
    private List<List<ParsedRow>> groupByLevel(List<ParsedRow> rows) {
        int maxLevel = 0;
        for (ParsedRow row : rows) {
            maxLevel = Math.max(maxLevel, row.level);
        }
        List<List<ParsedRow>> levels = new ArrayList<>();
        for (int i = 0; i <= maxLevel; i++) levels.add(new ArrayList<>());
        for (ParsedRow row : rows) {
            levels.get(row.level).add(row);
        }
        // 层桶里有空档（比如只有 1 和 3.1 没有 3）时 validateTree 已把父序号缺失报错，
        // 这里不再二次判。
        return levels;
    }

    private BomImportReport reportOf(List<ParsedRow> rows, List<GoodsImportError> errors,
                                     List<GoodsImportError> warnings) {
        List<Integer> levelCounts = groupByLevel(rows).stream()
                .map(List::size).toList();
        int errorRows = (int) errors.stream().map(GoodsImportError::rowNum).distinct().count();
        return new BomImportReport(rows.size(), errors, warnings, levelCounts,
                Math.max(0, rows.size() - errorRows), null);
    }

    private Map<String, Integer> mapHeaders(Row header) {
        Map<String, Integer> col = new HashMap<>();
        DataFormatter df = new DataFormatter();
        for (int c = 0; c < header.getLastCellNum(); c++) {
            Cell cell = header.getCell(c);
            if (cell == null) continue;
            String raw = df.formatCellValue(cell);
            if (raw == null) continue;
            String key = HEADER_ALIASES.get(normKey(raw));
            if (key != null && !col.containsKey(key)) col.put(key, c);
        }
        return col;
    }

    private static String trim(DataFormatter df, Row row, Map<String, Integer> col, String key) {
        Integer index = col.get(key);
        if (index == null) return "";
        Cell cell = row.getCell(index);
        if (cell == null) return "";
        String value = df.formatCellValue(cell);
        return value == null ? "" : value.trim();
    }

    /**
     * 数值单元格按存的值读(不按「#,##0.00」之类的显示格式，否则 0.03125 会读成 0.03)；
     * 文本只接受完整数字、规范千分位和科学计数法，不删除单位/百分号等字符后悄悄改义。
     * 公式单元格到不了这里：文件检查(GoodsImportWorkbookSecurity)已整份拒收。
     */
    private static BigDecimal number(DataFormatter df, Row row, Map<String, Integer> col, String key) {
        Integer index = col.get(key);
        Cell cell = index == null ? null : row.getCell(index);
        if (cell == null) return null;
        if (cell.getCellType() == CellType.NUMERIC) {
            // BigDecimal.valueOf 取 double 的最短十进制写法(0.03125、1.0E-5)；不能再过下面的字符过滤。
            return boundedNumber(BigDecimal.valueOf(cell.getNumericCellValue()), key);
        }
        String raw = trim(df, row, col, key);
        if (isBlank(raw)) return null;
        if (!NUMBER_PATTERN.matcher(raw).matches()) throw new NumberFormatException("Invalid numeric cell");
        return boundedNumber(new BigDecimal(raw.replace(",", "")), key);
    }

    private static BigDecimal boundedNumber(BigDecimal value, String key) {
        int scale = "basisOutputQty".equals(key) ? 6 : 5;
        // 先查表示范围，再做去尾零/乘除，阻断科学计数法的极端指数导致巨大内存分配。
        if (value.precision() > 64 || value.scale() < -18 || value.scale() > 64
                || (long) value.precision() - value.scale() > 18 - scale
                || value.stripTrailingZeros().scale() > scale) {
            throw new NumericRangeException("最多支持 " + (18 - scale) + " 位整数和 " + scale
                    + " 位小数，请修正数值（不能把正用量舍入为零）");
        }
        return value;
    }

    private static final class NumericRangeException extends NumberFormatException {
        NumericRangeException(String message) { super(message); }
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private static String blankToNull(String value) {
        return isBlank(value) ? null : value;
    }

    private static String labelOf(String key) {
        return switch (key) {
            case "seq" -> "序号";
            case "code" -> "物料编号";
            case "qty" -> "设计使用数量";
            default -> key;
        };
    }

    private static ApiException invalidWorkbook(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    /** 解析中间态。 */
    private record Parsed(List<ParsedRow> rows,
                          List<GoodsImportError> errors,
                          List<GoodsImportError> warnings,
                          List<List<ParsedRow>> levels,
                          Map<String, ParsedRow> bySeq,
                          Set<String> columns,
                          BomImportReport report) {}

    /** 一行组件（含解析出的层级/父序号与解析到的货品 id）。 */
    private static final class ParsedRow {
        int rowNum;
        String seq;
        String parentSeq;
        int level;
        String code;
        String name;
        UUID goodsId;
        BigDecimal qty;
        String basisCode;
        BigDecimal basisOutputQty;
        Boolean allowPartialPackage;
        String colorName;
        String summary;
    }
}
