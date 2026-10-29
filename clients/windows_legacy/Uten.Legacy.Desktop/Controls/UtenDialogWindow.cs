using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>Shared dialog chrome. Radius, spacing, typography and caption targets
    /// use owning Uten tokens; business state stays in the caller.</summary>
    public class UtenDialogWindow : Window, IPendingEditHost
    {
        private readonly NativeWindowFrame frame = new NativeWindowFrame();
        private readonly HashSet<Window> pendingChildren = new HashSet<Window>();
        private bool closeRequested;
        private bool dialogEnded;
        private readonly TextBlock heading;
        private readonly ScrollViewer bodyScroll;
        private readonly DockPanel header;
        protected StackPanel Body { get; private set; }
        protected WrapPanel Actions { get; private set; }
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
            header = new DockPanel();
            CloseButton = new Button { Content = "×", IsCancel = true, Style = (Style)FindResource("Uten.CaptionButton"),
                Background = (Brush)FindResource("Uten.Caption.Close"), ToolTip = "关闭" };
            CloseButton.Click += (sender, args) => Close();
            DockPanel.SetDock(CloseButton, Dock.Right); header.Children.Add(CloseButton);
            heading = new TextBlock { Text = title, Style = (Style)FindResource("Uten.PageTitle"),
                VerticalAlignment = VerticalAlignment.Center };
            heading.MouseLeftButtonDown += (sender, args) =>
            {
                if (args.ChangedButton == MouseButton.Left && args.LeftButton == MouseButtonState.Pressed) DragMove();
            };
            header.Children.Add(heading); layout.Children.Add(header);
            Body = new StackPanel { Margin = new Thickness(0, Space("S16"), 0, 0) };
            bodyScroll = new ScrollViewer { Content = Body, MaxHeight = Math.Max(120, SystemParameters.WorkArea.Height - 230),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
            layout.Children.Add(bodyScroll);
            StatusLabel = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed,
                Margin = new Thickness(0, Space("S12"), 0, 0) };
            System.Windows.Automation.AutomationProperties.SetName(StatusLabel, "操作结果");
            layout.Children.Add(StatusLabel);
            Actions = new WrapPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, Space("S16"), 0, 0) };
            layout.Children.Add(Actions);
            Content = UtenSurfaces.Wrap(layout, UtenSurfaceRole.Dialog);
            SourceInitialized += (sender, args) => UpdateFrame(); SizeChanged += (sender, args) => UpdateFrame();
            Actions.SizeChanged += (sender, args) => FitBodyViewport();
            StatusLabel.SizeChanged += (sender, args) => FitBodyViewport();
            Loaded += (sender, args) => FitBodyViewport();
        }
        protected double Space(string role) { return (double)FindResource("Uten.Space." + role); }
        protected void SetHeading(string text) { Title = heading.Text = text ?? ""; }
        protected void ShowStatus(string text, bool error = false)
        {
            StatusLabel.Text = text ?? "";
            StatusLabel.Visibility = String.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
            StatusLabel.SetResourceReference(TextBlock.ForegroundProperty, error ? "Uten.Error" : "Uten.Muted");
        }
        protected Button ActionButton(string text, Action action, bool primary = false)
        {
            var button = new Button { Content = text, Margin = new Thickness(Space("S8"), Space("S8"), 0, 0) };
            if (primary) button.SetResourceReference(StyleProperty, "Uten.PrimaryButton");
            button.Click += (sender, args) => action(); Actions.Children.Add(button); return button;
        }
        public void TrackPendingEditor(Window editor)
        {
            Window ancestor = editor?.Owner;
            while (ancestor != null && ancestor != this) ancestor = ancestor.Owner;
            if (ancestor != this) throw new ArgumentException("The child editor must belong to this dialog's ownership chain.");
            if (!pendingChildren.Add(editor)) return;
            editor.Closed += OnChildClosed;
            (Owner as IPendingEditHost)?.TrackPendingEditor(editor);
        }
        private void OnChildClosed(object sender, EventArgs args)
        {
            var child = sender as Window;
            if (child == null) return;
            child.Closed -= OnChildClosed; pendingChildren.Remove(child);
            if (!dialogEnded && closeRequested && pendingChildren.Count == 0)
                Dispatcher.BeginInvoke(new Action(() => { if (!dialogEnded && closeRequested && pendingChildren.Count == 0) Close(); }));
        }
        protected override void OnClosing(CancelEventArgs args)
        {
            if (pendingChildren.Count != 0)
            { closeRequested = true; args.Cancel = true; ShowStatus("请先完成子窗口中的操作或草稿保全。"); }
            base.OnClosing(args);
        }
        protected override void OnClosed(EventArgs args) { dialogEnded = true; base.OnClosed(args); }
        private void FitBodyViewport()
        {
            if (dialogEnded) return;
            double statusHeight = StatusLabel.Visibility == Visibility.Visible ? StatusLabel.ActualHeight + StatusLabel.Margin.Top : 0;
            double fixedHeight = Space("S24") * 2 + header.ActualHeight + Body.Margin.Top + Actions.ActualHeight
                + Actions.Margin.Top + statusHeight + 2;
            double maximum = Math.Max(80, SystemParameters.WorkArea.Height - fixedHeight);
            if (Math.Abs(bodyScroll.MaxHeight - maximum) > .5) bodyScroll.MaxHeight = maximum;
        }
        private void UpdateFrame() { frame.Update(this, true, (double)FindResource("Uten.Radius.DialogValue")); }
    }
}
