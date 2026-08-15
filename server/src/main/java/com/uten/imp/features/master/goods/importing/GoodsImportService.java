package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorDetail;
import com.uten.imp.features.master.color.dto.ColorSaveRequest;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.materialcategory.MaterialCategoryService;
import com.uten.imp.features.master.materialcategory.dto.MaterialCategoryDetail;
import com.uten.imp.features.master.materialcategory.dto.MaterialCategorySaveRequest;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.unit.dto.UnitDetail;
import com.uten.imp.features.master.unit.dto.UnitSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.apache.poi.EncryptedDocumentException;
import org.apache.poi.openxml4j.exceptions.OpenXML4JRuntimeException;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.DataFormatter;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.apache.poi.util.RecordFormatException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/**
 * 货品批量导入（goods:import）：两段式「先检测后导入」+ 一键撤回。
 *
 * <p>检测（detect）：解析 .xlsx（POI）→ 逐行校验（显式编号查重 in-file + vs-DB、必填、枚举、引用歧义），
 * 产出报告（错误清单 + 将自动新建的分类/颜色/单位）。不写库。前端据此拦住有错的提交。
 *
 * <p>提交（commit）：同一事务内重跑解析+校验（不信任 detect 与 commit 间状态不变）→ 建缺失
 * 分类（按路径逐级）/颜色/单位（复用各 Service 的 name 查重 + legacy_id 合成）→ 复用
 * {@link GoodsService#saveImported} 批量建货品（编号查重命中即整批回滚）→ 登记 batch + creations。
 *
 * <p>撤回（undo）：按 {@code goods_import_creations} 软删本批次新建的全部实体（只删本批新建的，
 * 批次前已有的分类/颜色不动）。
 *
 * <p>规则（与用户锁定）：
 * <ul>
 *   <li>分类分隔符只认标准 {@code -}（两侧空格 trim）；其它「横杠样」字符不切 → 自然匹配不上报错。</li>
 *   <li>空格：匹配键（编号/分类/颜色/单位/系列）全删空白含全角/NBSP + 全角转半角；
 *         货品名 trim + 内部多空格合并一个。</li>
 *   <li>编号：允许留空并由目标分类规则自动分配；显式填写时须文件内唯一且库里不存在。</li>
 *   <li>缺失分类/颜色/单位：自动新建（登记录撤回）。</li>
 *   <li>仅收 .xlsx；跳过空行/合计/总计/小计/标题行；公式错误单元格当空。</li>
 * </ul>
 */
@Service
@RequiredArgsConstructor
public class GoodsImportService {

    private final GoodsService goodsService;
    private final GoodsRepository goodsRepo;
    private final MaterialCategoryService categoryService;
    private final MaterialCategoryRepository categoryRepo;
    private final ColorService colorService;
    private final ColorRepository colorRepo;
    private final UnitService unitService;
    private final UnitRepository unitRepo;
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;

    /**
     * detect -> commit is deliberately a short-lived, single-node capability.
     * It is bounded to avoid untrusted uploads growing server memory forever.
     * A restart intentionally invalidates every plan; commit then fails closed
     * and asks the operator to detect the workbook again.
     */
    private final ConcurrentMap<UUID, ImportPlan> plans = new ConcurrentHashMap<>();
    private static final Duration PLAN_TTL = Duration.ofMinutes(5);
    private static final int MAX_ACTIVE_PLANS = 128;

    private static final Map<String, String> HEADER_ALIASES = new HashMap<>();
    static {
        for (String a : new String[]{"编号", "编码", "货品编号", "物料编码", "number", "code"}) putAlias(a, "code");
        for (String a : new String[]{"类别", "分类", "分类路径", "物料分类"}) putAlias(a, "categoryPath");
        for (String a : new String[]{"系列", "物料系列"}) putAlias(a, "series");
        putAlias("型号", "model");
        for (String a : new String[]{"名称", "货品名称", "货品名", "物料名称"}) putAlias(a, "name");
        putAlias("规格", "spec");
        for (String a : new String[]{"材质", "材料"}) putAlias(a, "material");
        for (String a : new String[]{"颜色", "主颜色"}) putAlias(a, "colorName");
        for (String a : new String[]{"单位", "基本单位"}) putAlias(a, "unitName");
        putAlias("来源", "sourceType");
        for (String a : new String[]{"价格", "单价"}) putAlias(a, "price");
        putAlias("状态", "status");
        // 导出有但 DTO 未开放编辑——识别但忽略其值（不报「无法识别」）。
        for (String a : new String[]{"客户型号", "备注"}) putAlias(a, "ignored");
    }

