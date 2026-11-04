package com.uten.imp.features.finance.application;
import java.util.*;
import static com.uten.imp.features.finance.application.FinanceApplicationContracts.*;

/** Cash execution delegates to original finance/payroll authorities; the workflow never posts a second ledger. */
public interface FinanceApplicationExecutionPort {
    Map<String,Object> execute(UUID id,Execute command);
    Map<String,Object> confirm(UUID id,Action command);
    Map<String,Object> unconfirm(UUID id,Action command);
    Map<String,Object> reverse(UUID id,Action command);
}
