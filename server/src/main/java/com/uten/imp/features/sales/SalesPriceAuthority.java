package com.uten.imp.features.sales;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

/**
 * 销售单据(报价单/订货单)共用的单价权威(ADR-134, 由原 SalesOrderService 抽出)。
 *
 * <ul>
 *   <li>单价只来自货品资料售价(新行, 批量 FOR SHARE 读取)、同一草稿已冻结的行价, 或财务核价
 *       设定的成交单价; 请求里的 price 只是页面预览, 与权威价不一致一律 409。销售从不改价。</li>
 *   <li>折扣是 0 < 折扣 <= 1 的 4 位倍率; 空/0 是「不打折」的旧写法, 保存时归一为 1。</li>
 *   <li>看不到价格的人(无 {@code sales_order:price:view})保存时, 按客户文件单价反推折扣:
 *       {@link #deriveDiscountFromClientPrice}, 取位只在 {@link MoneyPolicy#discountFromUnitPrice}。</li>
 * </ul>
 */
@Component
@RequiredArgsConstructor
public class SalesPriceAuthority {

    /** 由客户文件单价反推折扣时的合理区间下限(不含): 低于它多半是对应错了货品或币种。 */
    public static final BigDecimal PLAUSIBLE_DISCOUNT_FLOOR = new BigDecimal("0.3");

    /** 常见币种写法 → 统一代码(客户文件与币种资料名称两边都按它归一)。 */
    private static final Map<String, String> CURRENCY_ALIASES = currencyAliases();

    private final EntityManager em;

