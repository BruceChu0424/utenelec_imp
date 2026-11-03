using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>Shared date-only range dialog. Choosing a visible month never commits filters.</summary>
    public sealed class UtenDateRangeDialog : UtenDialogWindow
    {
        private readonly DateTime firstDate, lastDate;
        private readonly Button previous = new Button(), monthTitle = new Button(), next = new Button();
        private readonly StackPanel calendar = new StackPanel();
        private readonly TextBlock selection = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        private readonly CheckBox unlimitedStart = new CheckBox { Content = "不限开始" }, unlimitedEnd = new CheckBox { Content = "不限结束" };
        private readonly Button confirm;
        private DateTime displayedMonth;
        private DateTime? start, end;
        private bool choosingMonth;

        public DateTime? SelectedStart { get; private set; }
        public DateTime? SelectedEnd { get; private set; }
        public bool Applied { get; private set; }

        public UtenDateRangeDialog(Window owner, DateTime? initialStart = null, DateTime? initialEnd = null,
            DateTime? firstDate = null, DateTime? lastDate = null) : base(owner, "选择日期", 520)
        {
            this.firstDate = (firstDate ?? DateTime.MinValue).Date;
            this.lastDate = (lastDate ?? DateTime.MaxValue).Date;
            if (this.lastDate < this.firstDate) throw new ArgumentException("Invalid date bounds.");
            start = initialStart?.Date; end = initialEnd?.Date;
            if (start.HasValue && !InBounds(start.Value) || end.HasValue && !InBounds(end.Value)
                || start.HasValue && end.HasValue && end < start) throw new ArgumentException("Invalid initial range.");
            unlimitedStart.IsChecked = !start.HasValue && end.HasValue;
            unlimitedEnd.IsChecked = start.HasValue && !end.HasValue;
            var anchor = start ?? end ?? ChinaToday;
            if (anchor < this.firstDate) anchor = this.firstDate;
            if (anchor > this.lastDate) anchor = this.lastDate;
            displayedMonth = new DateTime(anchor.Year, anchor.Month, 1);
            var nav = new Grid { Margin = new Thickness(0, 0, 0, Space("S8")) };
            nav.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            nav.ColumnDefinitions.Add(new ColumnDefinition());
            nav.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            previous.Content = "‹"; previous.ToolTip = "上个月";
            next.Content = "›"; next.ToolTip = "下个月";
            monthTitle.ToolTip = "选择年份和月份";
            foreach (var button in new[] { previous, monthTitle, next }) button.BorderThickness = new Thickness(0);
            Grid.SetColumn(monthTitle, 1); Grid.SetColumn(next, 2);
            nav.Children.Add(previous); nav.Children.Add(monthTitle); nav.Children.Add(next); Body.Children.Add(nav);
            previous.Click += (sender, args) => { if (previous.IsEnabled) { displayedMonth = displayedMonth.AddMonths(-1); Render(); } };
            next.Click += (sender, args) => { if (next.IsEnabled) { displayedMonth = displayedMonth.AddMonths(1); Render(); } };
            monthTitle.Click += (sender, args) => { choosingMonth = !choosingMonth; Render(); };
            Body.Children.Add(calendar);
            var summary = new WrapPanel { Margin = new Thickness(0, Space("S8"), 0, 0) };
            summary.Children.Add(selection); Body.Children.Add(summary);
            var openBounds = new WrapPanel { Margin = new Thickness(0, Space("S8"), 0, 0) };
            unlimitedStart.Margin = new Thickness(0, 0, Space("S16"), 0);
            openBounds.Children.Add(unlimitedStart); openBounds.Children.Add(unlimitedEnd); Body.Children.Add(openBounds);
            unlimitedStart.Click += (sender, args) => UpdateSelection();
            unlimitedEnd.Click += (sender, args) => UpdateSelection();
            ActionButton("清除日期", () => { Applied = true; SelectedStart = SelectedEnd = null; Close(); });
            ActionButton("取消", Close);
            confirm = ActionButton("确定", () =>
            {
                if (!CanConfirm()) return;
                Applied = true;
                SelectedStart = unlimitedStart.IsChecked == true ? null : start;
                SelectedEnd = unlimitedEnd.IsChecked == true ? null : (end ?? start);
                Close();
            }, true);
            Render();
        }

        public static DateTime ChinaToday { get { return DateTimeOffset.UtcNow.ToOffset(TimeSpan.FromHours(8)).Date; } }
        public static DateTime RecentMonthStart(DateTime wallToday) { return wallToday.Date.AddMonths(-1); }
        private bool InBounds(DateTime day) { return day >= firstDate && day <= lastDate; }
        private bool CanConfirm()
        {
            var effectiveStart = unlimitedStart.IsChecked == true ? null : start;
            var effectiveEnd = unlimitedEnd.IsChecked == true ? null : (end ?? start);
            return (start.HasValue || unlimitedStart.IsChecked == true)
                && (end.HasValue || start.HasValue || unlimitedEnd.IsChecked == true)
                && (!effectiveStart.HasValue || !effectiveEnd.HasValue || effectiveEnd.Value >= effectiveStart.Value);
        }
        private void UpdateSelection()
        {
            string left = unlimitedStart.IsChecked == true ? "不限" : start?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) ?? "开始日期";
            string right = unlimitedEnd.IsChecked == true ? "不限" : (end ?? start)?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) ?? "结束日期";
            selection.Text = left + " 至 " + right;
            if (confirm != null) confirm.IsEnabled = CanConfirm();
        }
        private void SelectDay(DateTime day)
        {
            if (!start.HasValue || end.HasValue) { start = day; end = null; }
            else if (day < start.Value) start = day;
            else end = day;
            Render();
        }
        private Button Cell(string text, Action click, bool selected = false, bool enabled = true)
        {
            var button = new Button { Content = text, IsEnabled = enabled, MinHeight = 40,
                Padding = new Thickness(Space("S4")), Margin = new Thickness(1), BorderThickness = new Thickness(0) };
            if (selected) button.SetResourceReference(StyleProperty, "Uten.PrimaryButton");
            button.Click += (sender, args) => click();
            return button;
        }
        private void Render()
        {
            calendar.Children.Clear();
            monthTitle.Content = displayedMonth.ToString("yyyy年M月", CultureInfo.InvariantCulture) + " ▾";
            previous.IsEnabled = !choosingMonth && displayedMonth > new DateTime(firstDate.Year, firstDate.Month, 1);
            next.IsEnabled = !choosingMonth && displayedMonth < new DateTime(lastDate.Year, lastDate.Month, 1);
            if (choosingMonth) RenderMonths(); else RenderDays();
            UpdateSelection();
        }
        private void RenderMonths()
        {
            var year = new ComboBox { ItemsSource = Enumerable.Range(firstDate.Year, lastDate.Year - firstDate.Year + 1),
                SelectedItem = displayedMonth.Year, MinWidth = 120, Margin = new Thickness(0, 0, 0, Space("S8")) };
            year.SetValue(VirtualizingPanel.IsVirtualizingProperty, true);
            year.SetValue(VirtualizingPanel.VirtualizationModeProperty, VirtualizationMode.Recycling);
            year.ItemsPanel = new ItemsPanelTemplate(new FrameworkElementFactory(typeof(VirtualizingStackPanel)));
            System.Windows.Automation.AutomationProperties.SetName(year, "年份");
            year.SelectionChanged += (sender, args) =>
            {
                if (!(year.SelectedItem is int)) return;
                displayedMonth = new DateTime((int)year.SelectedItem, displayedMonth.Month, 1);
                var lowerMonth = new DateTime(firstDate.Year, firstDate.Month, 1);
                var upperMonth = new DateTime(lastDate.Year, lastDate.Month, 1);
                if (displayedMonth < lowerMonth) displayedMonth = lowerMonth;
                if (displayedMonth > upperMonth) displayedMonth = upperMonth;
                monthTitle.Content = displayedMonth.ToString("yyyy年M月", CultureInfo.InvariantCulture) + " ▾";
                RenderMonthGrid();
            };
            calendar.Children.Add(year); RenderMonthGrid();
        }
        private void RenderMonthGrid()
        {
            if (calendar.Children.Count > 1) calendar.Children.RemoveAt(1);
            var months = new UniformGrid { Columns = 3, Rows = 4, Height = 240 };
            for (int index = 1; index <= 12; index++)
            {
                int month = index;
                bool enabled = new DateTime(displayedMonth.Year, month, 1) <= lastDate
                    && new DateTime(displayedMonth.Year, month, DateTime.DaysInMonth(displayedMonth.Year, month)) >= firstDate;
                months.Children.Add(Cell(month.ToString(CultureInfo.InvariantCulture) + "月", () =>
                { displayedMonth = new DateTime(displayedMonth.Year, month, 1); choosingMonth = false; Render(); },
                    month == displayedMonth.Month, enabled));
            }
            calendar.Children.Add(months);
        }
        private void RenderDays()
        {
            var days = new UniformGrid { Columns = 7, Rows = 7, Height = 280 };
            foreach (var label in new[] { "一", "二", "三", "四", "五", "六", "日" })
                days.Children.Add(new TextBlock { Text = label, HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center });
            int blanks = ((int)displayedMonth.DayOfWeek + 6) % 7;
            for (int index = 0; index < 42; index++)
            {
                int number = index + 1 - blanks;
                if (number < 1 || number > DateTime.DaysInMonth(displayedMonth.Year, displayedMonth.Month))
                { days.Children.Add(new Border()); continue; }
                var day = new DateTime(displayedMonth.Year, displayedMonth.Month, number);
                var button = Cell(number.ToString(CultureInfo.InvariantCulture), () => SelectDay(day), start == day || end == day, InBounds(day));
                System.Windows.Automation.AutomationProperties.SetName(button, day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
                if (start.HasValue && end.HasValue && day > start && day < end)
                    button.SetResourceReference(BackgroundProperty, "Uten.PrimaryLight");
                days.Children.Add(button);
            }
            calendar.Children.Add(days);
        }
    }
}
