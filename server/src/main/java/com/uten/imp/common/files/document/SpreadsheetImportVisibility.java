package com.uten.imp.common.files.document;

import com.uten.imp.common.web.*;
import org.apache.poi.ss.usermodel.*;
import java.io.ByteArrayInputStream;

/** Strict financial imports must not silently omit hidden records or computed identity cells. */
public final class SpreadsheetImportVisibility {
    private SpreadsheetImportVisibility() { }
    /** Call after the bounded grid reader has validated file/container limits. */
    public static void requireCompleteLiteralIdentities(byte[] bytes,int identityColumns) {
        DocumentParseGate.run(deadline->{
            try(var workbook=WorkbookFactory.create(new ByteArrayInputStream(bytes))) {
                com.uten.imp.common.importing.PlatformWorkbookSchema.requireImportable(workbook);
                com.uten.imp.common.importing.ImportColumnGuard.requireSingleContentSheet(workbook);
                for(int sheetIndex=0;sheetIndex<workbook.getNumberOfSheets();sheetIndex++) {
                    if(workbook.isSheetHidden(sheetIndex)||workbook.isSheetVeryHidden(sheetIndex))throw invalid("导入文件存在隐藏工作表，请先核对原文件");
                    var sheet=workbook.getSheetAt(sheetIndex);
                    if(sheet.getLastRowNum()>=SpreadsheetGridReader.MAX_ROWS_PER_SHEET)throw invalid("导入工作表超过完整读取范围");
                    for(var row:sheet) {
                        deadline.check();
                        for(var cell:row) {
                            if(cell.getCellType()==CellType.BLANK)continue;
                            if(row.getZeroHeight()||sheet.isColumnHidden(cell.getColumnIndex()))throw invalid("导入文件存在隐藏数据，请先核对原文件");
                            if(cell.getColumnIndex()<identityColumns&&cell.getCellType()==CellType.FORMULA)throw invalid("科目身份字段不能使用公式，请使用原始文本");
                        }
                    }
                }
            }catch(ApiException error){throw error;}
            catch(Exception error){throw invalid("无法完整核对导入工作簿");}
            return true;
        });
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