    private static void putAlias(String alias, String key) {
        HEADER_ALIASES.put(normKey(alias), key);
    }

    private static final Set<String> VALID_SOURCE_TYPES = Set.of("自制", "采购", "委外");
    private static final Set<String> VALID_STATUSES = Set.of("使用", "禁用");
    private static final Set<String> TOTAL_KEYWORDS = Set.of("合计", "总计", "小计");

    // ============================================================
    // 检测（只读）
    // ============================================================

    /** 检测（只读）：解析+校验 xlsx（编号文件内/系统内重复、名称缺失、分类歧义、来源/状态非法），规划需新建的分类/颜色/单位；无错时落一条绑定 文件 sha256+主档指纹 的导入计划，供 commit 一次性消费。 */
    public GoodsImportReport detect(byte[] xlsx) {
        Parsed parsed = parse(xlsx);
        List<GoodsImportError> errors = new ArrayList<>(parsed.headerErrors);
        if (!parsed.headerErrors.isEmpty()) {
            return new GoodsImportReport(
                    parsed.totalRows, 0, errors, List.of(), List.of(), List.of(), 0, null);
        }

        MasterSnapshot masters = loadMasterSnapshot();
        CategoryPlanIndex categoryIndex = new CategoryPlanIndex(masters.categories());
        NamedMasterPlanIndex<Color> colorIndex = new NamedMasterPlanIndex<>(
                masters.colors(), Color::getId, Color::getName, Color::isDeleted);
        NamedMasterPlanIndex<Unit> unitIndex = new NamedMasterPlanIndex<>(
                masters.units(), Unit::getId, Unit::getName, Unit::isDeleted);
        Set<String> willCreateCat = new LinkedHashSet<>();
        Set<String> willCreateColor = new LinkedHashSet<>();
        Set<String> willCreateUnit = new LinkedHashSet<>();
        Set<String> seenCodes = new HashSet<>();
        List<PlannedRow> plannedRows = new ArrayList<>();
        int dataRows = 0;

        for (ParsedRow r : parsed.rows) {
            dataRows++;
            if (r.code != null && !r.code.isEmpty()) {
                if (!seenCodes.add(r.code)) {
                    errors.add(new GoodsImportError(r.rowNum, "编号", "编号「" + r.code + "」在本文件内重复"));
                } else if (goodsRepo.existsByCodeAndDeletedFalse(r.code)) {
                    errors.add(new GoodsImportError(r.rowNum, "编号", "编号「" + r.code + "」在系统中已存在"));
                }
            }
            if (r.name == null || r.name.isEmpty()) {
                errors.add(new GoodsImportError(r.rowNum, "货品名称", "货品名称不能为空"));
            }
            CategoryPathPlan category = null;
            if (r.categorySegments == null || r.categorySegments.isEmpty()) {
                errors.add(new GoodsImportError(r.rowNum, "类别", "类别不能为空"));
            } else {
                category = categoryIndex.plan(r.categorySegments, willCreateCat);
                if (category == null) {
                    errors.add(new GoodsImportError(r.rowNum, "类别", "分类路径存在歧义（同父同名节点）"));
                }
            }
            if (r.sourceType != null && !r.sourceType.isEmpty() && !VALID_SOURCE_TYPES.contains(r.sourceType)) {
                errors.add(new GoodsImportError(r.rowNum, "来源", "来源必须为 自制/采购/委外"));
            }
            if (r.status != null && !r.status.isEmpty() && !VALID_STATUSES.contains(r.status)) {
                errors.add(new GoodsImportError(r.rowNum, "状态", "状态必须为 使用/禁用"));
            }
            PlannedMasterReference color = planNamedMaster(
                    r.rowNum, "主颜色", r.colorName, colorIndex, willCreateColor, errors);
            PlannedMasterReference unit = planNamedMaster(
                    r.rowNum, "单位", r.unitName, unitIndex, willCreateUnit, errors);
            plannedRows.add(new PlannedRow(r.rowNum, category, color, unit));
        }
        int errorRows = (int) errors.stream().map(GoodsImportError::rowNum).distinct().count();
        UUID planId = null;
        if (errors.isEmpty()) {
            planId = rememberPlan(
                    sha256(xlsx), masters.fingerprint(), currentActorId(), plannedRows);
        }
        return new GoodsImportReport(parsed.totalRows, dataRows, errors,
                new ArrayList<>(willCreateCat), new ArrayList<>(willCreateColor),
                new ArrayList<>(willCreateUnit), Math.max(0, dataRows - errorRows), planId);
    }

