package com.uten.imp.features.ai.chat;

import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;

/**
 * Fabricated workbooks for the document route tests. Every name, ID number and phone is invented here; ID
 * numbers carry a valid GB 11643 check digit so they look exactly like real ones to the rules under test.
 */
final class AiDocumentFixtures {
    static final String ROSTER_TITLE = "测试有限公司员工花名册";
    static final List<String> ROSTER_HEADER = List.of("序号", "姓名", "性别", "部门", "岗位", "入职日期", "身份证号码", "手机号码");
    private static final String[] SURNAMES = {"赵", "钱", "孙", "李", "周", "吴", "郑", "王", "冯", "陈"};
    private static final String[] GIVEN = {"一", "二", "三", "四", "五", "六", "七", "八", "九", "十"};
    private static final String[] DEPARTMENTS = {"注塑一部", "装配二部", "品质三部", "仓储四部", "采购五部", "行政六部", "研发七部", "销售八部", "财务九部"};

    /** One fabricated employee row; the department is merged vertically per group of ten. */
    record Person(String name, String gender, String department, String position, LocalDate hired, String idNumber, long phone) {}

    private AiDocumentFixtures() {}

    static List<Person> people(int count) {
        List<Person> people = new ArrayList<>();
        for (int i = 1; i <= count; i++) {
            LocalDate birth = LocalDate.of(1990, 1, 1).plusDays(i * 37L);
            String first17 = "110101" + birth.toString().replace("-", "") + String.format("%03d", i);
            people.add(new Person(SURNAMES[i % 10] + "试" + GIVEN[(i / 10) % 10] + GIVEN[i % 10], i % 2 == 0 ? "女" : "男",
                    DEPARTMENTS[(i - 1) / 10 % DEPARTMENTS.length], i % 7 == 0 ? "组长" : "操作工", LocalDate.of(2020, 1, 1).plusDays(i),
                    idNumber(first17), 13800000000L + i));
        }
        return people;
    }

    /** GB 11643 check digit appended to 17 digits. */
    static String idNumber(String first17) {
        int[] weights = {7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2};
        int sum = 0;
        for (int i = 0; i < 17; i++) sum += (first17.charAt(i) - '0') * weights[i];
        return first17 + "10X98765432".charAt(sum % 11);
    }

    /**
     * A roster as HR keeps it: a merged title row, a date line, the header, one row per person with the
     * department merged down each group, and a total line that is not a person.
     */
    static byte[] roster(boolean xls, int count, boolean withTitle) throws IOException {
        try (Workbook book = xls ? new HSSFWorkbook() : new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            Sheet sheet = book.createSheet("花名册");
            var dateStyle = book.createCellStyle();
            dateStyle.setDataFormat(book.getCreationHelper().createDataFormat().getFormat("yyyy-mm-dd"));
            int r = 0;
            if (withTitle) {
                sheet.createRow(r++).createCell(0).setCellValue(ROSTER_TITLE);
                sheet.addMergedRegion(new CellRangeAddress(0, 0, 0, ROSTER_HEADER.size() - 1));
                sheet.createRow(r++).createCell(0).setCellValue("制表日期：2026-10-01");
            }
            Row header = sheet.createRow(r++);
            for (int c = 0; c < ROSTER_HEADER.size(); c++) header.createCell(c).setCellValue(ROSTER_HEADER.get(c));
            int groupStart = r;
            List<Person> people = people(count);
            for (int i = 0; i < people.size(); i++) {
                Person person = people.get(i);
                Row row = sheet.createRow(r);
                row.createCell(0).setCellValue(i + 1);
                row.createCell(1).setCellValue(person.name());
                row.createCell(2).setCellValue(person.gender());
                if (i % 10 == 0) row.createCell(3).setCellValue(person.department());
                row.createCell(4).setCellValue(person.position());
                var hired = row.createCell(5);
                hired.setCellValue(person.hired());
                hired.setCellStyle(dateStyle);
                row.createCell(6).setCellValue(person.idNumber());
                row.createCell(7).setCellValue(person.phone());
                if (i % 10 == 9 || i == people.size() - 1) {
                    if (r > groupStart) sheet.addMergedRegion(new CellRangeAddress(groupStart, r, 3, 3));
                    groupStart = r + 1;
                }
                r++;
            }
            Row total = sheet.createRow(r);
            total.createCell(0).setCellValue("合计");
            total.createCell(1).setCellValue("共" + count + "人");
            book.write(out);
            return out.toByteArray();
        }
    }

    /** A plain one-sheet table: String cells are text, Number cells numeric, LocalDate cells dates. */
    static byte[] table(boolean xls, String sheetName, List<List<Object>> rows) throws IOException {
        try (Workbook book = xls ? new HSSFWorkbook() : new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            Sheet sheet = book.createSheet(sheetName);
            var dateStyle = book.createCellStyle();
            dateStyle.setDataFormat(book.getCreationHelper().createDataFormat().getFormat("yyyy-mm-dd"));
            for (int r = 0; r < rows.size(); r++) {
                Row row = sheet.createRow(r);
                for (int c = 0; c < rows.get(r).size(); c++) {
                    Object value = rows.get(r).get(c);
                    if (value == null) continue;
                    var cell = row.createCell(c);
                    if (value instanceof Number number) cell.setCellValue(number.doubleValue());
                    else if (value instanceof LocalDate date) { cell.setCellValue(date); cell.setCellStyle(dateStyle); }
                    else cell.setCellValue(value.toString());
                }
            }
            book.write(out);
            return out.toByteArray();
        }
    }

    /** Every fabricated personal value of a roster (names, ID numbers, phones) plus its title and departments. */
    static List<String> rosterValues(int count) {
        List<String> values = new ArrayList<>(List.of(ROSTER_TITLE));
        for (Person person : people(count)) {
            values.add(person.name());
            values.add(person.idNumber());
            values.add(person.idNumber().substring(0, 15));
            values.add(Long.toString(person.phone()));
            values.add(person.department());
        }
        return values;
    }
}
