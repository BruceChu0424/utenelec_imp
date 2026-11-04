package com.uten.imp.features.expenseclaim.dto;
import java.util.UUID;
/** Native source links only: no duplicate approval calculation or full workflow payload. */
public record ExpenseClaimFinancialApplication(UUID id,String applicationNo,String kind,String status,String currentStep,boolean canOpen) { }