    // ============================================================
    // 提交（原子事务）
    // ============================================================

    /** 提交：一次性消费 detect 落出的计划，重解析后校验行号与主档指纹未变（防检测后主档被改/文件被换），再按计划 UUID/token 原子建分类、颜色、单位与货品。 */
    @Transactional
    public GoodsImportResult commit(UUID planId, byte[] xlsx, String filename) {
        ImportPlan plan = requireAndConsumePlan(planId, xlsx);
        Parsed parsed = parse(xlsx);
        if (parsed.rows.size() != plan.rows().size()) {
            throw stalePlan("导入文件解析结果已变化");
        }
        MasterSnapshot currentMasters = loadMasterSnapshot();
        if (!MessageDigest.isEqual(
                plan.masterFingerprint().getBytes(StandardCharsets.US_ASCII),
                currentMasters.fingerprint().getBytes(StandardCharsets.US_ASCII))) {
            throw stalePlan("分类、颜色或单位资料在检测后发生了变化");
        }

        UUID batchId = UUID.randomUUID();
        UUID actorId = currentActorId();
        em.createNativeQuery("""
                INSERT INTO goods_import_batches (id, created_by, filename, row_count, status)
                VALUES (:id, :actor, :fn, 0, 'IMPORTED')
                """)
                .setParameter("id", batchId)
                .setParameter("actor", actorId)
                .setParameter("fn", filename)
                .executeUpdate();

        Map<UUID, UUID> categoryTokens = new HashMap<>();
        Map<UUID, UUID> colorTokens = new HashMap<>();
        Map<UUID, UUID> unitTokens = new HashMap<>();
        List<String> createdCatPaths = new ArrayList<>();
        int createdCats = 0, createdColors = 0, createdUnits = 0;

        for (int rowIndex = 0; rowIndex < parsed.rows.size(); rowIndex++) {
            ParsedRow r = parsed.rows.get(rowIndex);
            PlannedRow planned = plan.rows().get(rowIndex);
            if (r.rowNum != planned.rowNum()) {
                throw stalePlan("导入文件行号已变化");
            }
            int[] catCnt = new int[1];
            UUID categoryId = materializeCategory(
                    planned.category(), categoryTokens, batchId, createdCatPaths, catCnt);
            createdCats += catCnt[0];
            int[] colorCnt = new int[1];
            UUID colorId = materializeColor(
                    planned.color(), colorTokens, batchId, colorCnt);
            createdColors += colorCnt[0];
            int[] unitCnt = new int[1];
            UUID unitId = materializeUnit(
                    planned.unit(), unitTokens, batchId, unitCnt);
            createdUnits += unitCnt[0];

            GoodsSaveRequest req = new GoodsSaveRequest();
            req.setCode(r.code);
            req.setName(r.name);
            req.setCategoryId(categoryId);
            req.setSeries(emptyToNull(r.series));
            req.setModel(emptyToNull(r.model));
            req.setSpec(emptyToNull(r.spec));
            req.setMaterial(emptyToNull(r.material));
            req.setSourceType(emptyToNull(r.sourceType));
            req.setPrice(r.price);
            req.setStatus(emptyToNull(r.status));
            // Runtime relationships are UUID-only. legacy_id is never used to
            // resolve or write an imported goods relationship.
            if (colorId != null) req.setColorId(colorId);
            if (unitId != null) req.setUnitId(unitId);
            UUID goodsId = goodsService.saveImported(req);
            recordCreation(batchId, "GOODS", goodsId);
        }

        em.createNativeQuery("UPDATE goods_import_batches SET row_count = :n WHERE id = :id")
                .setParameter("n", parsed.rows.size())
                .setParameter("id", batchId)
                .executeUpdate();

        return new GoodsImportResult(batchId, parsed.rows.size(),
                createdCats, createdColors, createdUnits, createdCatPaths);
    }

