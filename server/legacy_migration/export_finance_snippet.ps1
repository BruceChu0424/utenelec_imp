# =====================================================================
# Legacy DB (YTDQ_2023) finance-module export via .NET SqlClient -> UTF-8 CSV
# =====================================================================
# Exports the M_* money-flow tables for migrate_finance.sql ingestion.
# Output lands in ./data/m_*.csv (next to the purchase/warehouse CSVs).
#
# Companion to export_legacy.ps1 (which covers master + purchase + warehouse).
# This file is intentionally a focused snippet: 12 M_ tables (M_Acc/M_Style/
# M_in/M_out/M_Get/M_Paid/M_DPaid/M_DPaidItem/M_OGet/M_OGetItem/M_Bank/
# M_AllCheck), one single-line SQL each, column aliases aligned 1:1 with the
# staging tables in migrate_finance.sql.
#
# IMPORTANT (Windows PowerShell 5.1): keep this file ASCII-only. PS 5.1 reads
# a no-BOM .ps1 as the system ANSI codepage (CP936 here); non-ASCII bytes in
# comments/strings can swallow quotes and silently break parsing. The Chinese
# AccName/StyleName/Company DATA flows through SqlClient (Unicode) and gets
# written to the CSV as UTF-8 directly, bypassing the GBK console -- safe.
# If you must add Chinese in PS code, save the file as UTF-8 *with BOM*.
#
# Usage (from bash or PowerShell):
#   powershell -ExecutionPolicy Bypass -File export_finance_snippet.ps1 M_Acc
#   powershell -ExecutionPolicy Bypass -File export_finance_snippet.ps1 All
#
# Column order of each SQL MUST match migrate_finance.sql staging tables
# (psql \copy maps CSV columns to staging columns by position).
# =====================================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('M_Acc','M_Style','M_in','M_out','M_Get','M_Paid',
                 'M_DPaid','M_DPaidItem','M_OGet','M_OGetItem','M_Bank',
                 'M_AllCheck','All')]
    [string]$Target = 'All'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data   # preload SqlClient for Windows PowerShell 5.1
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $here 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }

$cs = 'Server=(localdb)\MSSQLLocalDB;Database=YTDQ_2023;Integrated Security=true;TrustServerCertificate=true;'

function Export-Query {
    param(
        [string]$Sql,
        [string]$OutPath,
        [char]$Delimiter = '|'
    )
    if ([string]::IsNullOrEmpty($Sql)) { throw 'Export-Query: Sql is empty' }
    $conn = New-Object System.Data.SqlClient.SqlConnection($cs)
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        $r = $cmd.ExecuteReader()
        $enc = New-Object System.Text.UTF8Encoding($false)
        $fs = [System.IO.File]::Create($OutPath)
        $w = New-Object System.IO.StreamWriter($fs, $enc)
        try {
            $headers = for ($i = 0; $i -lt $r.FieldCount; $i++) { $r.GetName($i) }
            $w.WriteLine(($headers -join $Delimiter))
            while ($r.Read()) {
                $vals = for ($i = 0; $i -lt $r.FieldCount; $i++) {
                    if ($r.IsDBNull($i)) {
                        ''
                    } else {
                        # RFC4180: quote fields that contain the delimiter, a double-quote, or a newline;
                        # otherwise PostgreSQL COPY (FORMAT csv, DELIMITER '|') mis-parses them (e.g. a
                        # Note with '|' or CRLF shifts every later column -> "missing data for column X").
                        $v = $r.GetValue($i).ToString()
                        if ($v.Contains([string]$Delimiter) -or $v.Contains('"') -or $v.Contains("`r") -or $v.Contains("`n")) {
                            '"' + ($v -replace '"', '""') + '"'
                        } else {
                            $v
                        }
                    }
                }
                $w.WriteLine(($vals -join $Delimiter))
            }
        }
        finally {
            $w.Close(); $fs.Close(); $r.Close()
        }
    }
    finally { $conn.Close() }
    Write-Host ('OK  ' + $OutPath + '  (' + (Get-Item $OutPath).Length + ' bytes)')
}

