package com.uten.imp.features.finance.application;
import com.uten.imp.application.port.WorkbenchBadgeSources;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.*;
@Component @RequiredArgsConstructor
public class FinanceApplicationWorkbenchBadgeSources implements WorkbenchBadgeSources {
    private final FinanceApplicationController applications;
    @Override public List<Source> sources(){return List.of(new Source("financeApplication",()->WorkbenchBadgeSources.numbers(applications.counts())));}
}
