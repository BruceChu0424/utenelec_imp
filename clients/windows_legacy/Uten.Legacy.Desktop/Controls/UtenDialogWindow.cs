using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>Shared dialog chrome. Radius, spacing, typography and caption targets
    /// use owning Uten tokens; business state stays in the caller.</summary>
    public class UtenDialogWindow : Window
    {
        private readonly NativeWindowFrame frame = new NativeWindowFrame();
        protected StackPanel Body { get; private set; }
        protected StackPanel Actions { get; private set; }
        protected TextBlock StatusLabel { get; private set; }
        protected Button CloseButton { get; private set; }

        public UtenDialogWindow(Window owner, string title, double width = 560)
        {
            SetResourceReference(StyleProperty, typeof(Window));
            if (owner != null) Owner = owner;
            Title = title;
            Width = Math.Min(width, SystemParameters.WorkArea.Width);
            MaxHeight = SystemParameters.WorkArea.Height;
            SizeToContent = SizeToContent.Height;
            WindowStartupLocation = owner == null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
            WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false;
            var layout = new StackPanel { Margin = (Thickness)FindResource("Uten.Padding.S24") };
            var header = new DockPanel();
            CloseButton = new Button { Content = "×", IsCancel = true, Style = (Style)FindResource("Uten.CaptionButton"),
                Background = (Brush)FindResource("Uten.Caption.Close"), ToolTip = "关闭" };
            CloseButton.Click += (sender, args) => Close();
            DockPanel.SetDock(CloseButton, Dock.Right); header.Children.Add(CloseButton);
            var heading = new TextBlock { Text = title, Style = (Style)FindResource("Uten.PageTitle"),
                VerticalAlignment = VerticalAlignment.Center };
            heading.MouseLeftButtonDown += (sender, args) =>
            {
                if (args.ChangedButton == MouseButton.Left && args.LeftButton == MouseButtonState.Pressed) DragMove();
            };
            header.Children.Add(heading); layout.Children.Add(header);
            Body = new StackPanel { Margin = new Thickness(0, Space("S16"), 0, 0) };
            layout.Children.Add(new ScrollViewer { Content = Body, MaxHeight = Math.Max(120, SystemParameters.WorkArea.Height - 230),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
            StatusLabel = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed,
                Margin = new Thickness(0, Space("S12"), 0, 0) };
            System.Windows.Automation.AutomationProperties.SetName(StatusLabel, "操作结果");
            layout.Children.Add(StatusLabel);
            Actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, Space("S24"), 0, 0) };
            layout.Children.Add(Actions);
            Content = UtenSurfaces.Wrap(layout, UtenSurfaceRole.Dialog);
            SourceInitialized += (sender, args) => UpdateFrame(); SizeChanged += (sender, args) => UpdateFrame();
        }
        protected double Space(string role) { return (double)FindResource("Uten.Space." + role); }
        protected void ShowStatus(string text, bool error = false)
        {
            StatusLabel.Text = text ?? "";
            StatusLabel.Visibility = String.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
            StatusLabel.SetResourceReference(TextBlock.ForegroundProperty, error ? "Uten.Error" : "Uten.Muted");
        }
        protected Button ActionButton(string text, Action action, bool primary = false)
        {
            var button = new Button { Content = text, Margin = new Thickness(Space("S8"), 0, 0, 0) };
            if (primary) button.SetResourceReference(StyleProperty, "Uten.PrimaryButton");
            button.Click += (sender, args) => action(); Actions.Children.Add(button); return button;
        }
        private void UpdateFrame() { frame.Update(this, true, (double)FindResource("Uten.Radius.DialogValue")); }
    }
}