    /** 按 detect 时固化的 existing UUID / new-token 建分类，不再按名称二次猜测。 */
    private UUID materializeCategory(CategoryPathPlan plan,
                                     Map<UUID, UUID> tokenIds,
                                     UUID batchId,
                                     List<String> createdPaths,
                                     int[] createdHolder) {
        if (plan == null || plan.segments().isEmpty()) {
            throw stalePlan("导入计划缺少分类 UUID 解析结果");
        }
        UUID parentId = null;
        List<String> pathSoFar = new ArrayList<>();
        for (PlannedCategorySegment segment : plan.segments()) {
            UUID childId;
            if (segment.existingId() != null) {
                childId = segment.existingId();
            } else {
                childId = tokenIds.get(segment.newToken());
            }
            if (childId == null) {
                MaterialCategorySaveRequest cr = new MaterialCategorySaveRequest();
                cr.setName(segment.name());
                cr.setParentId(parentId);
                MaterialCategoryDetail d = categoryService.create(cr);
                childId = d.getId();
                if (childId == null) {
                    throw stalePlan("新建分类未返回 UUID");
                }
                tokenIds.put(segment.newToken(), childId);
                recordCreation(batchId, "CATEGORY", childId);
                createdHolder[0]++;
                List<String> fullPath = new ArrayList<>(pathSoFar);
                fullPath.add(segment.name());
                createdPaths.add(String.join("-", fullPath));
            }
            pathSoFar.add(segment.name());
            parentId = childId;
        }
        return parentId;
    }

    private UUID materializeColor(PlannedMasterReference reference,
                                  Map<UUID, UUID> tokenIds,
                                  UUID batchId,
                                  int[] createdHolder) {
        if (reference == null) return null;
        if (reference.existingId() != null) return reference.existingId();
        UUID cached = tokenIds.get(reference.newToken());
        if (cached != null) return cached;
        ColorSaveRequest cr = new ColorSaveRequest();
        cr.setName(reference.name());
        cr.setStatus("使用");
        ColorDetail d = colorService.create(cr);
        UUID id = d.getId();
        if (id == null) throw stalePlan("新建颜色未返回 UUID");
        tokenIds.put(reference.newToken(), id);
        recordCreation(batchId, "COLOR", id);
        createdHolder[0]++;
        return id;
    }

    private UUID materializeUnit(PlannedMasterReference reference,
                                 Map<UUID, UUID> tokenIds,
                                 UUID batchId,
                                 int[] createdHolder) {
        if (reference == null) return null;
        if (reference.existingId() != null) return reference.existingId();
        UUID cached = tokenIds.get(reference.newToken());
        if (cached != null) return cached;
        UnitSaveRequest cr = new UnitSaveRequest();
        cr.setName(reference.name());
        cr.setStatus("使用");
        UnitDetail d = unitService.create(cr);
        UUID id = d.getId();
        if (id == null) throw stalePlan("新建单位未返回 UUID");
        tokenIds.put(reference.newToken(), id);
        recordCreation(batchId, "UNIT", id);
        createdHolder[0]++;
        return id;
    }

    private void recordCreation(UUID batchId, String entityType, UUID entityId) {
        em.createNativeQuery("""
                INSERT INTO goods_import_creations (batch_id, entity_type, entity_id)
                VALUES (:b, :t, :e) ON CONFLICT DO NOTHING
                """)
                .setParameter("b", batchId)
                .setParameter("t", entityType)
                .setParameter("e", entityId)
                .executeUpdate();
    }

    // ============================================================
    // 撤回
    // ============================================================

    /** 最近一次未撤回的导入批次（撤回按钮入口用）。无则 null。 */
    @Transactional(readOnly = true)
    public GoodsImportBatchInfo latestBatch() {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(
                "SELECT id, created_at, filename, row_count "
                        + "FROM goods_import_batches WHERE status='IMPORTED' ORDER BY created_at DESC LIMIT 1")
                .getResultList();
        if (rows.isEmpty()) return null;
        Object[] r = rows.get(0);
        return new GoodsImportBatchInfo(toUuid(r[0]), toOdt(r[1]), (String) r[2], ((Number) r[3]).intValue());
    }

