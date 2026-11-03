using System;
using System.IO;
using System.Collections.Generic;
using System.Globalization;
using System.Web.Script.Serialization;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Shared
{
    public static class DateRangeDialogChecks
    {
        public static int Run()
        {
            if (Application.Current == null) { var app = new App(); app.InitializeComponent(); app.ShutdownMode = ShutdownMode.OnExplicitShutdown; }
            int count = 0;
            Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Date range: " + label); count++; };
            using (var input = typeof(DateRangeDialogChecks).Assembly.GetManifestResourceStream("Uten.DateRangeSelectionFixture.json"))
            using (var reader = new StreamReader(input))
            {
                var fixture = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd());
                foreach (Dictionary<string, object> sample in (object[])fixture["recentMonthCases"])
                {
                    var today = DateTime.ParseExact((string)sample["today"], "yyyy-MM-dd", CultureInfo.InvariantCulture).AddHours(23);
                    var first = DateTime.ParseExact((string)sample["start"], "yyyy-MM-dd", CultureInfo.InvariantCulture);
                    var last = DateTime.ParseExact((string)sample["end"], "yyyy-MM-dd", CultureInfo.InvariantCulture);
                    check(UtenDateRangeDialog.RecentMonthStart(today) == first && today.Date == last, "shared recent month fixture covers month-end, leap-year and year boundary");
                }
            }
            var dialog = new UtenDateRangeDialog(null, new DateTime(2026, 3, 1), new DateTime(2026, 3, 4), new DateTime(1900, 2, 10), new DateTime(2100, 10, 15));
            try
            {
                Click(Field<Button>(dialog, "monthTitle"));
                var calendar = Field<StackPanel>(dialog, "calendar");
                var year = (ComboBox)calendar.Children[0];
                check(year.Items.Count == 201, "all bounded years can be selected directly");
                year.SelectedItem = 1900;
                Click(Buttons(calendar).Single(button => Equals(button.Content, "2月")));
                check(Equals(Field<Button>(dialog, "monthTitle").Content, "1900年2月 ▾"), "year and month jump directly to selected month");
                check(!Field<Button>(dialog, "previous").IsEnabled, "lower month bound disables previous");
                check(!Buttons(calendar).Single(button => Equals(button.Content, "9")).IsEnabled, "date before lower bound disabled");
                Click(Buttons(calendar).Single(button => Equals(button.Content, "10")));
                Click(Buttons(calendar).Single(button => Equals(button.Content, "11")));
                Click(Field<Button>(dialog, "monthTitle"));
                ((ComboBox)calendar.Children[0]).SelectedItem = 2100;
                check(!Buttons(calendar).Single(button => Equals(button.Content, "11月")).IsEnabled, "out of bounds month disabled");
                Click(Buttons(calendar).Single(button => Equals(button.Content, "10月")));
                check(!Field<Button>(dialog, "next").IsEnabled, "upper month bound disables next");
                Click(Field<Button>(dialog, "confirm"));
                check(dialog.Applied && dialog.SelectedStart == new DateTime(1900, 2, 10) && dialog.SelectedEnd == new DateTime(1900, 2, 11), "browsing years preserves pending range until confirm");
            }
            finally { dialog.Close(); }
            var cancel = new UtenDateRangeDialog(null, new DateTime(2026, 1, 1), new DateTime(2026, 1, 8));
            Click(Field<Button>(cancel, "monthTitle")); cancel.Close();
            check(!cancel.Applied && !cancel.SelectedStart.HasValue && !cancel.SelectedEnd.HasValue, "cancel leaves caller range untouched");
            var single = new UtenDateRangeDialog(null, firstDate: new DateTime(2026, 1, 1), lastDate: new DateTime(2026, 1, 31));
            Click(Buttons(Field<StackPanel>(single, "calendar")).Single(button => Equals(button.Content, "15")));
            Click(Field<Button>(single, "confirm"));
            check(single.Applied && single.SelectedStart == single.SelectedEnd && single.SelectedStart == new DateTime(2026, 1, 15), "one day confirms a single-day range");
            var open = new UtenDateRangeDialog(null, new DateTime(2026, 1, 1), null);
            Click(Field<Button>(open, "confirm"));
            check(open.Applied && open.SelectedStart == new DateTime(2026, 1, 1) && !open.SelectedEnd.HasValue, "open end preserved");
            var clear = new UtenDateRangeDialog(null, null, new DateTime(2026, 1, 2));
            Click(Buttons((DependencyObject)clear.Content).Single(button => Equals(button.Content, "清除日期")));
            check(clear.Applied && !clear.SelectedStart.HasValue && !clear.SelectedEnd.HasValue, "explicit clear returns unbounded range");
            for (int cycle = 0; cycle < 20; cycle++)
            {
                var repeated = new UtenDateRangeDialog(null, new DateTime(2026, 11, 1), new DateTime(2026, 11, 2));
                for (int step = 0; step < 20; step++) { Click(Field<Button>(repeated, "monthTitle")); Click(Field<Button>(repeated, "monthTitle")); }
                repeated.Close();
                check(!repeated.Applied, "rapid toggle and close never publishes range");
            }
            var preview = new UtenDateRangeDialog(null, new DateTime(2026, 3, 1), new DateTime(2026, 3, 12));
            try
            {
                Snapshot(preview, "date-range-days.png");
                Click(Field<Button>(preview, "monthTitle"));
                Snapshot(preview, "date-range-year-month.png");
                preview.Width = 320;
                Snapshot(preview, "date-range-narrow.png");
                check(((FrameworkElement)preview.Content).DesiredSize.Width <= 320, "narrow date picker fits its viewport");
            }
            finally { preview.Close(); }
            return count;
        }
        internal static void CompleteRange(UtenDateRangeDialog dialog, int yearNumber, int monthNumber, int startDay, int endDay)
        {
            Click(Field<Button>(dialog, "monthTitle"));
            var calendar = Field<StackPanel>(dialog, "calendar");
            ((ComboBox)calendar.Children[0]).SelectedItem = yearNumber;
            Click(Buttons(calendar).Single(button => Equals(button.Content, monthNumber.ToString(System.Globalization.CultureInfo.InvariantCulture) + "月")));
            Click(Buttons(calendar).Single(button => Equals(button.Content, startDay.ToString(System.Globalization.CultureInfo.InvariantCulture))));
            Click(Buttons(calendar).Single(button => Equals(button.Content, endDay.ToString(System.Globalization.CultureInfo.InvariantCulture))));
            Click(Field<Button>(dialog, "confirm"));
        }
        private static void Click(Button button) { button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); }
        private static T Field<T>(object target, string name) where T : class { return (T)target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(target); }
        private static System.Collections.Generic.IEnumerable<Button> Buttons(DependencyObject parent)
        {
            var button = parent as Button; if (button != null) yield return button;
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
                foreach (var child in Buttons(VisualTreeHelper.GetChild(parent, index))) yield return child;
            // Unmeasured fixture panels have no generated visual descendants yet.
            if (parent is Panel && VisualTreeHelper.GetChildrenCount(parent) == 0)
                foreach (UIElement child in ((Panel)parent).Children) foreach (var nested in Buttons(child)) yield return nested;
        }
        private static void Snapshot(Window window, string name)
        {
            var content = (FrameworkElement)window.Content;
            content.Measure(new Size(window.Width, Double.PositiveInfinity));
            content.Arrange(new Rect(0, 0, window.Width, content.DesiredSize.Height)); content.UpdateLayout();
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(content); var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
            using (var file = File.Create(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, name))) png.Save(file);
        }
    }
}
