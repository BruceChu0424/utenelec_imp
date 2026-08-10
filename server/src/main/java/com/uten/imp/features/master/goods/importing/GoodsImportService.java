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
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.DataFormatter;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.ss.usermodel.WorkbookFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 货品批量导入（goods:import）：两段式「先检测后导入」+ 一键撤回。
 *
 * <p>检测（detect）：解析 .xlsx（POI）→ 逐行校验（编号查重 in-file + vs-DB、必填、枚举、引用歧义），
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
 *   <li>编号：必填、文件内唯一、库里不存在；命中即报错不覆盖。</li>
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

    public GoodsImportReport detect(byte[] xlsx) {
        Parsed parsed = parse(xlsx);
        List<GoodsImportError> errors = new ArrayList<>(parsed.headerErrors);
        if (!parsed.headerErrors.isEmpty()) {
            return new GoodsImportReport(parsed.totalRows, 0, errors, List.of(), List.of(), List.of(), 0);
        }
        CategoryIndex index = new CategoryIndex(categoryRepo.findByDeletedFalseOrderBySortOrderAscNameAsc());
        Set<String> willCreateCat = new LinkedHashSet<>();
        Set<String> willCreateColor = new LinkedHashSet<>();
        Set<String> willCreateUnit = new LinkedHashSet<>();
        Set<String> seenCodes = new HashSet<>();
        int dataRows = 0;

        for (ParsedRow r : parsed.rows) {
            dataRows++;
            if (r.code == null || r.code.isEmpty()) {
                errors.add(new GoodsImportError(r.rowNum, "编号", "编号不能为空"));
            } else if (!seenCodes.add(r.code)) {
                errors.add(new GoodsImportError(r.rowNum, "编号", "编号「" + r.code + "」在本文件内重复"));
            } else if (goodsRepo.existsByCodeAndDeletedFalse(r.code)) {
                errors.add(new GoodsImportError(r.rowNum, "编号", "编号「" + r.code + "」在系统中已存在"));
            }
            if (r.name == null || r.name.isEmpty()) {
                errors.add(new GoodsImportError(r.rowNum, "货品名称", "货品名称不能为空"));
            }
            if (r.categorySegments == null || r.categorySegments.isEmpty()) {
                errors.add(new GoodsImportError(r.rowNum, "类别", "类别不能为空"));
            } else {
                String walk = index.simulatePath(r.categorySegments);
                if (walk == null) {
                    errors.add(new GoodsImportError(r.rowNum, "类别", "分类路径存在歧义（同父同名节点）"));
                } else if (!walk.isEmpty()) {
                    willCreateCat.add(walk);
                }
            }
            if (r.sourceType != null && !r.sourceType.isEmpty() && !VALID_SOURCE_TYPES.contains(r.sourceType)) {
                errors.add(new GoodsImportError(r.rowNum, "来源", "来源必须为 自制/采购/委外"));
            }
            if (r.status != null && !r.status.isEmpty() && !VALID_STATUSES.contains(r.status)) {
                errors.add(new GoodsImportError(r.rowNum, "状态", "状态必须为 使用/禁用"));
            }
            if (r.colorName != null && !r.colorName.isEmpty()
                    && colorRepo.findFirstByNameIgnoreCaseAndDeletedFalse(r.colorName).isEmpty()) {
                willCreateColor.add(r.colorName);
            }
            if (r.unitName != null && !r.unitName.isEmpty()
                    && unitRepo.findFirstByNameIgnoreCaseAndDeletedFalse(r.unitName).isEmpty()) {
                willCreateUnit.add(r.unitName);
            }
        }
        int errorRows = (int) errors.stream().map(GoodsImportError::rowNum).distinct().count();
        return new GoodsImportReport(parsed.totalRows, dataRows, errors,
                new ArrayList<>(willCreateCat), new ArrayList<>(willCreateColor),
                new ArrayList<>(willCreateUnit), Math.max(0, dataRows - errorRows));
    }

    // ============================================================
    // 提交（原子事务）
    // ============================================================

    @Transactional
    public GoodsImportResult commit(byte[] xlsx, String filename) {
        Parsed parsed = parse(xlsx);
        List<GoodsImportError> errors = validateForCommit(parsed);
        if (!errors.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "导入文件存在 " + errors.size() + " 个错误，请先用「检测」查看并修正");
        }

        UUID batchId = UUID.randomUUID();
        UUID actorId = currentUser.get().map(AuthUser::getId).orElse(null);
        em.createNativeQuery("""
                INSERT INTO goods_import_batches (id, created_by, filename, row_count, status)
                VALUES (:id, :actor, :fn, 0, 'IMPORTED')
                """)
                .setParameter("id", batchId)
                .setParameter("actor", actorId)
                .setParameter("fn", filename)
                .executeUpdate();

        CategoryIndex index = new CategoryIndex(categoryRepo.findByDeletedFalseOrderBySortOrderAscNameAsc());
        Map<String, Integer> colorCache = new HashMap<>();
        Map<String, Integer> unitCache = new HashMap<>();
        List<String> createdCatPaths = new ArrayList<>();
        int createdCats = 0, createdColors = 0, createdUnits = 0;

        for (ParsedRow r : parsed.rows) {
            int[] catCnt = new int[1];
            UUID categoryId = resolveCategory(index, r.categorySegments, batchId, createdCatPaths, catCnt);
            createdCats += catCnt[0];
            int[] colorCnt = new int[1];
            Integer colorLegacyId = resolveColor(r.colorName, colorCache, batchId, colorCnt);
            createdColors += colorCnt[0];
            int[] unitCnt = new int[1];
            Integer unitLegacyId = resolveUnit(r.unitName, unitCache, batchId, unitCnt);
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
            if (colorLegacyId != null) req.setColorLegacyId(colorLegacyId);
            if (unitLegacyId != null) req.setUnitLegacyId(unitLegacyId);
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

    /** 解析分类路径：缺则逐级新建并登记；返回叶子 id。createdHolder[0] 累加新建数。 */
    private UUID resolveCategory(CategoryIndex index, List<String> segments, UUID batchId,
                                 List<String> createdPaths, int[] createdHolder) {
        UUID parentId = null;
        List<String> pathSoFar = new ArrayList<>();
        for (String seg : segments) {
            List<UUID> kids = index.childrenOf(parentId, seg);
            UUID childId;
            if (kids.isEmpty()) {
                MaterialCategorySaveRequest cr = new MaterialCategorySaveRequest();
                cr.setName(seg);
                cr.setParentId(parentId);
                MaterialCategoryDetail d = categoryService.create(cr);
                childId = d.getId();
                index.registerCreated(parentId, seg, childId);
                recordCreation(batchId, "CATEGORY", childId);
                createdHolder[0]++;
                List<String> fullPath = new ArrayList<>(pathSoFar);
                fullPath.add(seg);
                createdPaths.add(String.join("-", fullPath));
            } else {
                childId = kids.get(0);
            }
            pathSoFar.add(seg);
            parentId = childId;
        }
        return parentId;
    }

    private Integer resolveColor(String normName, Map<String, Integer> cache, UUID batchId, int[] createdHolder) {
        if (normName == null || normName.isEmpty()) return null;
        Integer cached = cache.get(normName);
        if (cached != null) return cached;
        Optional<Color> existing = colorRepo.findFirstByNameIgnoreCaseAndDeletedFalse(normName);
        Integer legacyId;
        if (existing.isPresent()) {
            legacyId = existing.get().getLegacyId();
        } else {
            ColorSaveRequest cr = new ColorSaveRequest();
            cr.setName(normName);
            cr.setStatus("使用");
            ColorDetail d = colorService.create(cr);
            recordCreation(batchId, "COLOR", d.getId());
            createdHolder[0]++;
            legacyId = d.getLegacyId();
        }
        cache.put(normName, legacyId);
        return legacyId;
    }

    private Integer resolveUnit(String normName, Map<String, Integer> cache, UUID batchId, int[] createdHolder) {
        if (normName == null || normName.isEmpty()) return null;
        Integer cached = cache.get(normName);
        if (cached != null) return cached;
        Optional<Unit> existing = unitRepo.findFirstByNameIgnoreCaseAndDeletedFalse(normName);
        Integer legacyId;
        if (existing.isPresent()) {
            legacyId = existing.get().getLegacyId();
        } else {
            UnitSaveRequest cr = new UnitSaveRequest();
            cr.setName(normName);
            cr.setStatus("使用");
            UnitDetail d = unitService.create(cr);
            recordCreation(batchId, "UNIT", d.getId());
            createdHolder[0]++;
            legacyId = d.getLegacyId();
        }
        cache.put(normName, legacyId);
        return legacyId;
    }

    /** 提交前防御性校验（与 detect 同口径）。 */
    private List<GoodsImportError> validateForCommit(Parsed parsed) {
        List<GoodsImportError> errors = new ArrayList<>(parsed.headerErrors);
        Set<String> seenCodes = new HashSet<>();
        for (ParsedRow r : parsed.rows) {
            if (r.code == null || r.code.isEmpty()
                    || !seenCodes.add(r.code)
                    || goodsRepo.existsByCodeAndDeletedFalse(r.code)) {
                errors.add(new GoodsImportError(r.rowNum, "编号", "编号为空/重复/已存在"));
            }
            if (r.name == null || r.name.isEmpty()) {
                errors.add(new GoodsImportError(r.rowNum, "货品名称", "货品名称不能为空"));
            }
            if (r.categorySegments == null || r.categorySegments.isEmpty()) {
                errors.add(new GoodsImportError(r.rowNum, "类别", "类别不能为空"));
            }
        }
        return errors;
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
        try (Workbook wb = WorkbookFactory.create(new ByteArrayInputStream(xlsx))) {
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
                String code = normKey(str(row, col.get("code")));
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
        } catch (IOException e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "无法读取 Excel 文件（请确认为 .xlsx）");
        }
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
    // 分类树索引（内存 walk，避免逐行 CTE；树 ~881 节点）
    // ============================================================

    private static final class CategoryIndex {
        final Map<String, List<UUID>> children = new HashMap<>();

        CategoryIndex(List<MaterialCategory> all) {
            for (MaterialCategory c : all) {
                UUID pid = c.getParent() == null ? null : c.getParent().getId();
                children.computeIfAbsent(childKey(pid, normKey(c.getName())), k -> new ArrayList<>())
                        .add(c.getId());
            }
        }

        private static String childKey(UUID parentId, String normName) {
            return (parentId == null ? "ROOT" : parentId.toString()) + "::" + normName;
        }

        List<UUID> childrenOf(UUID parentId, String normName) {
            return children.getOrDefault(childKey(parentId, normName), List.of());
        }

        void registerCreated(UUID parentId, String normName, UUID id) {
            children.computeIfAbsent(childKey(parentId, normName), k -> new ArrayList<>()).add(id);
        }

        /** 模拟路径：全部已存在→""；需新建→返回将建的整条路径；同父同名歧义→null。 */
        String simulatePath(List<String> segments) {
            UUID parentId = null;
            for (String seg : segments) {
                List<UUID> kids = childrenOf(parentId, seg);
                if (kids.isEmpty()) return String.join("-", segments);
                if (kids.size() > 1) return null;
                parentId = kids.get(0);
            }
            return "";
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
}