# --- SQL as single-line single-quoted strings (no here-strings, no '' literals;
#     NULLs are turned into '' by the reader). Column order MUST match
#     migrate_finance.sql staging tables. ---

# M_Acc (27 rows, 13 cols) -> m_acc_stage.
# AStyle kept for reference (discarded in migrate; account_type rebuilt from AccName).
$mAccSql = 'SELECT ID AS legacy_id, Number AS code, AccName AS name, AccNode AS bank_account_no, InitTotal AS init_balance, GetTotal AS receipts_total, PaidTotal AS payments_total, ISNULL(FactTotal,0) AS balance_current, ISNULL(Remark,'''') AS remark, ISNULL(ParentID,0) AS parent_legacy_id, ISNULL(Status,'''') AS status, ISNULL(StyleID,0) AS style_legacy_id, ISNULL(AStyle,1) AS a_style FROM M_Acc ORDER BY ID'

# M_Style (124 rows, 15 cols) -> m_style_stage.
# Status/DeptStatus/QStatus/OrientStatus1/OrientStatus2 are bit -> reader emits True/False (COPY parses bool).
$mStyleSql = 'SELECT ID AS legacy_id, StyleClassid AS style_class_id, StyleNumber AS code, StyleName AS name, ISNULL(Parentid,0) AS parent_legacy, ISNULL(Remark,'''') AS remark, ISNULL(Status,0) AS status, ISNULL(DeptStatus,0) AS dept_status, ISNULL(NextNumber,'''') AS next_number, InitTotal AS init_total, ISNULL(QStatus,0) AS q_status, ISNULL(OrientStatus1,0) AS orient_status1, ISNULL(OrientStatus2,0) AS orient_status2, ISNULL(Unit,'''') AS unit, ISNULL(ItemID,0) AS item_id FROM M_Style ORDER BY ID'

# M_in (42,489 rows, 16 cols) -> m_in_stage.
# [M_In] bracket-quoted (column shares name with table); STotal/TTotal/Work_ID skipped (dynamic/redundant).
$mInSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, ISNULL(ClientID,0) AS client_legacy_id, MIn_Date AS bill_date, Last_Date AS due_date, Total AS total, [M_In] AS settled, M_Rare AS balance, ISNULL(Note,'''') AS note, Paid AS paid_bit, PaidDate AS paid_date, ISNULL(BStyle,0) AS b_style, ISNULL(PStyle,0) AS p_style, ISNULL(BillID,0) AS bill_legacy_id, ISNULL(CurID,0) AS currency_legacy_id, ISNULL(CRate,1) AS exchange_rate FROM M_In ORDER BY ID'

