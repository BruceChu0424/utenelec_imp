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
    private static Line bs(int n,String category,String... roots) {
        return new Line("BS_"+n,n,FinanceTemplateContract.row("BALANCE",n),"BALANCE",category,
                n==19 || Set.of("LIABILITY","EQUITY").contains(category) ? -1:1,
                List.of(),n==9?List.of(10,11,12,13):List.of(),List.of(roots));
    }
    private static Line total(String sheet,int n,Integer... terms) {
        return new Line((sheet.equals("BALANCE")?"BS_":"PL_")+n,n,FinanceTemplateContract.row(sheet,n),sheet,null,1,List.of(terms),List.of(),List.of());
    }
    private static Line pl(int n,String key,String category,List<Integer> details,String... roots) {
        return new Line(key,n,FinanceTemplateContract.row("PROFIT",n),"PROFIT",category,category.equals("INCOME")?-1:1,List.of(),details,List.of(roots));
    }
    static final List<Line> BALANCE=List.of(
        bs(1,"ACCOUNT","CASH","BANK"),bs(2,"ACCOUNT"),
        bs(3,"ACCOUNT"),bs(4,"ACCOUNT","RECEIVABLES"),
        bs(5,"ACCOUNT"),bs(6,"ACCOUNT"),bs(7,"ACCOUNT"),
        bs(8,"ACCOUNT","OTHER_RECEIVABLES","OTHER_RECEIVABLES_ALTERNATE"),
        bs(9,"ACCOUNT","INVENTORY"),bs(10,"ACCOUNT"),
        bs(11,"ACCOUNT"),bs(12,"ACCOUNT"),bs(13,"ACCOUNT"),
        bs(14,"ACCOUNT","PREPAID"),total("BALANCE",15,1,2,3,4,5,6,7,8,9,14),
        bs(16,"ACCOUNT"),bs(17,"ACCOUNT"),
        bs(18,"ACCOUNT","FIXED_ASSETS"),bs(19,"ACCOUNT","ACCUMULATED_DEPRECIATION"),
        total("BALANCE",20,18,-19),bs(21,"ACCOUNT"),
        bs(22,"ACCOUNT"),bs(23,"ACCOUNT"),bs(24,"ACCOUNT"),
        bs(25,"ACCOUNT"),bs(26,"ACCOUNT"),bs(27,"ACCOUNT"),
        bs(28,"ACCOUNT"),total("BALANCE",29,16,17,20,21,22,23,24,25,26,27,28),
        total("BALANCE",30,15,29),bs(31,"LIABILITY"),bs(32,"LIABILITY"),
        bs(33,"LIABILITY","PAYABLES"),bs(34,"LIABILITY"),
        bs(35,"LIABILITY"),bs(36,"LIABILITY","TAX_PAYABLE"),
        bs(37,"LIABILITY"),bs(38,"LIABILITY"),
        bs(39,"LIABILITY","OTHER_PAYABLES","OTHER_PAYABLES_ALTERNATE"),
        bs(40,"LIABILITY"),total("BALANCE",41,31,32,33,34,35,36,37,38,39,40),
        bs(42,"LIABILITY"),bs(43,"LIABILITY"),bs(44,"LIABILITY"),
        bs(45,"LIABILITY"),total("BALANCE",46,42,43,44,45),
        total("BALANCE",47,41,46),bs(48,"EQUITY","CAPITAL"),
        bs(49,"EQUITY"),bs(50,"EQUITY"),bs(51,"EQUITY","RETAINED_PROFIT"),
        total("BALANCE",52,48,49,50,51),
        total("BALANCE",53,47,52));
    static final List<Line> PROFIT=List.of(
        pl(1,"PL_1","INCOME",List.of(),"MAIN_REVENUE","OTHER_REVENUE"),
        pl(2,"PL_2","EXPENSE",List.of(),"MAIN_COST","OTHER_COST"),
        pl(3,"PL_TAX","EXPENSE",List.of()),
        pl(11,"SALES_FEE","EXPENSE",List.of()),
        pl(14,"PL_14","EXPENSE",List.of(),"ADMIN_EXPENSE"),
        pl(18,"PL_FINANCE","EXPENSE",List.of(19)),
        pl(19,"PL_19","EXPENSE",List.of()),
        pl(20,"PL_20","INCOME",List.of()),
        total("PROFIT",21,1,-2,-3,-11,-14,-18,20),
        pl(22,"PL_22","INCOME",List.of(23),"NON_OPERATING_REVENUE"),
        pl(23,"PL_23","INCOME",List.of()),
        pl(24,"PL_24","EXPENSE",List.of(25,26,27,28,29)),
        pl(25,"PL_25","EXPENSE",List.of()),
        pl(26,"PL_26","EXPENSE",List.of()),
        pl(27,"PL_27","EXPENSE",List.of()),
        pl(28,"PL_28","EXPENSE",List.of()),
        pl(29,"PL_29","EXPENSE",List.of()),
        total("PROFIT",30,21,22,-24),
        pl(31,"PL_31","EXPENSE",List.of()),total("PROFIT",32,30,-31));
    static final Line PRIOR_ADJUSTMENT=new Line("PL_PRIOR_ADJUSTMENT",33,FinanceTemplateContract.row("PROFIT",33),
            "PROFIT","EQUITY",1,List.of(),List.of(),List.of());
    static List<Line> lines(String sheet) { return sheet.equals("BALANCE")?BALANCE:PROFIT; }
    static List<Line> mappingLines(String sheet) {
        return sheet.equals("BALANCE")?BALANCE:java.util.stream.Stream.concat(PROFIT.stream(),java.util.stream.Stream.of(PRIOR_ADJUSTMENT)).toList();
    }
    static List<Line> all() { return java.util.stream.Stream.concat(BALANCE.stream(),mappingLines("PROFIT").stream()).toList(); }
    static Line find(String key) { return all().stream().filter(l->l.key().equals(key)).findFirst().orElse(null); }
    static Set<String> siblings(String key) {
        Line l=find(key); if(l==null)return Set.of();
        return mappingLines(l.sheet()).stream().filter(Line::direct).map(Line::key).filter(k->!key.equals(k))
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
