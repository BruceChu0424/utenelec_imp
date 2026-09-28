package com.uten.imp.features.sales.intake;

import com.uten.imp.common.text.IntakeTextNormalizer;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * 文件里的国家名 → 客户资料「国家/地区」(clients.place_id) 的常见写法。place_id 是自由文本, 同一国家可能有几种写法
 * (「沙特」「沙特阿拉伯」), 这里给出全部候选, 由查询按任一相等召回。只用于召回候选客户(打 55 分, 只能待核对)。
 */
final class IntakeCountries {

    private record Country(String label, List<String> placeIds, Pattern pattern) {
    }

    private static final List<Country> COUNTRIES;

    static {
        Map<String, List<String>> names = new LinkedHashMap<>();
        Map<String, List<String>> places = new LinkedHashMap<>();
        add(names, places, "约旦", List.of("JORDAN", "HASHEMITE KINGDOM", "AMMAN", "IRBID", "ZARQA"), "约旦");
        add(names, places, "尼日利亚", List.of("NIGERIA", "LAGOS", "ABUJA", "KANO", "ONITSHA"), "尼日利亚");
        add(names, places, "伊拉克", List.of("IRAQ", "BAGHDAD", "ERBIL", "BASRA", "MOSUL", "SULAYMANIYAH"), "伊拉克");
        add(names, places, "沙特", List.of("SAUDI ARABIA", "SAUDI", "KSA", "RIYADH", "JEDDAH", "DAMMAM"), "沙特", "沙特阿拉伯");
        add(names, places, "马来西亚", List.of("MALAYSIA", "KUALA LUMPUR"), "马来西亚");
        add(names, places, "俄罗斯", List.of("RUSSIA", "RUSSIAN FEDERATION", "MOSCOW"), "俄罗斯");
        add(names, places, "乌兹别克斯坦", List.of("UZBEKISTAN", "TASHKENT"), "乌兹别克斯坦", "乌兹别克");
        add(names, places, "越南", List.of("VIETNAM", "VIET NAM", "HANOI", "HO CHI MINH"), "越南");
        add(names, places, "哈萨克斯坦", List.of("KAZAKHSTAN", "ALMATY", "ASTANA"), "哈萨克斯坦", "哈萨克");
        add(names, places, "巴林", List.of("BAHRAIN", "MANAMA"), "巴林");
        add(names, places, "孟加拉", List.of("BANGLADESH", "DHAKA", "CHITTAGONG"), "孟加拉", "孟加拉国");
        add(names, places, "巴基斯坦", List.of("PAKISTAN", "KARACHI", "LAHORE", "ISLAMABAD"), "巴基斯坦", "巴基");
        add(names, places, "土耳其", List.of("TURKEY", "TURKIYE", "ISTANBUL", "ANKARA"), "土耳其");
        add(names, places, "埃及", List.of("EGYPT", "CAIRO", "ALEXANDRIA"), "埃及");
        add(names, places, "智利", List.of("CHILE", "SANTIAGO"), "智利");
        add(names, places, "西班牙", List.of("SPAIN", "MADRID", "BARCELONA"), "西班牙");
        add(names, places, "乌克兰", List.of("UKRAINE", "KYIV", "KIEV"), "乌克兰");
        add(names, places, "亚美尼亚", List.of("ARMENIA", "YEREVAN"), "亚美尼亚", "亚美尼");
        add(names, places, "叙利亚", List.of("SYRIA", "DAMASCUS", "ALEPPO"), "叙利亚");
        add(names, places, "墨西哥", List.of("MEXICO"), "墨西哥");
        add(names, places, "阿曼", List.of("OMAN", "MUSCAT"), "阿曼");
        add(names, places, "科威特", List.of("KUWAIT"), "科威特");
        add(names, places, "阿联酋", List.of("UNITED ARAB EMIRATES", "UAE", "U.A.E", "DUBAI", "SHARJAH", "ABU DHABI"), "阿联酋",
                "迪拜");
        add(names, places, "卡塔尔", List.of("QATAR", "DOHA"), "卡塔尔");
        add(names, places, "黎巴嫩", List.of("LEBANON", "BEIRUT"), "黎巴嫩");
        add(names, places, "也门", List.of("YEMEN", "SANAA", "ADEN"), "也门");
        add(names, places, "利比亚", List.of("LIBYA", "TRIPOLI", "BENGHAZI"), "利比亚");
        add(names, places, "阿尔及利亚", List.of("ALGERIA", "ALGIERS"), "阿尔及利亚");
        add(names, places, "摩洛哥", List.of("MOROCCO", "CASABLANCA"), "摩洛哥");
        add(names, places, "肯尼亚", List.of("KENYA", "NAIROBI", "MOMBASA"), "肯尼亚");
        add(names, places, "加纳", List.of("GHANA", "ACCRA"), "加纳");
        add(names, places, "埃塞俄比亚", List.of("ETHIOPIA", "ADDIS ABABA"), "埃塞俄比亚");
        add(names, places, "坦桑尼亚", List.of("TANZANIA", "DAR ES SALAAM"), "坦桑尼亚");
        add(names, places, "南非", List.of("SOUTH AFRICA", "JOHANNESBURG"), "南非");
        add(names, places, "伊朗", List.of("IRAN", "TEHRAN"), "伊朗");
        add(names, places, "阿富汗", List.of("AFGHANISTAN", "KABUL"), "阿富汗");
        add(names, places, "印度尼西亚", List.of("INDONESIA", "JAKARTA"), "印度尼西亚", "印尼");
        add(names, places, "菲律宾", List.of("PHILIPPINES", "MANILA"), "菲律宾");
        add(names, places, "泰国", List.of("THAILAND", "BANGKOK"), "泰国");
        add(names, places, "印度", List.of("INDIA", "MUMBAI", "NEW DELHI"), "印度");
        add(names, places, "斯里兰卡", List.of("SRI LANKA", "COLOMBO"), "斯里兰卡");
        add(names, places, "缅甸", List.of("MYANMAR", "YANGON"), "缅甸");
        add(names, places, "柬埔寨", List.of("CAMBODIA", "PHNOM PENH"), "柬埔寨");
        add(names, places, "蒙古", List.of("MONGOLIA", "ULAANBAATAR"), "蒙古", "外蒙古国");
        add(names, places, "荷兰", List.of("NETHERLANDS", "HOLLAND", "AMSTERDAM"), "荷兰");
        add(names, places, "巴拿马", List.of("PANAMA"), "巴拿马", "马拿马");
        add(names, places, "巴西", List.of("BRAZIL"), "巴西");
        add(names, places, "秘鲁", List.of("PERU", "LIMA"), "秘鲁");
        add(names, places, "哥伦比亚", List.of("COLOMBIA", "BOGOTA"), "哥伦比亚");
        add(names, places, "阿根廷", List.of("ARGENTINA", "BUENOS AIRES"), "阿根廷");
        List<Country> list = new java.util.ArrayList<>();
        for (Map.Entry<String, List<String>> e : names.entrySet()) {
            String alternation = String.join("|", e.getValue().stream().map(Pattern::quote).toList());
            list.add(new Country(e.getKey(), places.get(e.getKey()),
                    Pattern.compile("(?<![A-Z])(" + alternation + ")(?![A-Z])")));
        }
        COUNTRIES = List.copyOf(list);
    }