    @Transactional
    public int undo(UUID batchId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(
                "SELECT entity_type, entity_id FROM goods_import_creations WHERE batch_id = :b")
                .setParameter("b", batchId)
                .getResultList();
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "导入批次不存在或已撤回");
        }
        Map<String, List<UUID>> byType = new HashMap<>();
        for (String t : List.of("GOODS", "CATEGORY", "COLOR", "UNIT")) byType.put(t, new ArrayList<>());
        for (Object[] r : rows) {
            String t = (String) r[0];
            byType.computeIfAbsent(t, k -> new ArrayList<>()).add(toUuid(r[1]));
        }
        int affected = 0;
        affected += softDelete("goods", byType.get("GOODS"));
        affected += softDelete("material_categories", byType.get("CATEGORY"));
        affected += softDelete("colors", byType.get("COLOR"));
        affected += softDelete("units", byType.get("UNIT"));
        em.createNativeQuery("UPDATE goods_import_batches SET status='UNDONE' WHERE id=:b")
                .setParameter("b", batchId).executeUpdate();
        return affected;
    }

    private int softDelete(String table, List<UUID> ids) {
        if (ids == null || ids.isEmpty()) return 0;
        // 表名来自固定白名单（非用户输入）
        return em.createNativeQuery(
                "UPDATE " + table + " SET is_deleted = true, deleted_at = now() "
                        + "WHERE id IN (:ids) AND is_deleted = false")
                .setParameter("ids", ids)
                .executeUpdate();
    }

    // ============================================================
    // 解析 + 规范化
    // ============================================================

    private Parsed parse(byte[] xlsx) {
        List<ParsedRow> rows = new ArrayList<>();
        List<GoodsImportError> headerErrors = new ArrayList<>();
        if (xlsx == null || xlsx.length == 0) {
            throw invalidWorkbook("所选 Excel 文件为空，请重新选择");
        }
        // A normal .xlsx is an OOXML ZIP package. Legacy .xls files and
        // password-protected .xlsx files use an OLE compound container; both
        // need to be re-saved as an unencrypted .xlsx before this import flow.
        if (xlsx.length < 4 || xlsx[0] != 0x50 || xlsx[1] != 0x4B) {
            throw invalidWorkbook("文件为旧版 .xls、已加密或内容损坏，请另存为未加密的 .xlsx 后重试");
        }
        GoodsImportWorkbookSecurity.inspectArchive(xlsx);
        try (Workbook wb = WorkbookFactory.create(new ByteArrayInputStream(xlsx))) {
            GoodsImportWorkbookSecurity.inspectWorkbook(wb);
            if (wb.getNumberOfSheets() == 0) {
                throw invalidWorkbook("Excel 文件不包含工作表，请使用货品导出格式后重试");
            }
            Sheet sheet = wb.getSheetAt(0);
            Row header = sheet.getRow(0);
            if (header == null) {
                headerErrors.add(new GoodsImportError(1, "表头", "首个工作表无表头行"));
                return new Parsed(rows, headerErrors, 0);
            }
            Map<String, Integer> col = mapHeaders(header);
            for (String req : new String[]{"code", "name", "categoryPath"}) {
                if (!col.containsKey(req)) {
                    headerErrors.add(new GoodsImportError(1, "表头", "缺少必填列：" + reqLabel(req)));
                }
            }
            if (!headerErrors.isEmpty()) {
                return new Parsed(rows, headerErrors, 0);
            }
            int totalRows = 0;
            for (int ri = 1; ri <= sheet.getLastRowNum(); ri++) {
                Row row = sheet.getRow(ri);
                if (row == null) continue;
                String code = normCode(str(row, col.get("code")));
                String name = normName(str(row, col.get("name")));
                if ((code == null || code.isEmpty()) && (name == null || name.isEmpty())) continue;
                if (isTotalMarker(code) || isTotalMarker(name)) continue;
                totalRows++;
                ParsedRow pr = new ParsedRow();
                pr.rowNum = ri + 1;
                pr.code = code;
                pr.name = name;
                pr.series = normKey(str(row, col.get("series")));
                pr.model = trim(str(row, col.get("model")));
                pr.spec = trim(str(row, col.get("spec")));
                pr.material = trim(str(row, col.get("material")));
                pr.colorName = normKey(str(row, col.get("colorName")));
                pr.unitName = normKey(str(row, col.get("unitName")));
                pr.sourceType = normKey(str(row, col.get("sourceType")));
                pr.status = trim(str(row, col.get("status")));
                pr.price = parsePrice(str(row, col.get("price")), pr.rowNum, headerErrors);
                pr.categorySegments = splitCategory(str(row, col.get("categoryPath")));
                rows.add(pr);
            }
            return new Parsed(rows, headerErrors, totalRows);
        } catch (EncryptedDocumentException e) {
            throw invalidWorkbook("Excel 已设置打开密码，请另存为未加密的 .xlsx 后重试");
        } catch (OpenXML4JRuntimeException | RecordFormatException | IllegalArgumentException e) {
            throw invalidWorkbook("无法解析 Excel 文件，请确认文件未损坏且为未加密的 .xlsx");
        } catch (IOException e) {
            throw invalidWorkbook("无法读取 Excel 文件，请确认文件未损坏且为未加密的 .xlsx");
        }
    }

    private static ApiException invalidWorkbook(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
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
            if (key != null && !"ignored".equals(key) && !col.containsKey(key)) col.put(key, c);
        }
        return col;
    }

    /** 分类路径：仅按标准 {@code -} 切分，每段 normKey；空段丢弃。 */
    private List<String> splitCategory(String raw) {
        if (raw == null || raw.isBlank()) return List.of();
        String[] parts = raw.trim().split("-", -1);
        List<String> segs = new ArrayList<>();
        for (String p : parts) {
            String s = normKey(p);
            if (!s.isEmpty()) segs.add(s);
        }
        return segs;
    }

    private BigDecimal parsePrice(String raw, int rowNum, List<GoodsImportError> errors) {
        if (raw == null || raw.isBlank()) return null;
        String cleaned = raw.replaceAll("[^0-9.\\-]", "");
        if (cleaned.isEmpty() || ".".equals(cleaned) || "-".equals(cleaned)) return null;
        try {
            return new BigDecimal(cleaned);
        } catch (NumberFormatException e) {
            errors.add(new GoodsImportError(rowNum, "价格", "价格「" + raw + "」不是有效数字"));
            return null;
        }
    }

    private static String reqLabel(String key) {
        return switch (key) {
            case "code" -> "编号";
            case "name" -> "货品名称";
            case "categoryPath" -> "类别";
            default -> key;
        };
    }

    private static boolean isTotalMarker(String s) {
        if (s == null) return false;
        String t = s.trim();
        return TOTAL_KEYWORDS.stream().anyMatch(t::contains);
    }

    private static String str(Row row, Integer colIdx) {
        if (colIdx == null) return null;
        Cell cell = row.getCell(colIdx);
        if (cell == null) return null;
        String v = new DataFormatter().formatCellValue(cell);
        if (v == null) return null;
        v = v.replace("﻿", "");
        if (v.startsWith("#") && v.contains("!")) return ""; // 公式错误当空
        return v;
    }

    private static String emptyToNull(String s) {
        return (s == null || s.isEmpty()) ? null : s;
    }

    /** 匹配键规范化：全角转半角 + 删全部空白（含全角空格/NBSP，(?U) 覆盖 Unicode 空白）+ 清零宽/BOM。 */
    static String normKey(String s) {
        if (s == null) return null;
        return fullWidthToHalf(s).replaceAll("(?U)\\s+", "")
                .replaceAll("[\\u200B\\uFEFF]", "");
    }

    /** 与 CategoryDrivenCodeService 的显式编号口径一致，检测阶段即按大写查重。 */
    static String normCode(String s) {
        String normalized = normKey(s);
        return normalized == null ? null : normalized.toUpperCase(java.util.Locale.ROOT);
    }

    /** 货品名规范化：全角空格→普通、内部多空格（含 NBSP）合并一个、首尾清（决策 B）。 */
    private static String normName(String s) {
        if (s == null) return null;
        return fullWidthToHalf(s).replaceAll("[\\u200B\\uFEFF]", "")
                .replaceAll("(?U)\\s+", " ").strip();
    }

    private static String trim(String s) {
        return s == null ? null : s.trim();
    }

    private static String fullWidthToHalf(String s) {
        if (s == null) return null;
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '　') sb.append(' ');
            else if (c >= '！' && c <= '～') sb.append((char) (c - 0xFEE0));
            else sb.append(c);
        }
        return sb.toString();
    }

    private static UUID toUuid(Object o) {
        if (o == null) return null;
        return o instanceof UUID u ? u : UUID.fromString(o.toString());
    }

    private static java.time.OffsetDateTime toOdt(Object o) {
        if (o == null) return null;
        if (o instanceof java.time.OffsetDateTime od) return od;
        if (o instanceof java.sql.Timestamp ts) return ts.toInstant().atOffset(java.time.ZoneOffset.UTC);
        if (o instanceof java.time.Instant inst) return inst.atOffset(java.time.ZoneOffset.UTC);
        if (o instanceof java.util.Date d) return d.toInstant().atOffset(java.time.ZoneOffset.UTC);
        return null;
    }

    // ============================================================
    // detect -> commit 安全计划
    // ============================================================

    private MasterSnapshot loadMasterSnapshot() {
        return new MasterSnapshot(
                categoryRepo.findByDeletedFalseOrderBySortOrderAscNameAsc(),
                colorRepo.findAll(),
                unitRepo.findAll());
    }

    private UUID currentActorId() {
        return currentUser.requireId();
    }

    private UUID rememberPlan(String workbookHash,
                              String masterFingerprint,
                              UUID actorId,
                              List<PlannedRow> rows) {
        Instant now = Instant.now();
        plans.entrySet().removeIf(entry -> !entry.getValue().expiresAt().isAfter(now));
        if (plans.size() >= MAX_ACTIVE_PLANS) {
            plans.entrySet().stream()
                    .min(Comparator.comparing(entry -> entry.getValue().expiresAt()))
                    .ifPresent(entry -> plans.remove(entry.getKey(), entry.getValue()));
        }
        UUID id = UUID.randomUUID();
        plans.put(id, new ImportPlan(
                id, actorId, workbookHash, masterFingerprint,
                List.copyOf(rows), now.plus(PLAN_TTL)));
        return id;
    }

    private ImportPlan requireAndConsumePlan(UUID planId, byte[] workbook) {
        if (planId == null) {
            throw stalePlan("缺少检测计划");
        }
        ImportPlan plan = plans.remove(planId);
        if (plan == null) {
            throw stalePlan("检测计划不存在、已使用或服务已重启");
        }
        if (!plan.expiresAt().isAfter(Instant.now())) {
            throw stalePlan("检测计划已过期");
        }
        if (!Objects.equals(plan.actorId(), currentActorId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "检测计划不属于当前用户，请重新检测");
        }
        String actualHash = sha256(workbook);
        if (!MessageDigest.isEqual(
                plan.workbookHash().getBytes(StandardCharsets.US_ASCII),
                actualHash.getBytes(StandardCharsets.US_ASCII))) {
            throw stalePlan("提交文件与检测文件不一致");
        }
        return plan;
    }

    private static PlannedMasterReference planNamedMaster(
            int rowNum,
            String column,
            String name,
            NamedMasterPlanIndex<?> index,
            Set<String> willCreate,
            List<GoodsImportError> errors) {
        if (name == null || name.isEmpty()) return null;
        List<UUID> matches = index.ids(name);
        if (matches.size() > 1) {
            errors.add(new GoodsImportError(
                    rowNum, column, column + "名称存在多个主档记录，无法确定 UUID，请先清理重复资料"));
            return null;
        }
        if (matches.size() == 1) {
            return new PlannedMasterReference(matches.get(0), null, name);
        }
        willCreate.add(name);
        return new PlannedMasterReference(null, index.newToken(name), name);
    }

    private static String sha256(byte[] bytes) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            return java.util.HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 unavailable", impossible);
        }
    }

    private static ApiException stalePlan(String reason) {
        return new ApiException(
                ErrorCode.CONFLICT,
                reason + "，为避免关联到错误主档，本次未导入；请重新检测后再提交");
    }

    // ============================================================
    // 分类树/扁平主档计划索引
    // ============================================================

    private static final class CategoryPlanIndex {
        final Map<String, List<UUID>> existingChildren = new HashMap<>();
        final Map<String, PlannedCategorySegment> plannedChildren = new HashMap<>();

        CategoryPlanIndex(List<MaterialCategory> all) {
            for (MaterialCategory c : all) {
                UUID pid = c.getParent() == null ? null : c.getParent().getId();
                existingChildren.computeIfAbsent(
                                childKey(existingParent(pid), normKey(c.getName())),
                                ignored -> new ArrayList<>())
                        .add(c.getId());
            }
        }

        CategoryPathPlan plan(List<String> segments, Set<String> willCreate) {
            String parentRef = "ROOT";
            List<PlannedCategorySegment> result = new ArrayList<>();
            List<String> path = new ArrayList<>();
            for (String name : segments) {
                path.add(name);
                String key = childKey(parentRef, name);
                List<UUID> matches = existingChildren.getOrDefault(key, List.of());
                if (matches.size() > 1) return null;
                PlannedCategorySegment segment;
                if (matches.size() == 1) {
                    segment = new PlannedCategorySegment(matches.get(0), null, name);
                    parentRef = existingParent(matches.get(0));
                } else {
                    segment = plannedChildren.computeIfAbsent(
                            key,
                            ignored -> new PlannedCategorySegment(null, UUID.randomUUID(), name));
                    parentRef = tokenParent(segment.newToken());
                    willCreate.add(String.join("-", path));
                }
                result.add(segment);
            }
            return new CategoryPathPlan(List.copyOf(result));
        }

        private static String existingParent(UUID id) {
            return id == null ? "ROOT" : "ID:" + id;
        }

        private static String tokenParent(UUID token) {
            return "NEW:" + token;
        }

        private static String childKey(String parentRef, String normalizedName) {
            return parentRef + "::" + normalizedName;
        }
    }

    private static final class NamedMasterPlanIndex<T> {
        private final Map<String, List<UUID>> idsByName = new HashMap<>();
        private final Map<String, UUID> tokensByName = new HashMap<>();

        NamedMasterPlanIndex(List<T> all,
                             java.util.function.Function<T, UUID> id,
                             java.util.function.Function<T, String> name,
                             java.util.function.Predicate<T> deleted) {
            for (T item : all) {
                if (deleted.test(item)) continue;
                String key = normKey(name.apply(item));
                idsByName.computeIfAbsent(key, ignored -> new ArrayList<>()).add(id.apply(item));
            }
        }

        List<UUID> ids(String normalizedName) {
            return idsByName.getOrDefault(normalizedName, List.of());
        }

        UUID newToken(String normalizedName) {
            return tokensByName.computeIfAbsent(normalizedName, ignored -> UUID.randomUUID());
        }
    }

    // ============================================================
    // 解析结果载体
    // ============================================================

    private static final class Parsed {
        final List<ParsedRow> rows;
        final List<GoodsImportError> headerErrors;
        final int totalRows;

        Parsed(List<ParsedRow> rows, List<GoodsImportError> headerErrors, int totalRows) {
            this.rows = rows;
            this.headerErrors = headerErrors;
            this.totalRows = totalRows;
        }
    }

    private static final class ParsedRow {
        int rowNum;
        String code;
        String name;
        String series;
        String model;
        String spec;
        String material;
        String colorName;
        String unitName;
        String sourceType;
        String status;
        BigDecimal price;
        List<String> categorySegments;
    }

    private record ImportPlan(
            UUID id,
            UUID actorId,
            String workbookHash,
            String masterFingerprint,
            List<PlannedRow> rows,
            Instant expiresAt) {}

    private record PlannedRow(
            int rowNum,
            CategoryPathPlan category,
            PlannedMasterReference color,
            PlannedMasterReference unit) {}

    private record CategoryPathPlan(List<PlannedCategorySegment> segments) {}

    private record PlannedCategorySegment(UUID existingId, UUID newToken, String name) {}

    private record PlannedMasterReference(UUID existingId, UUID newToken, String name) {}

    private record MasterSnapshot(
            List<MaterialCategory> categories,
            List<Color> colors,
            List<Unit> units) {

        String fingerprint() {
            List<String> entries = new ArrayList<>();
            for (MaterialCategory category : categories) {
                UUID parentId = category.getParent() == null ? null : category.getParent().getId();
                entries.add("C|" + category.getId() + "|" + parentId + "|"
                        + normKey(category.getName()) + "|" + category.isDeleted());
            }
            for (Color color : colors) {
                entries.add("O|" + color.getId() + "|" + normKey(color.getName())
                        + "|" + color.isDeleted());
            }
            for (Unit unit : units) {
                entries.add("U|" + unit.getId() + "|" + normKey(unit.getName())
                        + "|" + unit.isDeleted());
            }
            entries.sort(String::compareTo);
            return sha256(String.join("\n", entries).getBytes(StandardCharsets.UTF_8));
        }
    }
}
