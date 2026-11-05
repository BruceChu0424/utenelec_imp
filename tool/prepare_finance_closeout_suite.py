from pathlib import Path
import argparse
import subprocess
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description="Select finance and affected shared caller regressions")
parser.add_argument("--output-directory", type=Path, default=root / "build/finance-closeout-20261104")
out = parser.parse_args().output_directory
out.mkdir(parents=True, exist_ok=True)
java = root / "server/src/test/java"
paths = set((java / "com/uten/imp/features/finance").rglob("*Test.java"))
for scope in ("com/uten/imp/features/documents", "com/uten/imp/common/platformcolumns", "com/uten/imp/common/finance", "com/uten/imp/common/export",
              "com/uten/imp/features/master/account", "com/uten/imp/features/purchase/order", "com/uten/imp/features/subcontract/order"):
    paths.update((java / scope).rglob("*Test.java"))
prefixes = ("Finance", "ProcurementFirstPayable", "PayableStatement", "SupplierPrepayment", "CustomerPrepayment",
            "SalesShipmentFinanceReleaseRate", "ProcurementFinance", "StandardFinanceApproval", "SubcontractLossValue",
            "NonFinanceUnapproval")
for path in (java / "com/uten/imp/businesschain").glob("*Test.java"):
    if path.name.startswith(prefixes) and path.stem != "FinanceInteractiveUatHarnessTest":
        paths.add(path)
for name in ("ExpenseEventMigrationCompatibilityTest", "ExpensePaymentReversalUpgradePostgresTest",
             "ExpenseClaimPaymentReversalMigrationContractTest", "PurchaseReceiptSuccessorQuantityPostgresTest",
             "AuditTriggerCoverageMigrationContractTest", "ProcurementOrderSourceRevisionEndToEndTest",
             "ProcurementUnapprovalEligibilityEndToEndTest", "GiftPhysicalConservationEndToEndTest",
             "GiftUnitRateConservationEndToEndTest", "GiftFreeOnlyOrderConservationEndToEndTest",
             "SubcontractShortDeliveryEndToEndTest", "SubcontractToleranceAutoSettleEndToEndTest",
             "DocumentQuantitySuccessorEndToEndTest", "SalesReturnActualSourceQuantityEndToEndTest",
             "SubcontractOrderSourceFifoEndToEndTest", "DocumentQuantityContractTest",
             "NativeLegacyOpeningPostgresTest", "LegacyOpeningOffsetEndToEndTest",
             "SupplierAdvanceStatementReplayPostgresTest", "PartyStatementNativeCashHeaderTest",
             "ProcurementSupplierHistoryPostgresTest", "ProcurementMasterDefaultsSyncPostgresTest"):
    paths.update(java.rglob(name + ".java"))
# Include task-owned caller, account, shared-contract and upgrade regressions
# added or changed after the original finance audit selector was captured.
for command in (["git", "diff", "--name-only", "HEAD", "--", "server/src/test/java"],
                ["git", "ls-files", "--others", "--exclude-standard", "--", "server/src/test/java"]):
    for relative in subprocess.check_output(command, cwd=root).decode().splitlines():
        path = root / relative
        if path.name.endswith("Test.java") and path.stem != "FinanceInteractiveUatHarnessTest" and path.is_file():
            paths.add(path)
classes = sorted(str(path.relative_to(java).with_suffix("")).replace("\\", ".").replace("/", ".") for path in paths)
(out / "selected-classes.txt").write_text("\n".join(classes)+"\n", encoding="utf-8")
(out / "uat-class.txt").write_text("com.uten.imp.businesschain.FinanceInteractiveUatHarnessTest\n", encoding="utf-8")
print(f"Selected {len(classes)} finance and source-chain test classes; manual UAT excluded")
