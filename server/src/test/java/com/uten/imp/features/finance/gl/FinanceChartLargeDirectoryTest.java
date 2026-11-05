package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinancialChartCurrencyReadPort;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.FinanceReportTestAccess;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.nio.charset.StandardCharsets;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FinanceChartLargeDirectoryTest {
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @ParameterizedTest
    @ValueSource(ints={5001,10003})
    void completeDirectoryPreservesItsOrderAndTailCurrencyAfterSeveralBoundedReads(int count)throws Exception {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader","test",
                List.of(new SimpleGrantedAuthority("finance_report:view"))));
        var db=mock(JdbcTemplate.class);
        var currencies=mock(FinancialChartCurrencyReadPort.class);
        var chart=new FinanceChartService(db,null,new ObjectMapper(),null,mock(SecurityContextCurrentUser.class),
                FinanceReportTestAccess.company(),null,mock(TxSessionVars.class),null,currencies);
        // A descending source order catches sorting or truncation during batching.
        var sourceCodes=java.util.stream.IntStream.range(0,count).mapToObj(index->Integer.toString(100000+count-index)).toList();
        when(db.queryForList("SELECT code FROM finance_chart_codes",String.class)).thenReturn(sourceCodes);
        var batches=new ArrayList<Set<String>>();
        when(currencies.read(anySet())).thenAnswer(call->{
            Set<String> requested=call.getArgument(0);
            assertThat(requested).isNotEmpty().hasSizeLessThanOrEqualTo(5000);
            batches.add(Set.copyOf(requested));
            Map<String,FinancialChartCurrencyReadPort.Reference> result=new LinkedHashMap<>();
            requested.forEach(code->result.put(code,new FinancialChartCurrencyReadPort.Reference(code,currency(code),true,"",4)));
            return result;
        });
        String directorySql="SELECT code,name,currency_name,row_version,classification FROM finance_chart_codes ORDER BY sort_order,code";
        when(db.query(eq(directorySql),org.mockito.ArgumentMatchers.<RowMapper<FinanceChartContracts.Account>>any())).thenAnswer(call->{
            RowMapper<FinanceChartContracts.Account> mapper=call.getArgument(1);
            var rows=new ArrayList<FinanceChartContracts.Account>();
            String[] currentCode={null};
            var row=mock(ResultSet.class);
            when(row.getString(1)).thenAnswer(ignored->currentCode[0]);
            when(row.getString(2)).thenAnswer(ignored->"科目"+currentCode[0]);
            when(row.getString(3)).thenReturn("");
            when(row.getLong(4)).thenReturn(4L);
            when(row.getString(5)).thenReturn("ASSET");
            for(int index=0;index<sourceCodes.size();index++) {
                currentCode[0]=sourceCodes.get(index);
                rows.add(mapper.mapRow(row,index));
            }
            return rows;
        });

        var result=chart.list();

        assertThat(result).hasSize(count).extracting(FinanceChartContracts.Account::code).containsExactlyElementsOf(sourceCodes);
        assertThat(result).allSatisfy(account->assertThat(account.currencyId()).isEqualTo(currency(account.code())));
        assertThat(batches).hasSize((count+4999)/5000);
        assertThat(batches.getLast()).hasSize(count%5000);
        var allRequested=new LinkedHashSet<String>();
        batches.forEach(batch->{assertThat(allRequested).doesNotContainAnyElementsOf(batch);allRequested.addAll(batch);});
        assertThat(allRequested).containsExactlyInAnyOrderElementsOf(sourceCodes);
        verify(currencies,times(batches.size())).read(anySet());
    }

    private static UUID currency(String code){return UUID.nameUUIDFromBytes(code.getBytes(StandardCharsets.UTF_8));}
}
