package com.uten.imp.features.sales.intake;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 识别流程的销售侧数据: 读币种、学习到的版式、同一文件是否已被用过, 以及保存后写入学习到的版式。
 * 实现是 {@link SalesIntakeStore}(每个方法一个短事务); 单元测试用内存假实现。
 */
interface IntakeReferenceData {

    /** 启用中的币种(很小的表, 一次读完)。 */
    List<CurrencyRow> currencies();

    /**
     * 按指纹找学习到的版式。已选客户: 该客户自己的 + 全局的(依次排列); 没选客户: 全局的 + 各客户专属的(依次排列)。
     * 能不能先于规则使用由流水线判断: 别的客户的专属版式只在规则认不出、且同指纹只学到过一种列角色时兜底。
     */
    List<LearnedLayout> layouts(Collection<String> fingerprints, UUID clientIdOrNull);

    /** 同一文件(SHA-256)以前识别后被保存进了哪些单据: 单据 id → 单据类型(quote/order)。 */
    Map<UUID, String> docsUsingSameFile(String sha256, UUID excludeJobId);

    /**
     * 保存后学习版式(版式来自规则或 AI; 独立事务, 单据提交之后调用): 客户专属一行(列角色没变确认次数加 1, 变了从 1
     * 重新数), 再按各客户的证据重算全局一行(列角色 = 最多客户确认过的那种, 确认次数 = 不同客户数)。没有客户不写。
     *
     * @param columnRoles     列字母 → 角色名(只接受合法字母与已知角色)
     * @param headerRowOffset 表头占用的额外行数(单行表头为 0)
     */
    void upsertLayout(String fingerprint, UUID clientId, String headerTexts, Map<String, String> columnRoles,
                      int headerRowOffset);

    /** 保存时用的就是学习到的版式: 只刷新最近使用时间, 不加确认次数(自己确认自己不算新证据)。 */
    void touchLayout(String fingerprint, UUID clientId);

    /** 币种。 */
    record CurrencyRow(UUID id, String code, String name, BigDecimal exchangeRate, boolean base) {
    }

    /** 学习到的版式。 */
    record LearnedLayout(String fingerprint, UUID clientId, Map<String, String> columnRoles, int headerRowOffset,
                         int confirmCount) {
    }

    /** 常见币种写法(ISO → 名称里可能出现的字样), 用于把文件币种对到币种资料。 */
    Map<String, Set<String>> CURRENCY_ALIASES = Map.of(
            "USD", Set.of("USD", "US$", "美元", "美金"),
            "CNY", Set.of("CNY", "RMB", "人民币"),
            "EUR", Set.of("EUR", "欧元"),
            "HKD", Set.of("HKD", "HK$", "港币", "港元"),
            "GBP", Set.of("GBP", "英镑"),
            "JPY", Set.of("JPY", "日元"));

    /** ISO 代码的中文名(提示文字用)。 */
    Map<String, String> CURRENCY_LABELS = Map.of("USD", "美元", "CNY", "人民币", "EUR", "欧元", "HKD", "港币",
            "GBP", "英镑", "JPY", "日元");
}
