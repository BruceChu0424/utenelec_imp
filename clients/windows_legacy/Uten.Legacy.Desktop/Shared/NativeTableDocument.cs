using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Threading;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Shared
{
    /// <summary>Authorized display strings only. A4 landscape / 28pt margins / 16pt title /
    /// 9pt subtitle / 8pt table / 4x3pt cell padding follow print_pdf_document.dart.
    /// No business arithmetic, repository, credentials or installed-font dependency.</summary>
    public sealed class NativeTableDocument : DocumentPaginator
    {
        private sealed class PageSlice { internal int Start, End; internal bool Header; }
        private const double Pt = 96d / 72d, Margin = 28 * Pt, CellX = 4 * Pt, CellY = 3 * Pt;
        private static readonly Size Paper = new Size(297d / 25.4d * 96, 210d / 25.4d * 96);
        private readonly string title, subtitle;
        private readonly IReadOnlyList<string> headers;
        private readonly IReadOnlyList<IReadOnlyList<string>> rows;
        private readonly double[] widths, heights;
        private readonly List<PageSlice> pages = new List<PageSlice>();
        private readonly Func<bool> current;
        private readonly FontFamily font;
        private readonly double headerHeight, introHeight;
        private readonly CancellationToken lifetime;
        public int RowCount { get { return rows.Count; } }
        public static FontFamily FullChineseFont()
        {
            return new FontFamily(new Uri("pack://application:,,,/Uten.Legacy.Desktop;component/", UriKind.Absolute),
                "./PrintAssets/#Noto Sans SC");
        }
        private NativeTableDocument(string title, string subtitle, IReadOnlyList<string> headers,
            IReadOnlyList<IReadOnlyList<string>> rows, double[] widths, Func<bool> current, CancellationToken lifetime)
        {
            this.title = title; this.subtitle = subtitle; this.headers = headers; this.rows = rows;
            this.widths = widths; this.current = current; this.lifetime = lifetime;
            heights = new double[rows.Count]; font = FullChineseFont();
            headerHeight = MeasureRow(headers, true);
            introHeight = MeasureText(title, Paper.Width - 2 * Margin, 16 * Pt, true)
                + (String.IsNullOrEmpty(subtitle) ? 0 : 4 * Pt + MeasureText(subtitle, Paper.Width - 2 * Margin, 9 * Pt, false)) + 10 * Pt;
        }
        public static async Task<NativeTableDocument> CreateAsync(string title, string subtitle,
            IReadOnlyList<string> headers, IReadOnlyList<IReadOnlyList<string>> rows,
            IReadOnlyList<double> relativeWidths, Func<bool> isCurrent, CancellationToken token)
        {
            if (String.IsNullOrEmpty(title) || headers == null || rows == null || headers.Count < 1 || headers.Count > 160
                || relativeWidths == null || relativeWidths.Count != headers.Count || isCurrent == null) throw new ArgumentException();
            if (rows.Count > 100000) throw new ApiException("PRINT_TOO_LARGE", "打印记录过多，请缩小筛选范围。");
            var copiedRows = new List<IReadOnlyList<string>>(rows.Count); long textBytes = 0;
            for (int index = 0; index < rows.Count; index++)
            {
                token.ThrowIfCancellationRequested();
                if (!isCurrent()) throw Retired();
                if (rows[index] == null || rows[index].Count != headers.Count) throw new FormatException("打印数据列数不一致。");
                var row = new string[headers.Count];
                for (int col = 0; col < row.Length; col++)
                {
                    row[col] = rows[index][col] ?? "";
                    textBytes += (long)row[col].Length * 2;
                    if (textBytes > 64L * 1024 * 1024) throw new ApiException("PRINT_TOO_LARGE", "打印文字过多，请缩小筛选范围。");
                }
                copiedRows.Add(Array.AsReadOnly(row));
                if (index % 40 == 0) await Dispatcher.Yield(DispatcherPriority.Background);
            }
            var weights = relativeWidths.ToArray();
            if (weights.Any(value => Double.IsNaN(value) || Double.IsInfinity(value) || value <= 0)) throw new ArgumentException("打印列宽无效。");
            double sum = weights.Sum(), available = Paper.Width - 2 * Margin;
            if (Double.IsInfinity(sum)) throw new ArgumentException("打印列宽无效。");
            var widths = weights.Select(value => available * value / sum).ToArray();
            if (widths.Any(value => value <= CellX * 2 + 1)) throw new FormatException("打印列过窄，请减少列数或调整宽度。");
            var document = new NativeTableDocument(title, subtitle, Array.AsReadOnly(headers.Select(value => value ?? "").ToArray()),
                new ReadOnlyCollection<IReadOnlyList<string>>(copiedRows), widths, isCurrent, token);
            await document.PaginateAsync();
            return document;
        }
        private async Task PaginateAsync()
        {
            Check();
            double usable = Paper.Height - 2 * Margin;
            double left = usable - introHeight - headerHeight;
            if (left <= 0) throw new FormatException("打印标题或列标题过长，无法完整放入纸张。");
            var page = new PageSlice { Start = 0, Header = true };
            for (int row = 0; row < rows.Count; row++)
            {
                Check(); heights[row] = MeasureRow(rows[row], false);
                if (heights[row] > usable) throw new FormatException("单行内容过长，无法在当前纸张完整打印，请缩小文字内容或调整列投影。");
                if (heights[row] > left)
                {
                    page.End = row; pages.Add(page); page = new PageSlice { Start = row }; left = usable;
                }
                left -= heights[row];
                if (row % 30 == 0) await Dispatcher.Yield(DispatcherPriority.Background);
            }
            page.End = rows.Count; pages.Add(page); Check();
        }
        private TextBlock Text(string text, double size, bool bold = false)
        {
            return new TextBlock { Text = text ?? "", FontFamily = font, FontSize = size, Foreground = Brushes.Black,
                FontWeight = bold ? FontWeights.Bold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap,
                TextTrimming = TextTrimming.None };
        }
        private double MeasureText(string text, double width, double size, bool bold)
        { var value = Text(text, size, bold); value.Measure(new Size(width, Double.PositiveInfinity)); return value.DesiredSize.Height; }
        private double MeasureRow(IReadOnlyList<string> cells, bool header)
        {
            double height = 0;
            for (int column = 0; column < cells.Count; column++)
                height = Math.Max(height, MeasureText(cells[column], widths[column] - 2 * CellX - Pt, 8 * Pt, header));
            return height + 2 * CellY + Pt;
        }
        public override DocumentPage GetPage(int pageNumber)
        {
            Check();
            if (pageNumber < 0 || pageNumber >= pages.Count) return DocumentPage.Missing;
            var page = pages[pageNumber];
            var canvas = new Canvas { Width = Paper.Width, Height = Paper.Height, Background = Brushes.White };
            double y = Margin;
            if (page.Header)
            {
                var caption = Text(title, 16 * Pt, true); caption.TextAlignment = TextAlignment.Center;
                caption.Width = Paper.Width - 2 * Margin; caption.Measure(new Size(caption.Width, Double.PositiveInfinity));
                Place(canvas, caption, Margin, y); y += caption.DesiredSize.Height;
                if (!String.IsNullOrEmpty(subtitle))
                {
                    y += 4 * Pt;
                    var sub = Text(subtitle, 9 * Pt); sub.TextAlignment = TextAlignment.Center; sub.Width = caption.Width;
                    sub.Measure(new Size(sub.Width, Double.PositiveInfinity)); Place(canvas, sub, Margin, y); y += sub.DesiredSize.Height;
                }
                y += 10 * Pt; DrawRow(canvas, headers, y, headerHeight, true, true); y += headerHeight;
            }
            for (int row = page.Start; row < page.End; row++)
            { Check(); DrawRow(canvas, rows[row], y, heights[row], false, row == page.Start && !page.Header); y += heights[row]; }
            canvas.Measure(Paper); canvas.Arrange(new Rect(Paper)); canvas.UpdateLayout(); Check();
            return new DocumentPage(canvas, Paper, new Rect(Paper), new Rect(Margin, Margin, Paper.Width - 2 * Margin, Paper.Height - 2 * Margin));
        }
        private void DrawRow(Canvas canvas, IReadOnlyList<string> cells, double y, double height, bool header, bool top)
        {
            double x = Margin;
            for (int column = 0; column < cells.Count; column++)
            {
                var content = Text(cells[column], 8 * Pt, header);
                content.TextAlignment = header ? TextAlignment.Center : TextAlignment.Left;
                var cell = new Border { Child = content, Width = widths[column], Height = height, Padding = new Thickness(CellX, CellY, CellX, CellY),
                    BorderBrush = Brushes.Black, BorderThickness = new Thickness(column == 0 ? .5 * Pt : 0, top ? .5 * Pt : 0, .5 * Pt, .5 * Pt),
                    Background = header ? new SolidColorBrush(Color.FromRgb(239, 239, 239)) : Brushes.White };
                Place(canvas, cell, x, y); x += widths[column];
            }
        }
        private static void Place(Canvas canvas, UIElement item, double x, double y)
        { Canvas.SetLeft(item, x); Canvas.SetTop(item, y); canvas.Children.Add(item); }
        private void Check() { lifetime.ThrowIfCancellationRequested(); if (!current()) throw Retired(); }
        private static ApiException Retired() { return new ApiException("READ_SCOPE_CHANGED", "打印预览已失效，请按当前账号和筛选重新打开。"); }
        public override bool IsPageCountValid { get { return true; } }
        public override int PageCount { get { Check(); return pages.Count; } }
        public override Size PageSize { get { return Paper; } set { /* Canonical A4 document; the print destination scales to its imageable paper. */ } }
        public override IDocumentPaginatorSource Source { get { return null; } }
    }
}
