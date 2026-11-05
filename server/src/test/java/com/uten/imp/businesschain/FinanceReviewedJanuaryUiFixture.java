package com.uten.imp.businesschain;

import com.uten.imp.features.finance.gl.*;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import static org.assertj.core.api.Assertions.assertThat;

/** Separate positive-report UAT book; never mixed with unbound directory stress facts. */
final class FinanceReviewedJanuaryUiFixture {
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceChartService chart;
    @Autowired FinanceAccountingImportService imports;
    @Autowired GlReportLineBindingService bindings;
    @Autowired GlReportService reports;
    @Autowired JdbcTemplate db;

    void seed()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var owner=fixture.seedWorld("january-ui-owner");var reviewer=fixture.seedWorld("january-ui-reviewer");
        fixture.loginAs(owner.superAdminUserId());
        var categories=Map.of("1001","ACCOUNT","3001","EQUITY","5001","INCOME","3103","EQUITY","560301","EXPENSE");
        var names=Map.of("1001","库存现金","3001","实收资本","5001","主营业务收入","3103","本年利润","560301","匿名损益明细");
        for(String code:List.of("1001","3001","5001","3103","560301"))
            chart.createAccount(new FinanceChartContracts.CreateAccount(UUID.randomUUID(),code,names.get(code),"",categories.get(code),"独立匿名1月账套，仅用于实际打印导出验收"));
        for(var account:chart.list()) {
            String bs=switch(account.code()){case "1001"->"BS_1";case "3001"->"BS_48";case "3103"->"BS_51";default->null;};
            String pl=switch(account.code()){case "5001"->"PL_1";case "560301"->"PL_FINANCE";default->null;};
            chart.map(account.code(),new FinanceChartContracts.Mapping(account.version(),account.targets().stream().map(target->target.id()).toList(),bs,pl));
        }
        var balance=imports.preview("BALANCE","独立匿名1月账套","january-balance.xls",
                FinanceAccountingContinuationPostgresTest.january(FinanceAccountingContinuationPostgresTest.balance(),false));
        var journals=imports.preview("VOUCHERS","独立匿名1月账套","january-journals.xls",
                FinanceAccountingContinuationPostgresTest.january(FinanceAccountingContinuationPostgresTest.journals(),true));
        assertThat(balance.source().issues()).isEmpty();assertThat(journals.source().issues()).isEmpty();
        var selected=chart.list().stream().map(account->new FinanceAccountingContracts.AccountSelection(account.code(),account.targets().getFirst().id(),account.version(),account.currencyId())).toList();
        Map<String,String> purposes=new LinkedHashMap<>();journals.source().vouchers().forEach(voucher->purposes.put(voucher.key(),voucher.closingCandidate()?"PNL_CLOSE":"OPERATING"));
        var submitted=imports.submit(journals.importId(),new FinanceAccountingContracts.Submit(journals.version(),balance.importId(),balance.version(),selected,purposes,Map.of(),List.of(),Set.of("560301"),false,true,"两人核对完整原始格式、期初、1月发生及零余额损益例外"));
        fixture.loginAs(reviewer.superAdminUserId());
        var posted=imports.approve(journals.importId(),new FinanceAccountingContracts.Review(submitted.version(),"独立第二人核对完整匿名1月来源"));
        assertThat(posted.entries()).isEqualTo(8);
        // Every other statement project really has no business in this five-code
        // book. Make that explicit through the production policy service.
        Set<String> known=Set.of("BS_1","BS_48","BS_51","PL_1","PL_FINANCE");
        for(var line:bindings.list())if(("BALANCE".equals(line.sheet())||"PROFIT".equals(line.sheet()))&&!known.contains(line.lineKey()))
            bindings.replace(line.lineKey(),List.of(),true);
        var bs=reports.balanceSheet(LocalDate.of(2026,1,31));
        assertThat(bs.rows()).hasSize(53);
        for(int line:List.of(30,53)) {
            var row=bs.rows().stream().filter(value->Integer.valueOf(line).equals(value.get("lineNo"))).findFirst().orElseThrow();
            assertThat((BigDecimal)row.get("periodEnd")).isEqualByComparingTo("595");
            assertThat((BigDecimal)row.get("yearStart")).isEqualByComparingTo("500");
        }
        var pl=reports.profitMonthly(2026,1);
        var net=pl.rows().stream().filter(row->Integer.valueOf(32).equals(row.get("lineNo"))).findFirst().orElseThrow();
        assertThat((BigDecimal)net.get("monthAmount")).isEqualByComparingTo("95");
        assertThat((BigDecimal)net.get("yearAmount")).isEqualByComparingTo("95");
        assertThat(db.queryForObject("SELECT sum(direction*amount) FROM gl_entries",BigDecimal.class)).isEqualByComparingTo("0");
    }
}
