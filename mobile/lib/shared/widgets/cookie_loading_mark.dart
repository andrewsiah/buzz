import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

/// Snack's loading mascot: a cookie eaten bite by bite on a 2 second loop.
///
/// Three bites land at 20%, 40% and 60% of the loop, each dropping crumbs;
/// at 80% the cookie shrinks away over a falling crumb pile, then returns
/// whole. Colors are fixed brand colors that read on light and dark surfaces.
/// With reduced motion it shows the whole cookie, still.
class CookieLoadingMark extends HookWidget {
  /// The rendered width and height.
  final double size;

  /// A fixed point in the loop, from 0 to 1, or null to animate.
  ///
  /// 0 is the whole cookie with no crumbs.
  final double? progress;

  /// The accessibility announcement, or null when an ancestor provides one.
  final String? semanticLabel;

  /// Creates the cookie loading mark.
  const CookieLoadingMark({
    this.size = 64,
    this.progress,
    this.semanticLabel = 'Loading',
    super.key,
  });

  /// The length of one eating loop.
  static const loopDuration = Duration(seconds: 2);

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final animate = progress == null && !reduced;
    final controller = useAnimationController(duration: loopDuration);
    useEffect(() {
      if (animate) {
        controller.repeat();
      } else {
        // Restart from a whole cookie the next time it animates.
        controller.reset();
      }
      return controller.stop;
    }, [controller, animate]);

    final Animation<double> loop = animate
        ? controller
        : AlwaysStoppedAnimation(reduced ? 0 : progress!.clamp(0.0, 1.0));
    final mark = RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: CookiePainter(loop, continuous: animate),
      ),
    );
    if (semanticLabel case final label?) {
      return Semantics(
        label: label,
        liveRegion: true,
        child: ExcludeSemantics(child: mark),
      );
    }
    return ExcludeSemantics(child: mark);
  }
}

/// Paints one frame of the cookie loop in a 64x64 design box.
///
/// Mirrors the web's snack-cookie-loading.svg keyframes.
@visibleForTesting
class CookiePainter extends CustomPainter {
  /// Creates a painter that repaints as [loop] ticks.
  CookiePainter(this.loop, {this.continuous = false}) : super(repaint: loop);

  /// The loop position, from 0 to 1.
  final Animation<double> loop;

  /// Whether the loop is running, so late crumbs finish falling after it
  /// wraps. A still frame at 0 stays a clean, whole cookie.
  final bool continuous;

  static const _dough = Color(0xFFD99A4E);
  static const _crust = Color(0xFFB87634);
  static const _chip = Color(0xFF4A2C17);

  static const _chips = <(double, double, double)>[
    (23, 23, 3.9),
    (38, 19.5, 3.3),
    (42, 35, 4.1),
    (26.5, 40.5, 3.6),
    (33, 30, 2.6),
    (18, 33, 2.4),
  ];

  // Each bite is three overlapping circles cut from the cookie's edge.
  static const _bites = <List<(double, double, double)>>[
    [(49.4, 11.3, 9.5), (40.7, 8, 6.5), (54.1, 19.3, 6.5)],
    [(58.6, 36.7, 9.5), (57.1, 27.6, 6.5), (54.1, 44.8, 6.5)],
    [(41.2, 57.4, 9.5), (48.4, 51.5, 6.5), (32, 57.5, 6.5)],
  ];

  // Crumbs: x, y, side, delay as a fraction of the loop.
  static const _biteCrumbs = <List<(double, double, double, double)>>[
    [(40.2, 14.6, 2.6, 0), (45, 14.9, 2, .02), (48.9, 14.8, 2.3, .04)],
    [(47.4, 34.3, 2.6, 0), (52.2, 34.6, 2, .02), (56.1, 34.5, 2.3, .04)],
    [(33.9, 50.4, 2.6, 0), (38.7, 50.7, 2, .02), (42.6, 50.6, 2.3, .04)],
  ];
  static const _pileCrumbs = <(double, double, double, double)>[
    (20, 26, 3, 0),
    (26, 30, 2.4, .015),
    (31, 34, 3.2, .03),
    (37, 26, 2.6, .045),
    (43, 30, 3, 0),
    (23, 34, 2.2, .015),
    (34, 26, 2.2, .03),
    (40, 30, 2.4, .045),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final t = loop.value;
    canvas
      ..save()
      ..scale(size.width / 64, size.height / 64)
      ..clipRect(const Rect.fromLTWH(0, 0, 64, 64));

    // Whole at 0-80%, shrinks to 0.6 and fades by 88%, hidden until 96%,
    // then grows back whole by 100%.
    final (scale, opacity) = switch (t) {
      < .8 => (1.0, 1.0),
      < .88 => (1 - .4 * (t - .8) / .08, 1 - (t - .8) / .08),
      < .96 => (.6, 0.0),
      _ => (.6 + .4 * (t - .96) / .04, (t - .96) / .04),
    };
    if (opacity > 0) {
      canvas
        ..save()
        ..translate(32, 32)
        ..scale(scale)
        ..translate(-32, -32)
        ..saveLayer(
          const Rect.fromLTWH(0, 0, 64, 64),
          Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
        )
        ..drawCircle(const Offset(32, 32), 24, Paint()..color = _dough)
        ..drawCircle(
          const Offset(32, 32),
          24,
          Paint()
            ..color = _crust
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      final chipPaint = Paint()..color = _chip;
      for (final (x, y, r) in _chips) {
        canvas.drawCircle(Offset(x, y), r, chipPaint);
      }
      final bitePaint = Paint()..blendMode = BlendMode.clear;
      for (var i = 0; i < _bites.length; i++) {
        if (t < .2 * (i + 1)) break;
        for (final (x, y, r) in _bites[i]) {
          canvas.drawCircle(Offset(x, y), r, bitePaint);
        }
      }
      canvas
        ..restore()
        ..restore();
    }

    for (var i = 0; i < _biteCrumbs.length; i++) {
      for (final crumb in _biteCrumbs[i]) {
        _paintCrumb(canvas, crumb, t, .2 * (i + 1), .16, 16, _crust);
      }
    }
    for (final crumb in _pileCrumbs) {
      _paintCrumb(canvas, crumb, t, .8, .18, 22, _dough);
      // Late pile crumbs are still falling when the loop wraps.
      if (continuous) _paintCrumb(canvas, crumb, t + 1, .8, .18, 22, _dough);
    }
    canvas.restore();
  }

  /// Draws a crumb that appears at [start] and falls [fall] while fading out
  /// over [length] of the loop.
  static void _paintCrumb(
    Canvas canvas,
    (double, double, double, double) crumb,
    double t,
    double start,
    double length,
    double fall,
    Color color,
  ) {
    final (x, y, side, delay) = crumb;
    final p = (t - start - delay) / length;
    if (p < 0 || p >= 1) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y + fall * p, side, side),
        const Radius.circular(.4),
      ),
      Paint()..color = color.withValues(alpha: 1 - p),
    );
  }

  @override
  bool shouldRepaint(CookiePainter oldDelegate) =>
      oldDelegate.continuous != continuous ||
      (continuous
          ? oldDelegate.loop != loop
          : oldDelegate.loop.value != loop.value);
}
