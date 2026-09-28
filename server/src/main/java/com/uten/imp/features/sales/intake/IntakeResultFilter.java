package com.uten.imp.features.sales.intake;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 按读者的价格权限过滤识别结果(SPEC §5.1 filterResultForReader)。纯函数, 不修改入参。
 *
 * <p>没有价格查看权限(sales_order:price:view 或 goods:price:view)的读者: 候选里的标价、折扣、折算率、定价状态与说明
 * 全部去掉, 会透露标价的理由(「单价与标价一致」「折扣异常」)也去掉, 财务参考汇率置空, summary.priceMasked=true。
 * 客户文件里本来就有的单价/金额(customerUnitPrice/customerAmount)是读者自己上传的, 保留。
 * 候选的 orderBlocked(订货单不能直接导入: 没有标价或客户价高于标价)不是价格本身, 也保留, 订货页据此不勾选并提示改做报价单。
 *
 * <p>没有新建客户权限(client:create)的读者: 去掉「用文件信息新建客户」的提议(client.newClientProposal), 界面就不给这个按钮,
 * 免得点了确认才被拒绝。
 */
final class IntakeResultFilter {

    static final Set<String> PRICE_KEYS = Set.of("listPrice", "discount", "rateUsed", "pricingFlag", "pricingNote",
            "impliedRatio");
    static final Set<String> PRICE_REASONS = Set.of("单价与标价一致", "折扣异常");

    private IntakeResultFilter() {
    }

    static Map<String, Object> filter(Map<String, Object> result, boolean canViewPrices, boolean canCreateClients) {
        Map<String, Object> out = filter(result, canViewPrices);
        if (out == null || canCreateClients || !(out.get("client") instanceof Map<?, ?> client)
                || client.get("newClientProposal") == null) {
            return out;
        }
        Map<String, Object> copy = new LinkedHashMap<>(out);
        Map<String, Object> clientCopy = new LinkedHashMap<>();
        client.forEach((k, v) -> clientCopy.put(String.valueOf(k), v));
        clientCopy.put("newClientProposal", null);
        copy.put("client", clientCopy);
        return copy;
    }

    static Map<String, Object> filter(Map<String, Object> result, boolean canViewPrices) {
        if (result == null || canViewPrices) {
            return result;
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> copy = (Map<String, Object>) mask(result, null);
        if (copy.get("summary") instanceof Map<?, ?> summary) {
            @SuppressWarnings("unchecked")
            Map<String, Object> s = (Map<String, Object>) summary;
            s.put("priceMasked", true);
        }
        if (copy.get("currency") instanceof Map<?, ?> currency) {
            @SuppressWarnings("unchecked")
            Map<String, Object> c = (Map<String, Object>) currency;
            c.put("financeRate", null);
        }
        return copy;
    }

    /** 深拷贝并去掉价格字段。 */
    private static Object mask(Object value, String key) {
        if (value instanceof Map<?, ?> map) {
            Map<String, Object> out = new LinkedHashMap<>();
            for (Map.Entry<?, ?> e : map.entrySet()) {
                String k = String.valueOf(e.getKey());
                if (PRICE_KEYS.contains(k) || k.startsWith("discount")) {
                    continue;
                }
                out.put(k, mask(e.getValue(), k));
            }
            return out;
        }
        if (value instanceof List<?> list) {
            List<Object> out = new ArrayList<>(list.size());
            for (Object item : list) {
                if ("reasons".equals(key) && item instanceof String s && PRICE_REASONS.contains(s)) {
                    continue;
                }
                out.add(mask(item, key));
            }
            return out;
        }
        return value;
    }
}