    private IntakeCountries() {
    }

    private static void add(Map<String, List<String>> names, Map<String, List<String>> places, String label,
                            List<String> englishNames, String... placeIds) {
        names.put(label, englishNames);
        places.put(label, List.of(placeIds));
    }

    /** 文字里出现的国家(取第一个); 返回主写法(如「约旦」), 没有返回 null。 */
    static String detect(String text) {
        if (text == null || text.isBlank()) {
            return null;
        }
        String upper = IntakeTextNormalizer.nfkc(text).toUpperCase(Locale.ROOT);
        int bestIndex = Integer.MAX_VALUE;
        String best = null;
        for (Country c : COUNTRIES) {
            var m = c.pattern().matcher(upper);
            if (m.find() && m.start() < bestIndex) {
                bestIndex = m.start();
                best = c.label();
            }
            for (String place : c.placeIds()) {
                int i = upper.indexOf(place);
                if (i >= 0 && i < bestIndex) {
                    bestIndex = i;
                    best = c.label();
                }
            }
        }
        return best;
    }

    /** 某国家主写法对应的全部 place_id 写法。 */
    static Set<String> placeIds(String label) {
        if (label == null) {
            return Set.of();
        }
        for (Country c : COUNTRIES) {
            if (c.label().equals(label)) {
                return new LinkedHashSet<>(c.placeIds());
            }
        }
        return Set.of(label);
    }

    /** AI 返回的国家(英文或中文) → 主写法; 不认识返回 null。 */
    static String normalize(String aiCountry) {
        return detect(aiCountry);
    }
}