    /**
     * 一次批量读取货品当前售价并加共享锁, 避免保存事务内被并发调价撕裂。只返回启用(使用)且未删除的货品;
     * 售价可能为空(未维护), 返回的 Map 允许空值, 调用方据单据类型决定是否放行。
     */
    public Map<UUID, BigDecimal> loadMasterPrices(Collection<UUID> goodsIds) {
        if (goodsIds == null || goodsIds.isEmpty()) return Map.of();
        LinkedHashSet<UUID> ids = new LinkedHashSet<>();
        for (UUID id : goodsIds) {
            if (id != null) ids.add(id);
        }
        if (ids.isEmpty()) return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT goods.id, goods.price
                        FROM goods
                        WHERE goods.id IN (:ids)
                          AND COALESCE(goods.is_deleted, FALSE) = FALSE
                          AND goods.status = '使用'
                        ORDER BY goods.id
                        FOR SHARE
                        """)
                .setParameter("ids", List.copyOf(ids))
                .getResultList();
        Map<UUID, BigDecimal> result = new HashMap<>();
        for (Object[] row : rows) {
            result.put((UUID) row[0], (BigDecimal) row[1]);
        }
        return result;
    }

    /** 订货单新行必须有售价: 未维护 400, 负数 409。 */
    public static BigDecimal requireMasterPrice(UUID goodsId, BigDecimal price, String documentLabel) {
        if (price == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "货品未维护销售单价，无法创建" + documentLabel + "明细(" + goodsId + ")");
        }
        return requireNonNegativePrice(price);
    }

    /** 报价单允许售价为空(标记「待财务定价」), 但绝不接受负数售价。 */
    public static BigDecimal requireNonNegativePrice(BigDecimal price) {
        if (price != null && price.signum() < 0) {
            throw new ApiException(ErrorCode.CONFLICT, "货品销售单价为负数，禁止开单");
        }
        return price;
    }

    /**
     * 请求单价不是写入来源; 但页面带了预览值, 就必须与服务端权威价一致(阻止改包篡价, 也避免开单期间
     * 主档调价后静默保存成一个没核对过的新价格)。权威价为空(待财务定价)时页面也必须不带价格。
     */
    public static void requirePreviewMatches(BigDecimal preview, BigDecimal authoritative, String documentLabel) {
        if (preview == null) return;
        if (authoritative == null || preview.compareTo(authoritative) != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    documentLabel + "单价已变化或请求被修改，请刷新货品/来源单据后重新确认");
        }
    }

    /**
     * 新写折扣统一为四位倍率: 1=原价、0.9=9折。null/0 是旧客户端的「不打折」表达, 保存时归一为 1;
     * 已审核历史行仍由审核兼容公式把 null/0 解释为 1, 不批量改写历史。
     */
    public static BigDecimal normalizeDiscountForWrite(BigDecimal discount) {
        if (discount == null || discount.signum() == 0) {
            return BigDecimal.ONE.setScale(4);
        }
        return normalizeExplicitDiscount(discount);
    }

    /** 财务核价明确填写的折扣: 必须 0 < 折扣 <= 1 且最多 4 位小数, 空值不当作原价。 */
    public static BigDecimal normalizeExplicitDiscount(BigDecimal discount) {
        if (discount == null || discount.signum() <= 0 || discount.compareTo(BigDecimal.ONE) > 0) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "折扣须为大于 0 且不大于 1 的倍率(1=原价，0.9=9折)");
        }
        if (discount.stripTrailingZeros().scale() > 4) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "折扣最多四位小数(最小精度 0.0001，1=原价，0.9=9折)");
        }
        return discount.setScale(4);
    }

    /**
     * 客户文件单价(可空, 只作参考): 不能为负, 精度界限与单价相同(最多 10 位小数、14 位整数)。
     * 保存时就拦下, 免得解析文件带来的浮点尾数让核价页折算本币时超出精度而打不开。原值原样保存(不取位)。
     */
    public static BigDecimal requireClientPrice(BigDecimal clientPrice, String label) {
        if (clientPrice == null) return null;
        if (clientPrice.signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "不能为负数");
        }
        FinancialExactAmount.unitPrice(clientPrice, label);
        return clientPrice;
    }

    /** 由文件单价反推的折扣是否落在合理区间 (0.3, 1]。 */
    public static boolean plausibleDiscount(BigDecimal discount) {
        return discount != null
                && discount.compareTo(PLAUSIBLE_DISCOUNT_FLOOR) > 0
                && discount.compareTo(BigDecimal.ONE) <= 0;
    }

    /**
     * 按客户文件单价反推折扣(ADR-134 §5.7 同一口径, 单据按本位币计价):
     * 文件币种是本位币或未知 → 只看 文件单价 ÷ 标价; 外币 → 分别看「按美元标价」(汇率 1) 与
     * 「按财务汇率折算」两种比值, 恰好一种落在 (0.3, 1] 才采用; 两种都合理或都不合理 → 空(推算不出)。
     * 汇率只读财务在币种资料里维护的参考汇率, 销售从不输入汇率。文件币种由调用方每次保存只解析一次
     * ({@link #resolveFileCurrency}), 这里不再查库。
     */
    public static Optional<BigDecimal> deriveDiscountFromClientPrice(
            BigDecimal clientPrice, FileCurrency currency, BigDecimal listPrice) {
        if (clientPrice == null || clientPrice.signum() <= 0 || listPrice == null || listPrice.signum() <= 0) {
            return Optional.empty();
        }
        BigDecimal plain = plausibleOrNull(MoneyPolicy.discountFromUnitPrice(clientPrice, BigDecimal.ONE, listPrice));
        if (currency == null || currency.base()) {
            return Optional.ofNullable(plain);
        }
        BigDecimal rate = currency.financeRate();
        if (rate == null || rate.signum() <= 0) {
            return Optional.ofNullable(plain);
        }
        BigDecimal converted = plausibleOrNull(MoneyPolicy.discountFromUnitPrice(clientPrice, rate, listPrice));
        if (plain != null && converted == null) return Optional.of(plain);
        if (plain == null && converted != null) return Optional.of(converted);
        return Optional.empty();
    }

    /**
     * 客户文件币种 → 是否本位币 + 财务参考汇率。按常见写法(USD/US$/美元/美金、CNY/RMB/人民币…)与币种资料的
     * 编号或名称对应; 对不上的一律当作「未知外币、没有汇率」。
     */
    public FileCurrency resolveFileCurrency(String fileCurrency) {
        String canonical = canonicalCurrency(fileCurrency);
        if (canonical == null) {
            return new FileCurrency(null, true, BigDecimal.ONE);
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT code, name, exchange_rate, is_base_currency
                        FROM currencies
                        WHERE COALESCE(is_deleted, FALSE) = FALSE
                          AND status = '使用'
                        ORDER BY is_base_currency DESC, code
                        """)
                .getResultList();
        for (Object[] row : rows) {
            String code = canonicalCurrency((String) row[0]);
            String name = canonicalCurrency((String) row[1]);
            if (canonical.equals(code) || canonical.equals(name)) {
                boolean base = Boolean.TRUE.equals(row[3]);
                BigDecimal rate = base ? BigDecimal.ONE : (BigDecimal) row[2];
                return new FileCurrency(canonical, base, rate);
            }
        }
        // 币种资料里没有这个币种: 人民币写法仍按本位币处理(本位币就是人民币时), 其它当未知外币。
        boolean baseIsCny = rows.stream().anyMatch(row -> Boolean.TRUE.equals(row[3])
                && ("CNY".equals(canonicalCurrency((String) row[0]))
                || "CNY".equals(canonicalCurrency((String) row[1]))));
        return new FileCurrency(canonical, "CNY".equals(canonical) && baseIsCny, null);
    }

    /** 统一币种写法; 认不出的原样大写返回(最多 8 个字符), 空白返回 null。 */
    public static String canonicalCurrency(String raw) {
        if (raw == null) return null;
        String value = raw.strip();
        if (value.isEmpty()) return null;
        String upper = value.toUpperCase(Locale.ROOT);
        String alias = CURRENCY_ALIASES.get(upper);
        if (alias != null) return alias;
        alias = CURRENCY_ALIASES.get(value);
        if (alias != null) return alias;
        return upper.length() > 8 ? upper.substring(0, 8) : upper;
    }

    /** 客户文件币种解析结果: code 为统一代码(空 = 未写币种, 按本位币); financeRate 为财务参考汇率(可空)。 */
    public record FileCurrency(String code, boolean base, BigDecimal financeRate) {
    }

    private static BigDecimal plausibleOrNull(MoneyPolicy.DiscountQuote quote) {
        return quote != null && plausibleDiscount(quote.discount()) ? quote.discount() : null;
    }

    private static Map<String, String> currencyAliases() {
        Map<String, String> aliases = new HashMap<>();
        for (String value : List.of("CNY", "RMB", "人民币", "¥", "￥", "元", "RMB¥")) aliases.put(value, "CNY");
        for (String value : List.of("USD", "US$", "$", "美元", "美金", "US DOLLAR", "US DOLLARS")) aliases.put(value, "USD");
        for (String value : List.of("EUR", "€", "欧元")) aliases.put(value, "EUR");
        for (String value : List.of("HKD", "HK$", "港币", "港元")) aliases.put(value, "HKD");
        for (String value : List.of("JPY", "日元")) aliases.put(value, "JPY");
        for (String value : List.of("GBP", "£", "英镑")) aliases.put(value, "GBP");
        return Map.copyOf(aliases);
    }

    /**
     * 同一张草稿里既有明细的配对簿: 先按行 UUID 精确配对(且商业身份不变), 再按商业身份队列兜底(旧客户端
     * 不带行 UUID)。每条既有行只能被配对一次。身份是「货品 + 颜色 + 单位 + 换算率」。
     *
     * @param <T> 已保存的明细实体
     * @param <L> 保存请求里的明细行
     */
    public static final class ExistingPriceBook<T, L> {
        private final Map<UUID, T> byId = new HashMap<>();
        private final Map<List<Object>, ArrayDeque<T>> byIdentity = new HashMap<>();
        private final Set<UUID> consumed = new HashSet<>();
        private final Function<T, UUID> storedId;
        private final Function<T, List<Object>> storedIdentity;
        private final Function<L, UUID> lineId;
        private final Function<L, List<Object>> lineIdentity;

        public ExistingPriceBook(
                List<T> stored,
                Function<T, UUID> storedId,
                Function<T, List<Object>> storedIdentity,
                Function<L, UUID> lineId,
                Function<L, List<Object>> lineIdentity) {
            this.storedId = storedId;
            this.storedIdentity = storedIdentity;
            this.lineId = lineId;
            this.lineIdentity = lineIdentity;
            if (stored == null) return;
            for (T item : stored) {
                byId.put(storedId.apply(item), item);
                byIdentity.computeIfAbsent(storedIdentity.apply(item), ignored -> new ArrayDeque<>())
                        .addLast(item);
            }
        }

        /** 配对并消费一条既有行; 没有配对返回 null。 */
        public T take(L line) {
            if (line == null) return null;
            UUID requestedId = lineId.apply(line);
            if (requestedId != null) {
                T exact = byId.get(requestedId);
                if (exact == null
                        || !storedIdentity.apply(exact).equals(lineIdentity.apply(line))
                        || !consumed.add(storedId.apply(exact))) {
                    return null;
                }
                return exact;
            }
            ArrayDeque<T> candidates = byIdentity.get(lineIdentity.apply(line));
            while (candidates != null && !candidates.isEmpty()) {
                T candidate = candidates.removeFirst();
                if (consumed.add(storedId.apply(candidate))) return candidate;
            }
            return null;
        }

        /** 没被任何请求行配对上的既有行(保存时要删除)。 */
        public List<T> unconsumed(List<T> stored) {
            List<T> left = new ArrayList<>();
            if (stored == null) return left;
            for (T item : stored) {
                if (!consumed.contains(storedId.apply(item))) left.add(item);
            }
            return left;
        }
    }

    /** 商业身份键: 货品 + 颜色 + 单位 + 换算率(去掉末尾 0, 允许空值)。 */
    public static List<Object> identity(UUID goodsId, UUID colorId, UUID unitId, BigDecimal unitRate) {
        return Arrays.asList(goodsId, colorId, unitId, unitRate == null ? null : unitRate.stripTrailingZeros());
    }
}