# M_out (44,534 rows, 16 cols) -> m_out_stage. Symmetric to M_in.
$mOutSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, ISNULL(VendID,0) AS supplier_legacy_id, MOut_Date AS bill_date, Last_Date AS due_date, Total AS total, [M_Out] AS settled, M_Rare AS balance, ISNULL(Note,'''') AS note, Paid AS paid_bit, PaidDate AS paid_date, ISNULL(BStyle,0) AS b_style, ISNULL(PStyle,0) AS p_style, ISNULL(BillID,0) AS bill_legacy_id, ISNULL(CurID,0) AS currency_legacy_id, ISNULL(CRate,1) AS exchange_rate FROM M_Out ORDER BY ID'

# M_Get (7,804 rows, 25 cols) -> m_get_stage.
$mGetSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, GetDate AS bill_date, ISNULL(ClientID,0) AS client_legacy_id, WorkID AS work_id, RecStyle AS rec_style, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(RecAcc,0) AS rec_acc, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(InvoicesNo,'''') AS invoices_no, MTotal AS mtotal, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, ISNULL(StepID,0) AS step_id, Cancel AS cancel, ISNULL(slf,0) AS slf, ISNULL(qtfy,0) AS qtfy, ISNULL(qtfymc,0) AS qtfymc, ISNULL(dfch,0) AS dfch, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_Get.MakeID),'''') AS maker_name, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_Get.ApproverID),'''') AS approver_name, ISNULL((SELECT Emp_Name FROM B_Worker WHERE ID = M_Get.WorkID),'''') AS work_name FROM M_Get ORDER BY ID'

# M_Paid (4,545 rows, 23 cols) -> m_paid_stage. Symmetric to M_Get (VendID/PaidAcc/dfzh/jsr).
$mPaidSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, PaidDate AS bill_date, ISNULL(VendID,0) AS supplier_legacy_id, WorkID AS work_id, PaidStyle AS paid_style, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(PaidAcc,0) AS paid_acc, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(InvoicesNo,'''') AS invoices_no, MTotal AS mtotal, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, ISNULL(StepID,0) AS step_id, Cancel AS cancel, ISNULL(dfzh,0) AS dfzh, ISNULL(jsr,'''') AS jsr, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_Paid.MakeID),'''') AS maker_name, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_Paid.ApproverID),'''') AS approver_name, ISNULL((SELECT Emp_Name FROM B_Worker WHERE ID = M_Paid.WorkID),'''') AS work_name FROM M_Paid ORDER BY ID'

# M_DPaid (1,125 rows, 20 cols) -> m_dpaid_stage. Total/MTotal split (sample Total=0 only MTotal set).
$mDpaidSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, PaidDate AS bill_date, WorkID AS work_id, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(PaidAcc,0) AS paid_acc, ISNULL(InvoicesNo,'''') AS invoices_no, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(PaidStyle,0) AS paid_style, MTotal AS mtotal, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, Cancel AS cancel, ISNULL(dfzh,0) AS dfzh, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_DPaid.MakeID),'''') AS maker_name, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_DPaid.ApproverID),'''') AS approver_name, ISNULL((SELECT Emp_Name FROM B_Worker WHERE ID = M_DPaid.WorkID),'''') AS work_name FROM M_DPaid ORDER BY ID'

# M_DPaidItem (8,537 rows, 11 cols) -> m_dpaid_item_stage.
$mDpaidItemSql = 'SELECT ID AS legacy_id, ISNULL(BillID,0) AS bill_legacy_id, ISNULL(StyleID,0) AS style_legacy_id, Total AS total, ISNULL(Summary,'''') AS summary, DeptID AS dept_legacy_id, CTotal AS ctotal, ISNULL(dfmc,'''') AS dfmc, QTY AS qty, Price AS price, ISNULL(AccID,0) AS acc_id FROM M_DPaidItem ORDER BY ID'

# M_OGet (1,552 rows, 20 cols) -> m_oget_stage. Symmetric to M_DPaid (RecAcc/RecStyle).
$mOgetSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, GetDate AS bill_date, WorkID AS work_id, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(RecAcc,0) AS rec_acc, ISNULL(InvoicesNo,'''') AS invoices_no, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(RecStyle,0) AS rec_style, MTotal AS mtotal, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, Cancel AS cancel, ISNULL(dfzh,0) AS dfzh, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_OGet.MakeID),'''') AS maker_name, ISNULL((SELECT fname FROM Sys_Operator WHERE ID = M_OGet.ApproverID),'''') AS approver_name, ISNULL((SELECT Emp_Name FROM B_Worker WHERE ID = M_OGet.WorkID),'''') AS work_name FROM M_OGet ORDER BY ID'

# M_OGetItem (1,551 rows, 8 cols) -> m_oget_item_stage. NO QTY/Price in old schema (set NULL in migrate).
$mOgetItemSql = 'SELECT ID AS legacy_id, ISNULL(BillID,0) AS bill_legacy_id, ISNULL(StyleID,0) AS style_legacy_id, Total AS total, ISNULL(Summary,'''') AS summary, DeptID AS dept_legacy_id, CTotal AS ctotal, ISNULL(df,'''') AS df FROM M_OGetItem ORDER BY ID'

# M_Bank (0 rows, 17 cols) -> empty CSV (header only). migrate_finance.sql skips ingest;
# structure preserved in V57 finance_bank_transfers for future activation.
$mBankSql = 'SELECT ID AS legacy_id, BillNo AS bill_no, BillDate AS bill_date, ISNULL(OutAcc,0) AS out_acc, WorkID AS work_id, Total AS total, MakeID AS make_id, ApproverID AS approver_id, Status AS status, Status2 AS status2, ISNULL(Remark,'''') AS remark, ISNULL(InvoicesNo,'''') AS invoices_no, CancelDate AS cancel_date, ISNULL(Source,'''') AS source, ISNULL(CurID,0) AS cur_id, ISNULL(CRate,1) AS crate, Cancel AS cancel FROM M_Bank ORDER BY ID'

# M_AllCheck (30,626 rows, 13 cols) -> m_allcheck_stage. Company carries client/supplier name (denormalized).
$mAllcheckSql = 'SELECT ID AS legacy_id, ISNULL(BillNo,'''') AS bill_no, ISNULL(CheckNo,'''') AS check_no, ISNULL(Remark,'''') AS remark, ISNULL(Company,'''') AS company, InTotal AS in_total, OutTotal AS out_total, BillDate AS bill_date, OutDate AS out_date, ISNULL(AccID,0) AS acc_id, ISNULL(Source,'''') AS source, ISNULL(BStyle,0) AS b_style, ISNULL(BillID,0) AS bill_id FROM M_AllCheck ORDER BY ID'

switch ($Target) {
    'M_Acc'        { Export-Query -Sql $mAccSql        -OutPath (Join-Path $dataDir 'm_acc.csv') }
    'M_Style'      { Export-Query -Sql $mStyleSql      -OutPath (Join-Path $dataDir 'm_style.csv') }
    'M_in'         { Export-Query -Sql $mInSql         -OutPath (Join-Path $dataDir 'm_in.csv') }
    'M_out'        { Export-Query -Sql $mOutSql        -OutPath (Join-Path $dataDir 'm_out.csv') }
    'M_Get'        { Export-Query -Sql $mGetSql        -OutPath (Join-Path $dataDir 'm_get.csv') }
    'M_Paid'       { Export-Query -Sql $mPaidSql       -OutPath (Join-Path $dataDir 'm_paid.csv') }
    'M_DPaid'      { Export-Query -Sql $mDpaidSql      -OutPath (Join-Path $dataDir 'm_dpaid.csv') }
    'M_DPaidItem'  { Export-Query -Sql $mDpaidItemSql  -OutPath (Join-Path $dataDir 'm_dpaid_item.csv') }
    'M_OGet'       { Export-Query -Sql $mOgetSql       -OutPath (Join-Path $dataDir 'm_oget.csv') }
    'M_OGetItem'   { Export-Query -Sql $mOgetItemSql   -OutPath (Join-Path $dataDir 'm_oget_item.csv') }
    'M_Bank'       { Export-Query -Sql $mBankSql       -OutPath (Join-Path $dataDir 'm_bank.csv') }
    'M_AllCheck'   { Export-Query -Sql $mAllcheckSql   -OutPath (Join-Path $dataDir 'm_allcheck.csv') }
    'All' {
        Export-Query -Sql $mAccSql        -OutPath (Join-Path $dataDir 'm_acc.csv')
        Export-Query -Sql $mStyleSql      -OutPath (Join-Path $dataDir 'm_style.csv')
        Export-Query -Sql $mInSql         -OutPath (Join-Path $dataDir 'm_in.csv')
        Export-Query -Sql $mOutSql        -OutPath (Join-Path $dataDir 'm_out.csv')
        Export-Query -Sql $mGetSql        -OutPath (Join-Path $dataDir 'm_get.csv')
        Export-Query -Sql $mPaidSql       -OutPath (Join-Path $dataDir 'm_paid.csv')
        Export-Query -Sql $mDpaidSql      -OutPath (Join-Path $dataDir 'm_dpaid.csv')
        Export-Query -Sql $mDpaidItemSql  -OutPath (Join-Path $dataDir 'm_dpaid_item.csv')
        Export-Query -Sql $mOgetSql       -OutPath (Join-Path $dataDir 'm_oget.csv')
        Export-Query -Sql $mOgetItemSql   -OutPath (Join-Path $dataDir 'm_oget_item.csv')
        Export-Query -Sql $mBankSql       -OutPath (Join-Path $dataDir 'm_bank.csv')
        Export-Query -Sql $mAllcheckSql   -OutPath (Join-Path $dataDir 'm_allcheck.csv')
    }
}
