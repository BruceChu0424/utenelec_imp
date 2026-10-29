using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>Border.CornerRadius paints a frame but does not clip children.
    /// This shared surface gives tables, panels and windows the same real clip.</summary>
    public sealed class RoundedSurface : Border
    {
        protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
        {
            base.OnRenderSizeChanged(sizeInfo);
            UpdateClip();
        }
        protected override void OnPropertyChanged(DependencyPropertyChangedEventArgs e)
        {
            base.OnPropertyChanged(e);
            if (e.Property == CornerRadiusProperty) UpdateClip();
        }
        private void UpdateClip()
        {
            double width = ActualWidth, height = ActualHeight;
            if (width <= 0 || height <= 0) return;
            var radius = CornerRadius;
            double tl = radius.TopLeft, tr = radius.TopRight, br = radius.BottomRight, bl = radius.BottomLeft;
            double scale = Math.Min(1, Math.Min(Ratio(width, tl + tr), Math.Min(Ratio(width, bl + br),
                Math.Min(Ratio(height, tl + bl), Ratio(height, tr + br)))));
            tl *= scale; tr *= scale; br *= scale; bl *= scale;
            var geometry = new StreamGeometry();
            using (var drawing = geometry.Open())
            {
                drawing.BeginFigure(new Point(tl, 0), true, true);
                drawing.LineTo(new Point(width - tr, 0), true, false);
                Arc(drawing, new Point(width, tr), tr);
                drawing.LineTo(new Point(width, height - br), true, false);
                Arc(drawing, new Point(width - br, height), br);
                drawing.LineTo(new Point(bl, height), true, false);
                Arc(drawing, new Point(0, height - bl), bl);
                drawing.LineTo(new Point(0, tl), true, false);
                Arc(drawing, new Point(tl, 0), tl);
            }
            geometry.Freeze();
            Clip = geometry;
        }
        private static double Ratio(double available, double wanted) { return wanted == 0 ? 1 : available / wanted; }
        private static void Arc(StreamGeometryContext drawing, Point end, double radius)
        {
            if (radius == 0) drawing.LineTo(end, true, false);
            else drawing.ArcTo(end, new Size(radius, radius), 0, false, SweepDirection.Clockwise, true, false);
        }
    }
}
