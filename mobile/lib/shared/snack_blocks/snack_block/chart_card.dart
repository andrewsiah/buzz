part of '../snack_block.dart';

/// A simple version 1 chart: title and a bar, line or scatter plot.
class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.chart, this.ink});

  final SnackChart chart;
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    final color = ink ?? context.colors.primary;
    final quiet = ink ?? context.colors.onSurfaceVariant;
    final points = chart.points;
    final first = points.first.label;
    final lastLabel = points.last.label;
    return Semantics(
      container: true,
      label:
          '${chart.summary}, ${points.length} '
          '${points.length == 1 ? 'point' : 'points'}',
      excludeSemantics: true,
      child: _CardFrame(
        ink: ink,
        child: Column(
          key: const ValueKey('snack-chart-card'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (chart.title.isNotEmpty) ...[
              Text(
                chart.title,
                style: context.textTheme.labelLarge?.copyWith(
                  color: ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: Grid.xxs),
            ],
            SizedBox(
              height: 120,
              width: double.infinity,
              child: CustomPaint(
                painter: _ChartPainter(
                  type: chart.type,
                  points: points,
                  color: color,
                  axis: quiet.withValues(alpha: 0.4),
                ),
              ),
            ),
            const SizedBox(height: Grid.half),
            Row(
              children: [
                Expanded(
                  child: Text(
                    first,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.bodySmall?.copyWith(color: quiet),
                  ),
                ),
                if (points.length > 1)
                  Expanded(
                    child: Text(
                      lastLabel,
                      maxLines: 1,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodySmall?.copyWith(
                        color: quiet,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.type,
    required this.points,
    required this.color,
    required this.axis,
  });

  final String type;
  final List<SnackChartPoint> points;
  final Color color;
  final Color axis;

  @override
  void paint(Canvas canvas, Size size) {
    final ys = points.map((p) => p.y);
    final xs = points.map((p) => p.x);
    final low = math.min(0.0, ys.reduce(math.min));
    final high = math.max(0.0, ys.reduce(math.max));
    final span = high - low == 0 ? 1.0 : high - low;
    final minX = xs.reduce(math.min);
    final spanX = xs.reduce(math.max) - minX;
    double yAt(double y) => size.height - (y - low) / span * size.height;
    final zero = yAt(0);
    canvas.drawLine(
      Offset(0, zero),
      Offset(size.width, zero),
      Paint()
        ..color = axis
        ..strokeWidth = 1,
    );
    final fill = Paint()..color = color;
    if (type == 'bar') {
      final slot = size.width / points.length;
      final width = math.max(1.0, slot * 0.7);
      for (final (index, point) in points.indexed) {
        final left = slot * index + (slot - width) / 2;
        canvas.drawRect(
          Rect.fromLTRB(left, yAt(point.y), left + width, zero),
          fill,
        );
      }
      return;
    }
    double xAt(double x) =>
        spanX == 0 ? size.width / 2 : (x - minX) / spanX * size.width;
    final offsets = [for (final p in points) Offset(xAt(p.x), yAt(p.y))];
    if (type == 'line' && offsets.length > 1) {
      canvas.drawPath(
        Path()..addPolygon(offsets, false),
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
    for (final offset in offsets) {
      canvas.drawCircle(offset, type == 'line' ? 2.5 : 3.5, fill);
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.type != type ||
      !listEquals(old.points, points) ||
      old.color != color ||
      old.axis != axis;
}
