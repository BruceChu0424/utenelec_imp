package com.uten.imp.features.finance.gl;

import java.util.*;

/** One row/rollup contract for statements, settings, filtering and exports. */
final class FinancialStatementCatalog {
    private FinancialStatementCatalog() {}
    record Line(String key, int number, String label, String sheet, String category,
                int sign, List<Integer> terms, List<Integer> details, List<String> roots) {
        boolean direct() { return category != null; }
        String side() { return number <= 30 ? "资产" : "负债和所有者权益"; }
    }
    private static Line bs(int n,String label,String category,String... roots) {
        return new Line("BS_"+n,n,label,"BALANCE",category,
                n==19 || Set.of("LIABILITY","EQUITY").contains(category) ? -1:1,
                List.of(),n==9?List.of(10,11,12,13):List.of(),List.of(roots));
    }
    private static Line total(String sheet,int n,String label,Integer... terms) {
        return new Line((sheet.equals("BALANCE")?"BS_":"PL_")+n,n,label,sheet,null,1,List.of(terms),List.of(),List.of());
    }
    private static Line pl(int n,String key,String label,String category,List<Integer> details,String... roots) {
        return new Line(key,n,label,"PROFIT",category,category.equals("INCOME")?-1:1,List.of(),details,List.of(roots));
    }
    static final List<Line> BALANCE=List.of(
        bs(1,"货币资金","ACCOUNT","CASH","BANK"),bs(2,"短期投资","ACCOUNT"),
        bs(3,"应收票据","ACCOUNT"),bs(4,"应收账款","ACCOUNT","RECEIVABLES"),
        bs(5,"预付账款","ACCOUNT"),bs(6,"应收股利","ACCOUNT"),bs(7,"应收利息","ACCOUNT"),
        bs(8,"其他应收款","ACCOUNT","OTHER_RECEIVABLES","OTHER_RECEIVABLES_ALTERNATE"),
        bs(9,"存货","ACCOUNT","INVENTORY"),bs(10,"其中：原材料","ACCOUNT"),
        bs(11,"在产品","ACCOUNT"),bs(12,"库存商品","ACCOUNT"),bs(13,"周转材料","ACCOUNT"),
        bs(14,"其他流动资产","ACCOUNT","PREPAID"),total("BALANCE",15,"流动资产合计",1,2,3,4,5,6,7,8,9,14),
        bs(16,"长期债券投资","ACCOUNT"),bs(17,"长期股权投资","ACCOUNT"),
        bs(18,"固定资产原价","ACCOUNT","FIXED_ASSETS"),bs(19,"减：累计折旧","ACCOUNT","ACCUMULATED_DEPRECIATION"),
        total("BALANCE",20,"固定资产账面价值",18,-19),bs(21,"在建工程","ACCOUNT"),
        bs(22,"工程物资","ACCOUNT"),bs(23,"固定资产清理","ACCOUNT"),bs(24,"生产性生物资产","ACCOUNT"),
        bs(25,"无形资产","ACCOUNT"),bs(26,"开发支出","ACCOUNT"),bs(27,"长期待摊费用","ACCOUNT"),
        bs(28,"其他非流动资产","ACCOUNT"),total("BALANCE",29,"非流动资产合计",16,17,20,21,22,23,24,25,26,27,28),
        total("BALANCE",30,"资产总计",15,29),bs(31,"短期借款","LIABILITY"),bs(32,"应付票据","LIABILITY"),
        bs(33,"应付账款","LIABILITY","PAYABLES"),bs(34,"预收账款","LIABILITY"),
        bs(35,"应付职工薪酬","LIABILITY"),bs(36,"应交税费","LIABILITY","TAX_PAYABLE"),
        bs(37,"应付利息","LIABILITY"),bs(38,"应付利润","LIABILITY"),
        bs(39,"其他应付款","LIABILITY","OTHER_PAYABLES","OTHER_PAYABLES_ALTERNATE"),
        bs(40,"其他流动负债","LIABILITY"),total("BALANCE",41,"流动负债合计",31,32,33,34,35,36,37,38,39,40),
        bs(42,"长期借款","LIABILITY"),bs(43,"长期应付款","LIABILITY"),bs(44,"递延收益","LIABILITY"),
        bs(45,"其他非流动负债","LIABILITY"),total("BALANCE",46,"非流动负债合计",42,43,44,45),
        total("BALANCE",47,"负债合计",41,46),bs(48,"实收资本（或股本）","EQUITY","CAPITAL"),
        bs(49,"资本公积","EQUITY"),bs(50,"盈余公积","EQUITY"),bs(51,"未分配利润","EQUITY","RETAINED_PROFIT"),
        total("BALANCE",52,"所有者权益（或股东权益）合计",48,49,50,51),
        total("BALANCE",53,"负债和所有者权益（或股东权益）总计",47,52));
    static final List<Line> PROFIT=List.of(
        pl(1,"PL_1","一、营业收入","INCOME",List.of(),"MAIN_REVENUE","OTHER_REVENUE"),
        pl(2,"PL_2","减：营业成本","EXPENSE",List.of(),"MAIN_COST","OTHER_COST"),
        pl(3,"PL_TAX","营业税金及附加","EXPENSE",List.of()),
        pl(11,"SALES_FEE","销售费用","EXPENSE",List.of()),
        pl(14,"PL_14","管理费用","EXPENSE",List.of(),"ADMIN_EXPENSE"),
        pl(18,"PL_FINANCE","财务费用","EXPENSE",List.of(19)),
        pl(19,"PL_19","其中：利息费用（收入以“-”号填列）","EXPENSE",List.of()),
        pl(20,"PL_20","加：投资收益（损失以“-”号填列）","INCOME",List.of()),
        total("PROFIT",21,"二、营业利润",1,-2,-3,-11,-14,-18,20),
        pl(22,"PL_22","加：营业外收入","INCOME",List.of(23),"NON_OPERATING_REVENUE"),
        pl(23,"PL_23","其中：政府补助","INCOME",List.of()),
        pl(24,"PL_24","减：营业外支出","EXPENSE",List.of(25,26,27,28,29)),
        pl(25,"PL_25","其中：坏账损失","EXPENSE",List.of()),
        pl(26,"PL_26","无法收回的长期债券投资损失","EXPENSE",List.of()),
        pl(27,"PL_27","无法收回的长期股权投资损失","EXPENSE",List.of()),
        pl(28,"PL_28","自然灾害等不可抗力因素造成的损失","EXPENSE",List.of()),
        pl(29,"PL_29","税收滞纳金","EXPENSE",List.of()),
        total("PROFIT",30,"三、利润总额",21,22,-24),
        pl(31,"PL_31","减：所得税费用","EXPENSE",List.of()),total("PROFIT",32,"四、净利润",30,-31));
    static List<Line> lines(String sheet) { return sheet.equals("BALANCE")?BALANCE:PROFIT; }
    static List<Line> all() { return java.util.stream.Stream.concat(BALANCE.stream(),PROFIT.stream()).toList(); }
    static Line find(String key) { return all().stream().filter(l->l.key().equals(key)).findFirst().orElse(null); }
    static Set<String> siblings(String key) {
        Line l=find(key); if(l==null)return Set.of();
        return lines(l.sheet()).stream().filter(Line::direct).map(Line::key).filter(k->!key.equals(k))
                .collect(java.util.stream.Collectors.toSet());
    }
    static Set<Integer> context(String sheet,int number) {
        Set<Integer> found=new LinkedHashSet<>();found.add(number);
        boolean changed;
        do { changed=false; for(Line l:lines(sheet)) {
            if(l.terms().stream().anyMatch(n->found.contains(Math.abs(n))) || l.details().stream().anyMatch(found::contains))
                changed|=found.add(l.number());
        }} while(changed);
        return found;
    }
}
