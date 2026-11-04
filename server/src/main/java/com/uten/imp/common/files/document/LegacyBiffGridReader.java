package com.uten.imp.common.files.document;

import com.uten.imp.common.web.*;
import java.math.BigDecimal;
import java.nio.*;
import java.nio.charset.*;
import java.util.*;

/** Bounded raw BIFF3 accounting-balance exports (the supplied Access/UFIDA format is not OLE BIFF8). */
public final class LegacyBiffGridReader {
    private LegacyBiffGridReader() { }
    public static boolean isRaw(byte[] bytes) {
        return bytes!=null&&bytes.length>=10&&u16(bytes,0)==0x0209&&u16(bytes,2)>=4&&u16(bytes,6)==0x0010;
    }
    /** The caller already owns DocumentParseGate. Hidden values are retained for the financial profile. */
    static DocumentGrid read(byte[] bytes,DocumentParseGate.Deadline deadline,boolean includeHidden) {
        if(!isRaw(bytes))throw invalid("不是受支持的旧科目余额导出格式");
        List<RawCell> cells=new ArrayList<>();Set<Integer> hiddenRows=new HashSet<>(),hiddenCols=new HashSet<>();
        int offset=0,records=0;boolean eof=false,first=true;
        while(offset+4<=bytes.length) {
            deadline.check();int sid=u16(bytes,offset),length=u16(bytes,offset+2);offset+=4;
            if(length>8228||offset+length>bytes.length||++records>100000)throw invalid("旧科目余额文件记录不完整或超过读取预算");
            int data=offset;offset+=length;
            if(sid==0x0209){if(!first)throw invalid("旧科目余额文件包含多个工作表，请核对完整来源");first=false;}
            else if(sid==0x000a){eof=true;break;}
            else if(sid==0x002f)throw invalid("请使用未加密的科目余额来源文件");
            else if(sid==0x0208&&length>=16){if((u16(bytes,data+12)&0x20)!=0)hiddenRows.add(u16(bytes,data));}
            else if(sid==0x007d&&length>=12){if((u16(bytes,data+8)&1)!=0)for(int c=u16(bytes,data);c<=u16(bytes,data+2);c++)hiddenCols.add(c);}
            else if(sid==0x0204) {
                if(length<8)throw invalid("旧科目余额文本记录无效");
                int count=u16(bytes,data+6);if(count>length-8)throw invalid("旧科目余额文本未完整保存");
                cells.add(new RawCell(u16(bytes,data),u16(bytes,data+2),Arrays.copyOfRange(bytes,data+8,data+8+count),null));
            } else if(sid==0x0203) {
                if(length!=14)throw invalid("旧科目余额数字记录无效");
                double value=ByteBuffer.wrap(bytes,data+6,8).order(ByteOrder.LITTLE_ENDIAN).getDouble();
                if(!Double.isFinite(value))throw invalid("旧科目余额含无法确认的数字");
                cells.add(new RawCell(u16(bytes,data),u16(bytes,data+2),null,SpreadsheetGridReader.excelNumber(BigDecimal.valueOf(value))));
            } else if(sid==0x0006||sid==0x0206||sid==0x0406||sid==0x027e||sid==0x00bd||sid==0x0205) {
                throw invalid("此旧科目余额含不支持的计算/编码单元格，请使用完整的XLSX数值导出");
            }
        }
        if(!eof||offset!=bytes.length)throw invalid("旧科目余额文件结束标记不完整");
        Charset encoding=encoding(cells);TreeMap<Integer,TreeMap<Integer,DocumentGrid.Cell>> rows=new TreeMap<>();
        boolean truncated=false;int maxColumn=-1;Set<Integer> skipped=new HashSet<>();
        for(RawCell cell:cells) {
            deadline.check();if(cell.column()>10)throw invalid("此旧导出不是9列或11列科目余额格式");
            if(cell.row()>=SpreadsheetGridReader.MAX_ROWS_PER_SHEET){truncated=true;continue;}
            if(!includeHidden&&(hiddenRows.contains(cell.row())||hiddenCols.contains(cell.column()))){skipped.add(cell.row());continue;}
            DocumentGrid.Cell value;
            if(cell.text()!=null) {
                String text=decode(cell.text(),encoding);if(text.length()>SpreadsheetGridReader.MAX_CELL_CHARS)throw invalid("旧科目余额文本过长");
                value=DocumentGrid.Cell.text(cell.column(),SpreadsheetGridReader.cleanText(text));
            }else value=new DocumentGrid.Cell(cell.column(),SpreadsheetGridReader.plain(cell.number()),DocumentGrid.CellKind.NUMBER,cell.number());
            if(rows.computeIfAbsent(cell.row(),k->new TreeMap<>()).putIfAbsent(cell.column(),value)!=null)
                throw invalid("旧科目余额含重复坐标，不能静默覆盖来源单元格");
            maxColumn=Math.max(maxColumn,cell.column());
        }
        List<DocumentGrid.Row> emitted=new ArrayList<>();rows.forEach((row,values)->emitted.add(new DocumentGrid.Row(row,List.copyOf(values.values()))));
        return new DocumentGrid(List.of(new DocumentGrid.Sheet("Sheet 1",0,List.copyOf(emitted),List.of(),skipped.size(),maxColumn,truncated)));
    }
    private record RawCell(int row,int column,byte[] text,BigDecimal number) { }
    private static Charset encoding(List<RawCell> cells) {
        List<Charset> matches=new ArrayList<>();
        for(String candidate:List.of("GBK","UTF-8","windows-1252")) {
            Charset charset=Charset.forName(candidate);Set<String> headers=new HashSet<>();
            try{for(var cell:cells)if(cell.row()==0&&cell.text()!=null)headers.add(decode(cell.text(),charset).strip());}
            catch(ApiException unsupported){continue;}
            if(headers.containsAll(Set.of("科目编码","科目名称","期初借方","期初贷方","期末借方","期末贷方")))matches.add(charset);
        }
        if(matches.size()!=1)throw invalid("旧文件字符集或表头不能唯一确认，不能按乱码导入");
        return matches.getFirst();
    }
    private static String decode(byte[] bytes,Charset charset) {
        try{return charset.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();}
        catch(CharacterCodingException error){throw invalid("旧科目余额存在不能完整解码的来源文字");}
    }
    private static int u16(byte[] data,int offset){return Byte.toUnsignedInt(data[offset])|(Byte.toUnsignedInt(data[offset+1])<<8);}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
