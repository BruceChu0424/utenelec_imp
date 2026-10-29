using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Shared
{
    public interface INativePrintDestination
    {
        bool Choose(int pages);
        void Submit(DocumentPaginator paginator, string title);
    }

    public static class NativePrintGate
    {
        /// <returns>True means sent to the OS queue, never proof that paper was delivered.</returns>
        public static bool Submit(DocumentPaginator document, string title, Func<bool> current, INativePrintDestination destination)
        {
            if (document == null || destination == null || current == null) throw new ArgumentException();
            Require(current);
            if (!destination.Choose(document.PageCount)) return false;
            Require(current);
            destination.Submit(document, title);
            return true;
        }
        private static void Require(Func<bool> current)
        { if (!current()) throw new ApiException("READ_SCOPE_CHANGED", "打印预览已失效，未提交到打印队列。"); }
    }

    public sealed class NativeWpfPrintDestination : INativePrintDestination
    {
        private PrintDialog dialog;
        public bool Choose(int pages)
        {
            dialog = new PrintDialog { UserPageRangeEnabled = true, MinPage = 1, MaxPage = checked((uint)Math.Max(1, pages)) };
            return dialog.ShowDialog() == true;
        }
        public void Submit(DocumentPaginator paginator, string title)
        {
            if (dialog == null) throw new InvalidOperationException("Choose a printer first.");
            int first = 0, count = paginator.PageCount;
            if (dialog.PageRangeSelection == PageRangeSelection.UserPages)
            {
                first = dialog.PageRange.PageFrom - 1;
                int last = dialog.PageRange.PageTo;
                if (first < 0 || last <= first || last > paginator.PageCount) throw new ArgumentOutOfRangeException("PageRange");
                count = last - first;
            }
            var size = new Size(dialog.PrintableAreaWidth, dialog.PrintableAreaHeight);
            if (Double.IsNaN(size.Width) || Double.IsNaN(size.Height) || Double.IsInfinity(size.Width)
                || Double.IsInfinity(size.Height) || size.Width <= 0 || size.Height <= 0)
                throw new InvalidOperationException("The printer did not report a printable paper area.");
            dialog.PrintDocument(new SelectedPagesPaginator(paginator, first, count, size), title);
        }
    }

    /// <summary>Keep canonical A4 content and the user's printer/page selection.
    /// Scaling to the imageable area cannot cut the last row or silently omit selected pages.</summary>
    public sealed class SelectedPagesPaginator : DocumentPaginator
    {
        private readonly DocumentPaginator source;
        private readonly int first, count;
        private readonly Size target;
        public SelectedPagesPaginator(DocumentPaginator source, int first, int count, Size target)
        {
            if (source == null || first < 0 || count < 1 || first > source.PageCount - count
                || Double.IsNaN(target.Width) || Double.IsNaN(target.Height) || Double.IsInfinity(target.Width)
                || Double.IsInfinity(target.Height) || target.Width <= 0 || target.Height <= 0) throw new ArgumentException();
            this.source = source; this.first = first; this.count = count; this.target = target;
        }
        public override DocumentPage GetPage(int pageNumber)
        {
            if (pageNumber < 0 || pageNumber >= count) return DocumentPage.Missing;
            var original = source.GetPage(first + pageNumber);
            if (original == DocumentPage.Missing) throw new InvalidOperationException("A selected print page is missing.");
            double scale = Math.Min(target.Width / original.Size.Width, target.Height / original.Size.Height);
            var size = new Size(original.Size.Width * scale, original.Size.Height * scale);
            var visual = new DrawingVisual();
            using (var drawing = visual.RenderOpen())
                drawing.DrawRectangle(new VisualBrush(original.Visual), null,
                    new Rect((target.Width - size.Width) / 2, (target.Height - size.Height) / 2, size.Width, size.Height));
            return new DocumentPage(visual, target, new Rect(target), new Rect(target));
        }
        public override bool IsPageCountValid { get { return source.IsPageCountValid; } }
        public override int PageCount { get { var ignored = source.PageCount; return count; } }
        public override Size PageSize { get { return target; } set { } }
        public override IDocumentPaginatorSource Source { get { return source.Source; } }
    }
}
