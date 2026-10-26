package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorDetail;
import com.uten.imp.features.master.color.dto.ColorSaveRequest;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.goods.Goods;
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
import com.uten.imp.features.master.lifecycle.MasterLifecycleService;
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
    private final MasterLifecycleService lifecycle;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.features.master.goods.history.GoodsOperationHistoryService operationHistory;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.application.port.GoodsMasterWriteAccessPort writeAccess;

    /**
     * detect -> commit is deliberately a short-lived, single-node capability.
     * It is bounded to avoid untrusted uploads growing server memory forever.
     * A restart intentionally invalidates every plan; commit then fails closed
     * and asks the operator to detect the workbook again.
     */
    private final ConcurrentMap<UUID, ImportPlan> plans = new ConcurrentHashMap<>();
    private static final Duration PLAN_TTL = Duration.ofMinutes(30);
    private static final int MAX_ACTIVE_PLANS = 32;
    private static final int MAX_CACHED_ROWS = 16_000;
    private static final long MAX_CACHED_PLAN_BYTES = 32L * 1024 * 1024;

    private static final Map<String, String> HEADER_ALIASES = new HashMap<>();
    static {
        for (String a : new String[]{"编号", "编码", "货品编号", "物料编码", "number", "code"}) putAlias(a, "code");
        for (String a : new String[]{"系统标识", "货品UUID", "货品ID", "goodsId", "UUID", "uuid", "id"}) putAlias(a, "goodsId");
        for (String a : new String[]{"类别", "分类", "分类路径", "物料分类"}) putAlias(a, "categoryPath");
        for (String a : new String[]{"系列", "物料系列"}) putAlias(a, "series");
        putAlias("型号", "model");
        for (String a : new String[]{"名称", "货品名称", "货品名", "物料名称"}) putAlias(a, "name");
        // Only explicit customer product labels populate this scalar. A customer
        // company name or the ordinary goods name is not a product-name alias.
        for (String a : new String[]{"客户货品名称", "客户品名"}) putAlias(a, "clientGoodsName");
        putAlias("客户型号", "cNumber");
        // 英文名称(ADR-134): 导出列名「英文名称」可原样导回; 常见英文表头一并认。
        // normKey 不做大小写归一, 几种常见写法都登记。
        for (String a : new String[]{"英文名称", "英文名", "英文品名", "English Name", "english name",
                "ENGLISH NAME", "EnglishName", "name_en", "NAME_EN", "nameEn"}) {
            putAlias(a, "nameEn");
        }
        putAlias("规格", "spec");
        for (String a : new String[]{"材质", "材料"}) putAlias(a, "material");
        for (String a : new String[]{"颜色", "主颜色"}) putAlias(a, "colorName");
        for (String a : new String[]{"单位", "基本单位"}) putAlias(a, "unitName");
        putAlias("来源", "sourceType");
        for (String a : new String[]{"价格", "单价"}) putAlias(a, "price");
        // 采购批量口径（V575）：供应商报价单/整箱表常用这几种叫法，一并认。
        // normKey 不做大小写归一，MOQ/moq 两种写法都登记。
        for (String a : new String[]{"最小起订量", "起订量", "最小订量", "MOQ", "moq"}) {
            putAlias(a, "minOrderQty");
        }
        for (String a : new String[]{"订货倍数", "整箱数量", "整包装量", "包装倍数"}) putAlias(a, "orderMultipleQty");
        putAlias("状态", "status");
        // 后模镶件编号（V457）：导出一直在写这一列，DTO 也开放编辑，
        // 但此前没登记别名 → 未识别表头被静默丢弃，导出改完再导入会把
        // 用户填的值悄悄吃掉。这里按可编辑文本列接线。
        for (String a : new String[]{"后模镶件编号", "后模镶件", "镶件编号"}) {
            putAlias(a, "rearInsertCode");
        }
        // 备注（2026-09-25 导入导出格式对齐）：GoodsSaveRequest.paper 本就可编辑，
        // 此前登记为 ignored → 导出里的备注列改完再导入会被静默丢弃。接线落库。
        for (String a : new String[]{"备注", "纸样"}) putAlias(a, "paper");
        // 导出有但 DTO 未开放编辑——识别但忽略其值（不报「无法识别」）。
        //
        // 所属仓库 (V587) / 生产车间 (V590, 2026-09-29 前表头叫「归属车间」) / 模具编号、模具名称
        // (2026-10-19 起导出携带模具名称列)：导出写这些列，
        // 但导入侧只拿得到「名称/编号」，而在线关系只认 UUID（本文件的 UUID-only 契约），
        // 按名反查会重蹈按名猜关系的老路，故登记为 ignored 只识别不落值——导出改完再导入，
        // 这些列的值不会写进新货品。必须登记：把「刻意丢弃」写成明账，避免后来人把它
        // 当成又一个 V457 式的漏登记去补，也避免别处误把它接成别的字段。真要支持编辑，
        // 得先给导入一条 UUID 口径的选择通道。
        for (String a : new String[]{"所属仓库", "归属仓库", "归属车间", "生产车间", "车间",
                "模具编号", "模具名称", "模具"}) putAlias(a, "ignored");
    }

    private static void putAlias(String alias, String key) {
        HEADER_ALIASES.put(normKey(alias), key);
    }

    /** 与 goods.rear_insert_code varchar(100)、GoodsSaveRequest 的 @Size(max=100) 对齐。 */
    private static final int REAR_INSERT_CODE_MAX = 100;

    /** 与 goods.name_en varchar(255) 对齐(ADR-134)。 */
    private static final int NAME_EN_MAX = com.uten.imp.features.master.goods.GoodsNameEn.MAX_LENGTH;

    private static final Set<String> VALID_SOURCE_TYPES = Set.of("自制", "采购", "委外");
    private static final Set<String> VALID_STATUSES = Set.of("使用", "禁用");
    private static final Set<String> TOTAL_KEYWORDS = Set.of("合计", "总计", "小计");

    // ============================================================
    // 检测（只读）
    // ============================================================

    /** 检测（只读）：解析+校验 xlsx（编号文件内/系统内重复、名称缺失、分类歧义、来源/状态非法），规划需新建的分类/颜色/单位；无错时落一条绑定 文件 sha256+主档指纹 的导入计划，供 commit 一次性消费。 */
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:import')")
    @Transactional(readOnly = true)
    public GoodsImportReport detect(byte[] xlsx) {
        Parsed parsed = parse(xlsx);
        List<GoodsImportError> errors = new ArrayList<>(parsed.headerErrors);
        if (!parsed.headerErrors.isEmpty()) {
            return new GoodsImportReport(
                    parsed.totalRows, 0, errors, List.of(), List.of(), List.of(), 0, 0, null);
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
        Set<UUID> seenGoods = new HashSet<>();
        List<GoodsImportIdentity> goodsSnapshot = goodsRepo.findImportIdentities();
        List<PlannedRow> plannedRows = new ArrayList<>();
        List<GoodsImportReviewRow> reviewRows = new ArrayList<>();
        int dataRows = 0;
        int restorableRows = 0;
        int addedRows = 0, unchangedRows = 0, fillRows = 0, conflictRows = 0;

        for (ParsedRow r : parsed.rows) {
            dataRows++;
            UUID restoreGoodsId = null;
            Goods existingGoods = null;
            String matchType = null;
            if (r.code != null && !r.code.isEmpty()) {
                if (!seenCodes.add(r.code)) {
                    errors.add(new GoodsImportError(r.rowNum, "编号", "编号「" + r.code + "」在本文件内重复"));
                } else {
                    existingGoods = goodsRepo.findByCodeAndDeletedFalse(r.code).orElse(null);
                    if (existingGoods != null) {
                        matchType = "CODE";
                    } else if (goodsRepo.existsByCodeAndDeletedFalse(r.code)) {
                        errors.add(new GoodsImportError(r.rowNum, "编号", "编号「" + r.code + "」在系统中已存在，但无法确定唯一货品"));
                    } else {
                    // 同编号命中已软删行：不再当冲突拦下，导入时以原 UUID 原编号恢复该行
                    //（2026-10-19「删除后同编号不能导入」根因修复，见 [commit]）。
                    List<UUID> deletedIds = goodsRepo.findRestorableDeletedIdsByCode(r.code);
                    if (deletedIds.size() > 1 && r.goodsId == null) {
                        errors.add(new GoodsImportError(r.rowNum, "系统标识", "同编号对应多个已删除货品，请填写原货品系统标识后核对恢复"));
                    } else if (!deletedIds.isEmpty()) {
                        if (r.goodsId != null && !deletedIds.contains(r.goodsId)) {
                            errors.add(new GoodsImportError(r.rowNum, "系统标识", "系统标识与已删除货品编号不一致，请核对原货品"));
                        } else restoreGoodsId = r.goodsId == null ? deletedIds.getFirst() : r.goodsId;
                    }
                    if (restoreGoodsId != null) {
                        restorableRows++;
                    }
                    }
                }
            }
            if (r.goodsId != null) {
                Goods byId = goodsRepo.findById(r.goodsId).orElse(null);
                if (byId == null || byId.isDeleted() && !Objects.equals(restoreGoodsId, byId.getId())) {
                    errors.add(new GoodsImportError(r.rowNum, "货品UUID", "货品 UUID 不存在或已删除，请重新导出后导入"));
                } else if (existingGoods != null && !existingGoods.getId().equals(byId.getId())) {
                    errors.add(new GoodsImportError(r.rowNum, "编号", "货品 UUID 与编号指向不同货品，请核对后重传"));
                } else if (!byId.isDeleted()) {
                    existingGoods = byId;
                    matchType = "UUID";
                }
            }
            if (r.goodsId == null && r.code != null && !r.code.isEmpty() && goodsRepo.codeHasReuseHistory(r.code)) {
                errors.add(new GoodsImportError(r.rowNum, "系统标识", "该编号曾复用，请重新导出并保留系统标识，核对当前货品后导入"));
            }
            if (r.name == null || r.name.isEmpty()) {
                errors.add(new GoodsImportError(r.rowNum, "货品名称", "货品名称不能为空"));
            }
            // 后模镶件编号是标识符，不是描述：超长截断会得到一个「看着正常、
            // 实际指错镶件」的编号，比让用户改表格更危险。列宽 varchar(100)
            // 与 DTO 的 @Size(max=100) 一致，这里在检测期就按行报错。
            if (r.rearInsertCode != null
                    && r.rearInsertCode.length() > REAR_INSERT_CODE_MAX) {
                errors.add(new GoodsImportError(r.rowNum, "后模镶件编号",
                        "后模镶件编号不能超过 " + REAR_INSERT_CODE_MAX + " 个字符，当前 "
                                + r.rearInsertCode.length() + " 个"));
            }
            // 英文名称同样是识别依据, 超长截断会得到错误的英文名, 检测期按行报错。
            if (r.nameEn != null && r.nameEn.codePointCount(0, r.nameEn.length()) > NAME_EN_MAX) {
                errors.add(new GoodsImportError(r.rowNum, "英文名称",
                        "英文名称不能超过 " + NAME_EN_MAX + " 个字符"));
            }
            CategoryPathPlan category = null;
            if (r.categorySegments == null || r.categorySegments.isEmpty()) {
                errors.add(new GoodsImportError(r.rowNum, "类别", "类别不能为空"));
            } else {
                category = categoryIndex.plan(r.categoryPath, r.categorySegments, willCreateCat);
                if (category == null) {
                    errors.add(new GoodsImportError(r.rowNum, "类别", "分类路径存在歧义（同父同名或名称含 - 导致路径重合），请先区分分类名称后重新导出"));
                }
            }
            if (r.sourceType != null && !r.sourceType.isEmpty() && !VALID_SOURCE_TYPES.contains(r.sourceType)) {
                errors.add(new GoodsImportError(r.rowNum, "来源", "来源必须为 自制/采购/委外"));
            }
            if (r.status != null && !r.status.isEmpty() && !VALID_STATUSES.contains(r.status)) {
                errors.add(new GoodsImportError(r.rowNum, "状态", "状态必须为 使用/禁用"));
            }
            // UUID/code are the only goods identities. A blank pair creates a
            // new row with an allocated code. Names, colors and materials are
            // descriptive: a same-name row must never silently update a variant.
            if (existingGoods != null) writeAccess.requireWritable(existingGoods.getId());
            boolean preserveLegacyColor = existingGoods != null && existingGoods.getColor() == null
                    && existingGoods.getColorLegacyId() != null
                    && legacyNameUnchanged(masters.colors(), existingGoods.getColorLegacyId(), r.colorName,
                    Color::getLegacyId, Color::getName, Color::isDeleted);
            boolean preserveLegacyUnit = existingGoods != null && existingGoods.getUnit() == null
                    && existingGoods.getUnitLegacyId() != null
                    && legacyNameUnchanged(masters.units(), existingGoods.getUnitLegacyId(), r.unitName,
                    Unit::getLegacyId, Unit::getName, Unit::isDeleted);
            PlannedMasterReference color = preserveLegacyColor ? null : planNamedMaster(
                    r.rowNum, "主颜色", r.colorName, colorIndex, willCreateColor, errors);
            PlannedMasterReference unit = preserveLegacyUnit ? null : planNamedMaster(
                    r.rowNum, "单位", r.unitName, unitIndex, willCreateUnit, errors);
            List<GoodsImportReviewRow.Change> changes = List.of();
            String goodsFingerprint = null;
            if (existingGoods != null) {
                if (!seenGoods.add(existingGoods.getId())) {
                    errors.add(new GoodsImportError(r.rowNum, "货品名称", "本文件多行对应同一货品，请合并为一行后重传"));
                }
                // Object scope is checked before returning any stored cell values.
                changes = changes(r, existingGoods, category, color, unit);
                goodsFingerprint = goodsFingerprint(existingGoods);
                if (changes.isEmpty()) unchangedRows++;
                else {
                    if (changes.stream().anyMatch(c -> "FILL".equals(c.kind()))) fillRows++;
                    if (changes.stream().anyMatch(c -> "CONFLICT".equals(c.kind()))) conflictRows++;
                    reviewRows.add(new GoodsImportReviewRow(rowKey(r.rowNum), r.rowNum,
                            existingGoods.getId(), existingGoods.getCode(), existingGoods.getName(),
                            categoryPath(existingGoods.getCategory()), matchType, changes));
                }
            } else if (restoreGoodsId == null) addedRows++;
            plannedRows.add(new PlannedRow(r.rowNum, category, color, unit, restoreGoodsId,
                    existingGoods == null ? null : existingGoods.getId(), goodsFingerprint, changes));
        }
        int errorRows = (int) errors.stream().map(GoodsImportError::rowNum).distinct().count();
        UUID planId = null;
        if (errors.isEmpty()) {
            planId = rememberPlan(
                    sha256(xlsx), masters.fingerprint(), identityFingerprint(goodsSnapshot), currentActorId(), plannedRows);
        }
        return new GoodsImportReport(parsed.totalRows, dataRows, errors,
                new ArrayList<>(willCreateCat), new ArrayList<>(willCreateColor),
                new ArrayList<>(willCreateUnit), Math.max(0, dataRows - errorRows - unchangedRows),
                restorableRows, planId, List.copyOf(reviewRows), addedRows, unchangedRows, fillRows, conflictRows);
    }

    // ============================================================
    // 提交（原子事务）
    // ============================================================

    /** 提交：一次性消费 detect 落出的计划，重解析后校验行号与主档指纹未变（防检测后主档被改/文件被换），再按计划 UUID/token 原子建分类、颜色、单位与货品。 */
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:import')")
    @Transactional
    public GoodsImportResult commit(UUID planId, byte[] xlsx, String filename) {
        return commit(planId, xlsx, filename, Set.of());
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:import')")
    @Transactional
    public GoodsImportResult commit(UUID planId, byte[] xlsx, String filename, Set<String> replaceRowKeys) {
        ImportPlan plan = requireAndConsumePlan(planId, xlsx);
        Set<String> replacements = replaceRowKeys == null ? Set.of() : Set.copyOf(replaceRowKeys);
        Set<String> allowedKeys = plan.rows().stream()
                .filter(row -> row.changes().stream().anyMatch(change -> "CONFLICT".equals(change.kind())))
                .map(row -> rowKey(row.rowNum())).collect(java.util.stream.Collectors.toSet());
        if (!allowedKeys.containsAll(replacements)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "替换选择包含检测报告以外的行，请重新检测");
        }
        Parsed parsed = parse(xlsx);
        if (parsed.rows.size() != plan.rows().size()) {
            throw stalePlan("导入文件解析结果已变化");
        }
        if (!Objects.equals(plan.masterFingerprint(), loadMasterSnapshot().fingerprint())) {
            throw stalePlan("分类、颜色或单位资料在检测后发生了变化");
        }
        // Serialize with master edits/deletes and with competing imports, including
        // insertion of a same-path/name goods after detection. NOWAIT fails closed.
        try {
            em.createNativeQuery("LOCK TABLE colors,units,material_categories,goods IN SHARE ROW EXCLUSIVE MODE NOWAIT").executeUpdate();
        } catch (RuntimeException busy) {
            throw new ApiException(ErrorCode.CONFLICT, "基础资料正在更新，请稍后重新检测后导入");
        }
        // The pre-lock comparison populated the persistence context. Reload
        // after serialization so committed reference edits cannot hide in L1.
        em.clear();
        if (!Objects.equals(plan.goodsFingerprint(), identityFingerprint(goodsRepo.findImportIdentities()))) {
            throw stalePlan("货品资料在检测后发生了变化");
        }
        Map<UUID, Goods> lockedGoods = new HashMap<>();
        for (PlannedRow row : plan.rows()) {
            if (row.existingGoodsId() == null) continue;
            Goods goods = goodsRepo.findById(row.existingGoodsId())
                    .orElseThrow(() -> stalePlan("待合并货品已不存在"));
            em.refresh(goods);
            writeAccess.requireWritable(goods.getId());
            if (goods.isDeleted() || !Objects.equals(row.goodsFingerprint(), goodsFingerprint(goods))) {
                throw stalePlan("货品资料在检测后发生了变化");
            }
            lockedGoods.put(goods.getId(), goods);
        }
        // Restoring an old identity is also a merge. Read its complete baseline
        // under the same table lock; omitted workbook columns never mean clear.
        for (PlannedRow row : plan.rows()) {
            if (row.restoreGoodsId() == null) continue;
            goodsService.requireRestoreImportedWriteAccess(row.restoreGoodsId());
            Goods goods = goodsRepo.findById(row.restoreGoodsId())
                    .orElseThrow(() -> stalePlan("待恢复货品已不存在"));
            em.refresh(goods);
            if (!goods.isDeleted()) throw stalePlan("待恢复货品已恢复");
            lockedGoods.put(goods.getId(), goods);
        }
        MasterSnapshot currentMasters = loadMasterSnapshot();
        if (!MessageDigest.isEqual(
                plan.masterFingerprint().getBytes(StandardCharsets.US_ASCII),
                currentMasters.fingerprint().getBytes(StandardCharsets.US_ASCII))) {
            throw stalePlan("分类、颜色或单位资料在检测后发生了变化");
        }

        boolean hasWork = plan.rows().stream().anyMatch(row -> row.existingGoodsId() == null
                || row.changes().stream().anyMatch(change -> "FILL".equals(change.kind())
                        || replacements.contains(rowKey(row.rowNum()))));
        if (!hasWork) {
            int ignored = (int) plan.rows().stream().filter(row -> !row.changes().isEmpty()).count();
            return new GoodsImportResult(null, 0, 0, 0, 0, List.of(), 0, 0, 0, ignored,
                    plan.rows().size() - ignored, 0);
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
        int created = 0, restored = 0, updated = 0, merged = 0, filled = 0, ignored = 0, unchanged = 0;

        // Authorize the complete reviewed update set before materializing any category,
        // color or unit. New records still use the independent import capability.
        for (int authorizationIndex=0;authorizationIndex<plan.rows().size();authorizationIndex++) {
            PlannedRow planned=plan.rows().get(authorizationIndex);
            if(planned.existingGoodsId()!=null) {
                boolean replacing=replacements.contains(rowKey(planned.rowNum()));
                com.uten.imp.features.master.goods.GoodsFieldEditPolicy.requireFields(
                        planned.changes().stream().filter(change -> "FILL".equals(change.kind()) || replacing)
                                .map(GoodsImportReviewRow.Change::field).toList());
            } else if(planned.restoreGoodsId()!=null) {
                com.uten.imp.features.master.goods.GoodsFieldEditPolicy.requireFields(
                        changes(parsed.rows.get(authorizationIndex),lockedGoods.get(planned.restoreGoodsId()),
                                planned.category(),planned.color(),planned.unit()).stream()
                                .map(GoodsImportReviewRow.Change::field).toList());
            }
        }

        for (int rowIndex = 0; rowIndex < parsed.rows.size(); rowIndex++) {
            ParsedRow r = parsed.rows.get(rowIndex);
            PlannedRow planned = plan.rows().get(rowIndex);
            if (r.rowNum != planned.rowNum()) {
                throw stalePlan("导入文件行号已变化");
            }
            boolean replacing = replacements.contains(rowKey(r.rowNum));
            List<GoodsImportReviewRow.Change> applied = planned.changes().stream()
                    .filter(change -> "FILL".equals(change.kind()) || replacing).toList();
            boolean merging = planned.existingGoodsId() != null;
            if (merging && planned.changes().stream().anyMatch(change -> "CONFLICT".equals(change.kind()))
                    && !replacing) ignored++;
            if (merging && applied.isEmpty()) {
                if (planned.changes().isEmpty()) unchanged++;
                continue;
            }
            int[] catCnt = new int[1];
            UUID categoryId = !merging || hasChange(applied, "categoryId") ? materializeCategory(
                    planned.category(), categoryTokens, batchId, createdCatPaths, catCnt) : null;
            createdCats += catCnt[0];
            int[] colorCnt = new int[1];
            UUID colorId = !merging || hasChange(applied, "colorId") ? materializeColor(
                    planned.color(), colorTokens, batchId, colorCnt) : null;
            createdColors += colorCnt[0];
            int[] unitCnt = new int[1];
            UUID unitId = !merging || hasChange(applied, "unitId") ? materializeUnit(
                    planned.unit(), unitTokens, batchId, unitCnt) : null;
            createdUnits += unitCnt[0];

            if (merging) {
                Goods goods = lockedGoods.get(planned.existingGoodsId());
                GoodsSaveRequest request = mergeRequest(goods, r, applied, categoryId, colorId, unitId);
                goodsService.updateImported(goods.getId(), request);
                // The existing history trigger captures before/after for UPDATE;
                // creations is the legacy batch-to-history link, not a delete list.
                recordCreation(batchId, "GOODS", goods.getId());
                merged++;
                if (applied.stream().anyMatch(change -> "CONFLICT".equals(change.kind()))) updated++;
                if (applied.stream().anyMatch(change -> "FILL".equals(change.kind()))) filled++;
                continue;
            }
            if (planned.restoreGoodsId() != null) {
                Goods deleted = lockedGoods.get(planned.restoreGoodsId());
                List<GoodsImportReviewRow.Change> restoreChanges = changes(
                        r, deleted, planned.category(), planned.color(), planned.unit());
                GoodsSaveRequest request = mergeRequest(deleted, r, restoreChanges, categoryId, colorId, unitId);
                UUID goodsId = goodsService.restoreImported(deleted.getId(), request);
                recordCreation(batchId, "GOODS", goodsId);
                restored++;
                continue;
            }
            GoodsSaveRequest req = new GoodsSaveRequest();
            req.setCode(r.code);
            req.setName(r.name);
            if (r.clientGoodsNamePresent) req.setClientGoodsName(r.clientGoodsName);
            if (r.cNumberPresent) req.setCNumber(r.cNumber);
            req.setCategoryId(categoryId);
            req.setSeries(emptyToNull(r.series));
            req.setModel(emptyToNull(r.model));
            req.setSpec(emptyToNull(r.spec));
            req.setMaterial(emptyToNull(r.material));
            req.setRearInsertCode(emptyToNull(r.rearInsertCode));
            req.setPaper(emptyToNull(r.paper));
            if (r.nameEn != null) req.setNameEn(r.nameEn);
            req.setSourceType(emptyToNull(r.sourceType));
            if (r.price != null) req.setPrice(r.price);
            req.setMinOrderQty(r.minOrderQty);
            req.setOrderMultipleQty(r.orderMultipleQty);
            if (emptyToNull(r.status) != null) req.setStatus(emptyToNull(r.status));
            // Runtime relationships are UUID-only. legacy_id is never used to
            // resolve or write an imported goods relationship.
            if (colorId != null) req.setColorId(colorId);
            if (unitId != null) req.setUnitId(unitId);
            UUID goodsId = goodsService.saveImported(req);
            recordCreation(batchId, "GOODS", goodsId);
            created++;
        }

        em.flush();
        em.createNativeQuery("""
                UPDATE goods_import_batches SET row_count=:n, operation_id=(
                    SELECT h.id FROM goods_operation_history h
                    WHERE h.actor_id=:actor AND h.request_id=nullif(current_setting('app.audit_request_id',true),'')::uuid
                      AND h.transaction_id=txid_current() AND h.operation_type='GOODS_IMPORT')
                WHERE id=:id
                """)
                .setParameter("n", created + restored + merged)
                .setParameter("id", batchId)
                .setParameter("actor", actorId)
                .executeUpdate();

        return new GoodsImportResult(batchId, created + restored + merged,
                createdCats, createdColors, createdUnits, createdCatPaths,
                created, updated, filled, ignored, unchanged, restored);
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
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:import')")
    @Transactional(readOnly = true)
    public GoodsImportBatchInfo latestBatch() {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(
                "SELECT id, created_at, filename, row_count "
                        + "FROM goods_import_batches WHERE status='IMPORTED' AND created_by=:actor ORDER BY created_at DESC LIMIT 1")
                .setParameter("actor", currentActorId())
                .getResultList();
        if (rows.isEmpty()) return null;
        Object[] r = rows.get(0);
        return new GoodsImportBatchInfo(toUuid(r[0]), toOdt(r[1]), (String) r[2], ((Number) r[3]).intValue());
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:import:undo')")
    @Transactional
    public int undo(UUID batchId) {
        return operationHistory.undoImport(batchId);
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
                String rawGoodsId = trim(str(row, col.get("goodsId")));
                if (rawGoodsId != null && !rawGoodsId.isEmpty()) {
                    try {
                        pr.goodsId = UUID.fromString(rawGoodsId);
                    } catch (IllegalArgumentException invalidId) {
                        headerErrors.add(new GoodsImportError(pr.rowNum, "货品UUID", "货品 UUID 格式不正确"));
                    }
                }
                pr.code = code;
                pr.name = name;
                pr.clientGoodsNamePresent = col.containsKey("clientGoodsName");
                pr.clientGoodsName = trim(str(row, col.get("clientGoodsName")));
                pr.cNumberPresent = col.containsKey("cNumber");
                pr.cNumber = trim(str(row, col.get("cNumber")));
                pr.series = normKey(str(row, col.get("series")));
                pr.model = trim(str(row, col.get("model")));
                pr.spec = trim(str(row, col.get("spec")));
                pr.material = trim(str(row, col.get("material")));
                pr.rearInsertCode = trim(str(row, col.get("rearInsertCode")));
                pr.paper = trim(str(row, col.get("paper")));
                pr.nameEn = com.uten.imp.features.master.goods.GoodsNameEn.normalize(
                        str(row, col.get("nameEn")));
                pr.colorName = normKey(str(row, col.get("colorName")));
                pr.unitName = normKey(str(row, col.get("unitName")));
                pr.sourceType = normKey(str(row, col.get("sourceType")));
                pr.status = trim(str(row, col.get("status")));
                pr.price = parsePrice(numberText(row, col.get("price")), pr.rowNum, headerErrors);
                // 采购批量口径（V575）：负数按无效数字报错，不静默取绝对值。
                pr.minOrderQty = parseQty(
                        numberText(row, col.get("minOrderQty")), "最小起订量", pr.rowNum, headerErrors);
                pr.orderMultipleQty = parseQty(
                        numberText(row, col.get("orderMultipleQty")), "订货倍数", pr.rowNum, headerErrors);
                pr.categoryPath = str(row, col.get("categoryPath"));
                pr.categorySegments = splitCategory(pr.categoryPath);
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
            if ("clientGoodsName".equals(key) && col.containsKey(key)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户货品名称与客户品名只保留一列，避免来源冲突");
            }
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
        String cleaned = raw.trim();
        if (cleaned.matches("[￥¥$€£].*")) cleaned = cleaned.substring(1).trim();
        if (cleaned.matches("[+-]?\\d{1,3}(,\\d{3})+(\\.\\d+)?")) cleaned = cleaned.replace(",", "");
        try {
            BigDecimal value = new BigDecimal(cleaned);
            validateDecimal(value);
            return value;
        } catch (NumberFormatException e) {
            errors.add(new GoodsImportError(rowNum, "价格", "价格「" + raw + "」不是有效数字"));
            return null;
        }
    }

    /**
     * 采购批量数量列（最小起订量 / 订货倍数）：可空、非负。
     *
     * <p>与 {@link #parsePrice} 的区别：不剥非数字字符（起订量单元格不会带货币符号，
     * 真出现「500个」这种写法要让用户看见错误而不是被静默读成 500），负数直接报错。
     */
    private BigDecimal parseQty(String raw, String label, int rowNum,
                                List<GoodsImportError> errors) {
        if (raw == null || raw.isBlank()) return null;
        try {
            BigDecimal v = new BigDecimal(raw.trim());
            validateDecimal(v);
            if (v.signum() < 0) {
                errors.add(new GoodsImportError(rowNum, label, label + "「" + raw + "」不能为负数"));
                return null;
            }
            return v;
        } catch (NumberFormatException e) {
            errors.add(new GoodsImportError(rowNum, label, label + "「" + raw + "」不是有效数字"));
            return null;
        }
    }

    private static void validateDecimal(BigDecimal value) {
        BigDecimal normalized = value.stripTrailingZeros();
        if (normalized.scale() > 4 || normalized.precision() - normalized.scale() > 14) {
            throw new NumberFormatException("numeric(18,4) limit");
        }
    }

    private static String numberText(Row row, Integer column) {
        if (column == null) return null;
        Cell cell = row.getCell(column);
        if (cell == null) return null;
        var type = cell.getCellType() == org.apache.poi.ss.usermodel.CellType.FORMULA
                ? cell.getCachedFormulaResultType() : cell.getCellType();
        if (type == org.apache.poi.ss.usermodel.CellType.NUMERIC) {
            return cell instanceof org.apache.poi.xssf.usermodel.XSSFCell xssf
                    ? xssf.getRawValue() : BigDecimal.valueOf(cell.getNumericCellValue()).toPlainString();
        }
        return str(row, column);
    }

    private static <T> boolean legacyNameUnchanged(List<T> masters, Integer legacyId, String importedName,
                                                  java.util.function.Function<T, Integer> legacy,
                                                  java.util.function.Function<T, String> name,
                                                  java.util.function.Predicate<T> deleted) {
        return importedName != null && !importedName.isBlank() && masters.stream()
                .filter(master -> !deleted.test(master) && Objects.equals(legacyId, legacy.apply(master))
                        && Objects.equals(importedName, normKey(name.apply(master)))).count() == 1;
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
                              String goodsFingerprint,
                              UUID actorId,
                              List<PlannedRow> rows) {
        long estimatedBytes = estimatePlanBytes(rows);
        if (estimatedBytes > MAX_CACHED_PLAN_BYTES || rows.size() > MAX_CACHED_ROWS) {
            throw new ApiException(ErrorCode.PAYLOAD_TOO_LARGE, "导入差异内容过多，请拆分文件后重新检测");
        }
        synchronized (plans) {
            Instant now = Instant.now();
            plans.entrySet().removeIf(entry -> !entry.getValue().expiresAt().isAfter(now));
            while (!plans.isEmpty() && (plans.size() >= MAX_ACTIVE_PLANS
                    || plans.values().stream().mapToLong(ImportPlan::estimatedBytes).sum() + estimatedBytes > MAX_CACHED_PLAN_BYTES
                    || plans.values().stream().mapToInt(plan -> plan.rows().size()).sum() + rows.size() > MAX_CACHED_ROWS)) {
                plans.entrySet().stream().min(Comparator.comparing(entry -> entry.getValue().expiresAt()))
                        .ifPresent(entry -> plans.remove(entry.getKey(), entry.getValue()));
            }
            UUID id = UUID.randomUUID();
            plans.put(id, new ImportPlan(
                    id, actorId, workbookHash, masterFingerprint, goodsFingerprint,
                    List.copyOf(rows), now.plus(PLAN_TTL), estimatedBytes));
            return id;
        }
    }

    private static long estimatePlanBytes(List<PlannedRow> rows) {
        long bytes = 512;
        for (PlannedRow row : rows) {
            bytes += 512;
            if (row.category() != null) for (PlannedCategorySegment segment : row.category().segments()) {
                bytes += 128 + stringBytes(segment.name());
            }
            if (row.color() != null) bytes += 128 + stringBytes(row.color().name());
            if (row.unit() != null) bytes += 128 + stringBytes(row.unit().name());
            for (GoodsImportReviewRow.Change change : row.changes()) {
                bytes += 128 + stringBytes(change.field()) + stringBytes(change.label())
                        + stringBytes(change.oldValue()) + stringBytes(change.newValue());
            }
        }
        return bytes;
    }

    private static long stringBytes(Object value) {
        return value == null ? 0 : 64L + value.toString().length() * 2L;
    }

    private ImportPlan requireAndConsumePlan(UUID planId, byte[] workbook) {
        if (planId == null) {
            throw stalePlan("缺少检测计划");
        }
        ImportPlan plan = plans.remove(planId);
        if (plan == null) {
            throw stalePlan("检测计划不存在、已使用、已释放或服务已重启");
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

    private static String rowKey(int rowNum) { return "goods:" + rowNum; }

    private static UUID existingCategoryId(CategoryPathPlan category) {
        return category == null || category.segments().isEmpty()
                ? null : category.segments().getLast().existingId();
    }

    private static String categoryPath(MaterialCategory category) {
        var names = new java.util.ArrayDeque<String>();
        var seen = new HashSet<UUID>();
        while (category != null && seen.add(category.getId())) {
            names.addFirst(Objects.toString(category.getName(), ""));
            category = category.getParent();
        }
        return String.join("-", names);
    }

    private List<GoodsImportReviewRow.Change> changes(ParsedRow row, Goods old,
                                                     CategoryPathPlan category,
                                                     PlannedMasterReference color,
                                                     PlannedMasterReference unit) {
        List<GoodsImportReviewRow.Change> result = new ArrayList<>();
        change(result, "code", "编号", normCode(old.getCode()), row.code);
        change(result, "name", "货品名称", old.getName(), row.name);
        change(result, "clientGoodsName", "客户货品名称", old.getClientGoodsName(), row.clientGoodsName);
        change(result, "cNumber", "客户型号", old.getCNumber(), row.cNumber);
        change(result, "series", "系列", old.getSeries(), row.series);
        change(result, "model", "型号", old.getModel(), row.model);
        change(result, "spec", "规格", old.getSpec(), row.spec);
        change(result, "material", "材质", old.getMaterial(), row.material);
        change(result, "rearInsertCode", "后模镶件编号", old.getRearInsertCode(), row.rearInsertCode);
        change(result, "paper", "备注", old.getPaper(), row.paper);
        change(result, "nameEn", "英文名称", old.getNameEn(), row.nameEn);
        change(result, "sourceType", "来源", old.getSourceType(), row.sourceType);
        change(result, "status", "状态", old.getStatus(), row.status);
        if (row.price != null) {
            boolean mayViewPrice = currentUser.get().map(user -> user.isSuperAdmin()
                    || user.getPermissions().contains("goods:price:view")
                    || user.getPermissions().contains("goods:price:edit")).orElse(false);
            if (!mayViewPrice) {
                throw new ApiException(ErrorCode.FORBIDDEN, "检测已有货品的售价差异需要查看货品售价权限，请删除价格列后重传或申请权限");
            }
            change(result, "price", "价格", old.getPrice(), row.price);
        }
        change(result, "minOrderQty", "最小起订量", old.getMinOrderQty(), row.minOrderQty);
        if (!(old.getOrderMultipleQty() == null && row.orderMultipleQty != null
                && row.orderMultipleQty.signum() == 0)) {
            change(result, "orderMultipleQty", "订货倍数", old.getOrderMultipleQty(), row.orderMultipleQty);
        }
        UUID oldCategoryId = old.getCategory() == null ? null : old.getCategory().getId();
        if (category != null && (existingCategoryId(category) == null
                || !Objects.equals(oldCategoryId, existingCategoryId(category)))) {
            change(result, "categoryId", "类别", categoryPath(old.getCategory()), normKey(row.categoryPath));
        }
        UUID oldColorId = old.getColor() == null ? null : old.getColor().getId();
        if (color != null && (color.newToken() != null || !Objects.equals(oldColorId, color.existingId()))) {
            change(result, "colorId", "主颜色", old.getColor() == null ? null : old.getColor().getName(), color.name());
        }
        UUID oldUnitId = old.getUnit() == null ? null : old.getUnit().getId();
        if (unit != null && (unit.newToken() != null || !Objects.equals(oldUnitId, unit.existingId()))) {
            if (goodsRepo.quantityUnitInUse(old.getId())) {
                throw new ApiException(ErrorCode.CONFLICT, "第 " + row.rowNum + " 行货品已有数量记录或组装引用，不能通过导入修改或补选基本单位");
            }
            change(result, "unitId", "单位", old.getUnit() == null ? null : old.getUnit().getName(), unit.name());
        }
        return List.copyOf(result);
    }

    private static void change(List<GoodsImportReviewRow.Change> changes, String field, String label,
                               Object oldValue, Object incoming) {
        if (incoming == null || incoming instanceof String value && value.isBlank()) return;
        boolean oldEmpty = oldValue == null || oldValue instanceof String value && value.isBlank();
        boolean equal = oldValue instanceof BigDecimal oldNumber && incoming instanceof BigDecimal newNumber
                ? oldNumber.compareTo(newNumber) == 0
                : Objects.equals(oldValue instanceof String value ? value.trim() : oldValue, incoming);
        if (equal) return;
        changes.add(new GoodsImportReviewRow.Change(field, label, oldEmpty ? null : oldValue,
                incoming, oldEmpty ? "FILL" : "CONFLICT"));
    }

    private static boolean hasChange(List<GoodsImportReviewRow.Change> changes, String field) {
        return changes.stream().anyMatch(change -> field.equals(change.field()));
    }

    private static GoodsSaveRequest mergeRequest(Goods old, ParsedRow row,
                                                 List<GoodsImportReviewRow.Change> changes,
                                                 UUID categoryId, UUID colorId, UUID unitId) {
        GoodsSaveRequest request = new GoodsSaveRequest();
        // The normal save command is a full replacement DTO. Start with every
        // existing scalar so an import of two columns cannot erase other tabs.
        org.springframework.beans.BeanUtils.copyProperties(old, request,
                "unitLegacyId", "colorLegacyId", "mouldLegacyId", "clientLegacyId", "vendLegacyId", "vend2LegacyId",
                "thicknessUnitLegacyId", "mWeightUnitLegacyId", "MWeightUnitLegacyId",
                "nameEn", "cNumber", "CNumber", "clientGoodsName", "subcontractAllowedLossPct", "status");
        request.setCategoryId(old.getCategory() == null ? null : old.getCategory().getId());
        request.setVersion(old.getVersion());
        for (GoodsImportReviewRow.Change change : changes) {
            switch (change.field()) {
                case "code" -> request.setCode(row.code);
                case "name" -> request.setName(row.name);
                case "clientGoodsName" -> request.setClientGoodsName(row.clientGoodsName);
                case "cNumber" -> request.setCNumber(row.cNumber);
                case "series" -> request.setSeries(row.series);
                case "model" -> request.setModel(row.model);
                case "spec" -> request.setSpec(row.spec);
                case "material" -> request.setMaterial(row.material);
                case "rearInsertCode" -> request.setRearInsertCode(row.rearInsertCode);
                case "paper" -> request.setPaper(row.paper);
                case "nameEn" -> request.setNameEn(row.nameEn);
                case "sourceType" -> request.setSourceType(row.sourceType);
                case "status" -> request.setStatus(row.status);
                case "price" -> request.setPrice(row.price);
                case "minOrderQty" -> request.setMinOrderQty(row.minOrderQty);
                case "orderMultipleQty" -> request.setOrderMultipleQty(row.orderMultipleQty);
                case "categoryId" -> request.setCategoryId(categoryId);
                case "colorId" -> request.setColorId(colorId);
                case "unitId" -> request.setUnitId(unitId);
                default -> throw new IllegalStateException("Unsupported goods import field: " + change.field());
            }
        }
        return request;
    }

    private static String identityFingerprint(List<GoodsImportIdentity> goods) {
        return sha256(goods.stream().map(GoodsImportIdentity::toString).sorted()
                .collect(java.util.stream.Collectors.joining("\n")).getBytes(StandardCharsets.UTF_8));
    }

    private static String goodsFingerprint(Goods goods) {
        List<Object> values = java.util.Arrays.asList(goods.getId(), goods.getVersion(), goods.isDeleted(),
                goods.getOwnerEmployeeId(), goods.getCode(), goods.getName(), goods.getClientGoodsName(),
                goods.getCNumber(), goods.getSeries(), goods.getModel(), goods.getSpec(), goods.getMaterial(),
                goods.getRearInsertCode(), goods.getPaper(), goods.getNameEn(), goods.getSourceType(),
                goods.getStatus(), goods.getPrice(), goods.getMinOrderQty(), goods.getOrderMultipleQty(),
                goods.getCategory() == null ? null : goods.getCategory().getId(),
                goods.getColor() == null ? null : goods.getColor().getId(),
                goods.getUnit() == null ? null : goods.getUnit().getId());
        StringBuilder text = new StringBuilder();
        for (Object value : values) {
            String string = value == null ? "" : value.toString();
            text.append(string.length()).append(':').append(string);
        }
        return sha256(text.toString().getBytes(StandardCharsets.UTF_8));
    }

    // ============================================================
    // 分类树/扁平主档计划索引
    // ============================================================

    private static final class CategoryPlanIndex {
        final Map<String, List<UUID>> existingChildren = new HashMap<>();
        final Map<String, PlannedCategorySegment> plannedChildren = new HashMap<>();
        final Map<String, List<CategoryPathPlan>> existingPaths = new HashMap<>();

        CategoryPlanIndex(List<MaterialCategory> all) {
            Map<UUID, MaterialCategory> byId = new HashMap<>();
            for (MaterialCategory category : all) byId.put(category.getId(), category);
            for (MaterialCategory c : all) {
                UUID pid = c.getParent() == null ? null : c.getParent().getId();
                existingChildren.computeIfAbsent(
                                childKey(existingParent(pid), normKey(c.getName())),
                                ignored -> new ArrayList<>())
                        .add(c.getId());
                var chain = new java.util.ArrayDeque<PlannedCategorySegment>();
                var visited = new HashSet<UUID>();
                MaterialCategory current = c;
                while (current != null && visited.add(current.getId())) {
                    chain.addFirst(new PlannedCategorySegment(current.getId(), null, normKey(current.getName())));
                    current = current.getParent() == null ? null : byId.get(current.getParent().getId());
                }
                if (current == null) {
                    String path = chain.stream().map(PlannedCategorySegment::name)
                            .collect(java.util.stream.Collectors.joining("-"));
                    existingPaths.computeIfAbsent(path, ignored -> new ArrayList<>())
                            .add(new CategoryPathPlan(List.copyOf(chain)));
                }
            }
        }

        CategoryPathPlan plan(String rawPath, List<String> segments, Set<String> willCreate) {
            // Exported paths use '-' but names may contain it. Resolve the whole
            // path against authoritative UUID chains before interpreting separators.
            var matches = existingPaths.getOrDefault(normKey(rawPath), List.of());
            if (matches.size() > 1) return null;
            if (matches.size() == 1) return matches.getFirst();
            String parentRef = "ROOT";
            List<PlannedCategorySegment> result = new ArrayList<>();
            List<String> path = new ArrayList<>();
            String normalizedPath = normKey(rawPath);
            String longestExisting = existingPaths.keySet().stream()
                    .filter(existing -> normalizedPath.startsWith(existing + "-"))
                    .max(Comparator.comparingInt(String::length)).orElse(null);
            if (longestExisting != null) {
                var parents = existingPaths.get(longestExisting);
                if (parents.size() != 1) return null;
                result.addAll(parents.getFirst().segments());
                result.forEach(segment -> path.add(segment.name()));
                parentRef = existingParent(result.getLast().existingId());
                segments = java.util.Arrays.stream(normalizedPath.substring(longestExisting.length() + 1).split("-"))
                        .filter(segment -> !segment.isEmpty()).toList();
            }
            for (String name : segments) {
                path.add(name);
                String key = childKey(parentRef, name);
                List<UUID> childMatches = existingChildren.getOrDefault(key, List.of());
                if (childMatches.size() > 1) return null;
                PlannedCategorySegment segment;
                if (childMatches.size() == 1) {
                    segment = new PlannedCategorySegment(childMatches.get(0), null, name);
                    parentRef = existingParent(childMatches.get(0));
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
        UUID goodsId;
        String code;
        String name;
        String clientGoodsName;
        boolean clientGoodsNamePresent;
        String cNumber;
        boolean cNumberPresent;
        String series;
        String model;
        String spec;
        String material;
        String rearInsertCode;       // 后模镶件编号（V457）
        String paper;                // 备注（2026-09-25 导入导出格式对齐，落库）
        String nameEn;               // 英文名称(ADR-134), 来源记 MANUAL
        String colorName;
        String unitName;
        String sourceType;
        String status;
        BigDecimal price;
        BigDecimal minOrderQty;      // 最小起订量（V575）
        BigDecimal orderMultipleQty; // 订货倍数（V575）
        List<String> categorySegments;
        String categoryPath;
    }

    private record ImportPlan(
            UUID id,
            UUID actorId,
            String workbookHash,
            String masterFingerprint,
            String goodsFingerprint,
            List<PlannedRow> rows,
            Instant expiresAt,
            long estimatedBytes) {}

    private record PlannedRow(
            int rowNum,
            CategoryPathPlan category,
            PlannedMasterReference color,
            PlannedMasterReference unit,
            UUID restoreGoodsId,
            UUID existingGoodsId,
            String goodsFingerprint,
            List<GoodsImportReviewRow.Change> changes) {}

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
