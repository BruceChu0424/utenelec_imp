package com.uten.imp.features.sales.intake;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 文件表头信息(买方、联系人、单号、日期、贸易条款、付款方式…)。可变, 先由规则填, 再由 AI 只补空白项。
 */
final class IntakeHeader {

    String buyerName;
    String buyerAddress;
    String contactName;
    final List<String> emails = new ArrayList<>();
    final List<String> phones = new ArrayList<>();
    String taxId;
    String website;
    String docNo;
    String docDate;
    String incoterm;
    String port;
    String paymentTerms;
    /** 买方所在国家(客户资料「国家/地区」主写法, 如「约旦」)。 */
    String country;
    /** 表头来源: RULES / RULES+AI / AI。 */
    String source = "RULES";

    /** 备注建议: 「EXW; T/T 30% deposit, 70% before shipment」。 */
    String remarkSuggestion() {
        List<String> parts = new ArrayList<>();
        if (incoterm != null) {
            parts.add(port == null ? incoterm : incoterm + " " + port);
        } else if (port != null) {
            parts.add(port);
        }
        if (paymentTerms != null) {
            parts.add(paymentTerms);
        }
        return parts.isEmpty() ? null : String.join("; ", parts);
    }

    void addEmail(String email) {
        String e = email == null ? null : email.strip().toLowerCase(java.util.Locale.ROOT);
        if (e != null && !e.isEmpty() && !emails.contains(e) && emails.size() < 5) {
            emails.add(e);
        }
    }

    void addPhone(String phone) {
        String p = phone == null ? null : phone.strip();
        if (p == null || p.isEmpty() || phones.size() >= 5) {
            return;
        }
        String digits = p.replaceAll("\\D", "");
        for (String existing : phones) {
            if (existing.replaceAll("\\D", "").equals(digits)) {
                return;
            }
        }
        phones.add(p);
    }

    /** 结果 header 对象(§5.9)。 */
    Map<String, Object> toResult() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("buyerName", buyerName);
        out.put("buyerAddress", buyerAddress);
        out.put("contactName", contactName);
        out.put("emails", List.copyOf(emails));
        out.put("phones", List.copyOf(phones));
        out.put("taxId", taxId);
        out.put("website", website);
        out.put("docNo", docNo);
        out.put("docDate", docDate);
        out.put("incoterm", incoterm);
        out.put("port", port);
        out.put("paymentTerms", paymentTerms);
        out.put("remarkSuggestion", remarkSuggestion());
        out.put("country", country);
        return out;
    }
}
