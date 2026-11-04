using System;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>Calendar wall-date presentation only; query bounds stay owned by the caller.</summary>
    public static class UtenDateRangePresentation
    {
        private static string Date(DateTime value) { return value.ToString("yyyy.MM.dd", CultureInfo.InvariantCulture); }

        public static string Label(DateTime? start, DateTime? end, DateTime today)
        {
            if (!start.HasValue) return end.HasValue ? "截至" + Date(end.Value) : "选择日期";
            if (!end.HasValue) return Date(start.Value) + "起";
            int days = (end.Value.Date - start.Value.Date).Days + 1;
            if (days < 1) throw new ArgumentException("Invalid date range.");
            if (end.Value.Date == today.Date)
            {
                if (days == 1) return "今天";
                if (start.Value.Date == UtenDateRangeDialog.RecentMonthStart(today)) return "近1个月";
                return "近" + days.ToString(CultureInfo.InvariantCulture) + "天";
            }
            return "共" + days.ToString(CultureInfo.InvariantCulture) + "天";
        }

        public static string Tooltip(DateTime? start, DateTime? end)
        {
            if (start.HasValue && end.HasValue) return Date(start.Value) + "-" + Date(end.Value);
            if (start.HasValue) return Date(start.Value) + "起";
            if (end.HasValue) return "截至" + Date(end.Value);
            return "全部日期";
        }
    }

    /// <summary>A normal-height text button with immediate mouse and keyboard disclosure.</summary>
    public sealed class UtenDateRangeButton : Button
    {
        private readonly ToolTip disclosure = new ToolTip { Placement = PlacementMode.Bottom };

        public UtenDateRangeButton()
        {
            SetResourceReference(StyleProperty, typeof(Button));
            disclosure.PlacementTarget = this;
            ToolTip = disclosure;
            ToolTipService.SetInitialShowDelay(this, 0);
            ToolTipService.SetBetweenShowDelay(this, 0);
            ToolTipService.SetShowDuration(this, 10000);
            SetRange(null, null);
        }

        public void SetRange(DateTime? start, DateTime? end, DateTime? today = null)
        {
            string label = UtenDateRangePresentation.Label(start, end, today ?? UtenDateRangeDialog.ChinaToday);
            string fullRange = UtenDateRangePresentation.Tooltip(start, end);
            Content = label;
            disclosure.Content = fullRange;
            AutomationProperties.SetName(this, "选择日期，" + label);
            AutomationProperties.SetHelpText(this, fullRange);
        }

        protected override void OnGotKeyboardFocus(KeyboardFocusChangedEventArgs args)
        {
            base.OnGotKeyboardFocus(args);
            if (IsLoaded && IsKeyboardFocused) disclosure.IsOpen = true;
        }

        protected override void OnLostKeyboardFocus(KeyboardFocusChangedEventArgs args)
        {
            disclosure.IsOpen = false;
            base.OnLostKeyboardFocus(args);
        }

        protected override void OnClick()
        {
            disclosure.IsOpen = false;
            base.OnClick();
        }
    }
}
