import 'dart:async';
import 'dart:ui' as ui;

import 'package:buzz/shared/widgets/cookie_loading_mark.dart';
import 'package:buzz/shared/widgets/cookie_refresh_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/widget_helpers.dart';

void main() {
  testWidgets('cookie loses a bite at each fifth of the loop', (tester) async {
    // Alpha inside each bite's reach on the cookie, and at its untouched
    // left edge, in the 64x64 design box.
    const bites = [Offset(44, 16), Offset(52, 36), Offset(38, 50)];
    const edge = Offset(12, 32);
    for (final (progress, bitten) in const [
      (0.0, 0),
      (0.25, 1),
      (0.45, 2),
      (0.65, 3),
    ]) {
      final bytes = await _paintCookie(tester, progress);
      int alphaAt(Offset point) =>
          bytes.getUint8(((point.dy.round() * 64) + point.dx.round()) * 4 + 3);
      expect(alphaAt(edge), 255, reason: 'cookie at $progress');
      for (var i = 0; i < bites.length; i++) {
        expect(
          alphaAt(bites[i]),
          i < bitten ? 0 : 255,
          reason: 'bite ${i + 1} at $progress',
        );
      }
    }
    // Between 88% and 96% the cookie is gone, leaving only the crumb pile.
    final gone = await _paintCookie(tester, 0.9);
    expect(gone.getUint8(((32 * 64) + 12) * 4 + 3), 0);
  });

  testWidgets('shows the cookie while pulling to refresh', (tester) async {
    const contentKey = ValueKey('loading-content');
    var refreshes = 0;
    final refreshCompleter = Completer<void>();

    await tester.pumpWidget(
      WidgetHelpers.testable(
        child: CookieRefreshIndicator(
          onRefresh: () {
            refreshes++;
            return refreshCompleter.future;
          },
          child: ListView(
            children: const [SizedBox(key: contentKey, height: 800)],
          ),
        ),
      ),
    );

    final listFinder = find.byType(ListView);
    final restingTop = tester.getTopLeft(listFinder).dy;
    final restingContentTop = tester.getTopLeft(find.byKey(contentKey)).dy;
    await tester.timedDrag(
      listFinder,
      const Offset(0, 320),
      const Duration(milliseconds: 500),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 300));

    final cookieFinder = find.byType(CookieLoadingMark);
    final loadingTop = tester.getTopLeft(listFinder).dy;
    final loadingContentTop = tester.getTopLeft(find.byKey(contentKey)).dy;
    final gapTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('cookie-refresh-retained-gap')),
    );
    expect(cookieFinder, findsOneWidget);
    expect(refreshes, 1);
    expect(gapTransform.transform.getTranslation().y, closeTo(72, 1));
    expect(loadingTop - restingTop, closeTo(72, 1));
    final loadingCookieRect = tester.getRect(cookieFinder);
    final loadingGap = loadingContentTop - restingContentTop;
    expect(
      loadingCookieRect.center.dy,
      closeTo(
        restingContentTop +
            (loadingGap - loadingCookieRect.height) * 0.75 +
            loadingCookieRect.height / 2,
        1,
      ),
    );

    refreshCompleter.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    final closingTop = tester.getTopLeft(listFinder).dy;
    expect(closingTop, greaterThan(restingTop));
    expect(closingTop, lessThan(loadingTop));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(listFinder).dy, closeTo(restingTop, 1));
    expect(cookieFinder, findsNothing);
  });

  testWidgets('tracks each stage of an active pull', (tester) async {
    tester.view.physicalSize = const Size(420, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final hapticCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') hapticCalls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    const contentKey = ValueKey('pull-content');
    final refreshCompleter = Completer<void>();
    await tester.pumpWidget(
      WidgetHelpers.testable(
        child: CookieRefreshIndicator(
          onRefresh: () => refreshCompleter.future,
          child: ListView(
            children: const [SizedBox(key: contentKey, height: 800)],
          ),
        ),
      ),
    );

    final restingContentTop = tester.getTopLeft(find.byKey(contentKey)).dy;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
      pointer: 1,
    );
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump();

    final cookieFinder = find.byType(CookieLoadingMark);
    expect(cookieFinder, findsNothing);
    expect(
      tester.getTopLeft(find.byKey(contentKey)).dy,
      greaterThan(restingContentTop),
    );

    await gesture.moveBy(const Offset(0, 44));
    await tester.pump();

    final earlyTop = tester.getTopLeft(cookieFinder).dy;
    final partialOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('cookie-refresh-opacity')),
    );
    expect(partialOpacity.opacity, greaterThan(0));
    expect(partialOpacity.opacity, lessThan(1));
    final partialScale = tester
        .widget<Transform>(find.byKey(const ValueKey('cookie-refresh-scale')))
        .transform
        .storage[0];
    expect(partialScale, greaterThan(0.6));
    expect(partialScale, lessThan(1));
    expect(hapticCalls, isEmpty);

    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();

    final pulledContentTop = tester.getTopLeft(find.byKey(contentKey)).dy;
    expect(tester.getTopLeft(cookieFinder).dy, greaterThan(earlyTop));
    expect(
      find.byKey(const ValueKey('cookie-refresh-eyes-emoji')),
      findsNothing,
    );
    final pulledCookieRect = tester.getRect(cookieFinder);
    final pulledGap = pulledContentTop - restingContentTop;
    expect(
      pulledCookieRect.center.dy,
      closeTo(
        restingContentTop +
            (pulledGap - pulledCookieRect.height) * 0.75 +
            pulledCookieRect.height / 2,
        1,
      ),
    );

    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();

    expect(
      tester
          .widget<Transform>(find.byKey(const ValueKey('cookie-refresh-scale')))
          .transform
          .storage[0],
      closeTo(1, 0.001),
    );
    expect(hapticCalls, hasLength(1));
    expect(hapticCalls.single.arguments, 'HapticFeedbackType.mediumImpact');
    expect(
      find.byKey(const ValueKey('cookie-refresh-eyes-emoji')),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 350));
    await gesture.moveBy(
      const Offset(0, 120),
      timeStamp: const Duration(milliseconds: 350),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('cookie-refresh-eyes-emoji')),
      findsNothing,
    );
    expect(hapticCalls, hasLength(1));

    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveBy(
      const Offset(0, 240),
      timeStamp: const Duration(milliseconds: 750),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('cookie-refresh-eyes-emoji')),
      findsOneWidget,
    );
    expect(hapticCalls, hasLength(2));
    expect(hapticCalls.last.arguments, 'HapticFeedbackType.heavyImpact');
    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('cookie-refresh-eyes-emoji-offset')),
          )
          .transform
          .storage[13],
      12,
    );
    final initialShake = tester
        .widget<Transform>(
          find.byKey(const ValueKey('cookie-refresh-eyes-emoji-shake')),
        )
        .transform
        .storage[12];
    await tester.pump(const Duration(milliseconds: 35));
    final movedShake = tester
        .widget<Transform>(
          find.byKey(const ValueKey('cookie-refresh-eyes-emoji-shake')),
        )
        .transform
        .storage[12];
    expect(movedShake, isNot(closeTo(initialShake, 0.01)));
    expect(movedShake.abs(), lessThanOrEqualTo(0.75));
    await tester.pump(const Duration(milliseconds: 105));
    expect(hapticCalls, hasLength(3));
    expect(hapticCalls.last.arguments, 'HapticFeedbackType.selectionClick');

    final secondGesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
      pointer: 2,
    );
    await secondGesture.moveBy(
      const Offset(0, 40),
      timeStamp: const Duration(milliseconds: 800),
    );
    await gesture.up();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('cookie-refresh-eyes-emoji')),
      findsOneWidget,
    );
    expect(hapticCalls, hasLength(3));

    await secondGesture.moveBy(
      const Offset(0, 80),
      timeStamp: const Duration(milliseconds: 900),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('cookie-refresh-eyes-emoji')),
      findsOneWidget,
    );
    expect(hapticCalls, hasLength(3));

    await secondGesture.up();
    await tester.pump();
    final hapticsAfterRelease = hapticCalls.length;
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('cookie-refresh-eyes-emoji')),
      findsNothing,
    );
    expect(hapticCalls, hasLength(hapticsAfterRelease));

    refreshCompleter.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('keeps expressive eyes hidden for a quick refresh flick', (
    tester,
  ) async {
    final hapticCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') hapticCalls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final refreshCompleter = Completer<void>();
    var refreshes = 0;
    await tester.pumpWidget(
      WidgetHelpers.testable(
        child: CookieRefreshIndicator(
          onRefresh: () {
            refreshes++;
            return refreshCompleter.future;
          },
          child: ListView(children: const [SizedBox(height: 800)]),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    for (var step = 0; step < 10; step++) {
      await gesture.moveBy(
        const Offset(0, 50),
        timeStamp: Duration(milliseconds: (step + 1) * 10),
      );
      await tester.pump(const Duration(milliseconds: 10));
      expect(
        find.byKey(const ValueKey('cookie-refresh-eyes-emoji')),
        findsNothing,
      );
    }

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(refreshes, 1);
    expect(hapticCalls, hasLength(1));
    expect(hapticCalls.single.arguments, 'HapticFeedbackType.mediumImpact');
    expect(
      find.byKey(const ValueKey('cookie-refresh-eyes-emoji')),
      findsNothing,
    );

    refreshCompleter.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('keeps the cookie whole when motion is disabled', (tester) async {
    final refreshCompleter = Completer<void>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: WidgetHelpers.testable(
          child: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: CookieRefreshIndicator(
                onRefresh: () => refreshCompleter.future,
                child: ListView(children: const [SizedBox(height: 800)]),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.timedDrag(
      find.byType(ListView),
      const Offset(0, 320),
      const Duration(milliseconds: 400),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Refreshing: the gap is held and the cookie is free to animate.
    final gap = tester.widget<Transform>(
      find.byKey(const ValueKey('cookie-refresh-retained-gap')),
    );
    expect(gap.transform.getTranslation().y, greaterThan(0));
    final cookie = find.byType(CookieLoadingMark);
    expect(tester.widget<CookieLoadingMark>(cookie).progress, isNull);
    final painter = tester
        .widgetList<CustomPaint>(
          find.descendant(of: cookie, matching: find.byType(CustomPaint)),
        )
        .map((paint) => paint.painter)
        .whereType<CookiePainter>()
        .single;
    // A still frame of the whole cookie, not a running loop.
    expect(painter.continuous, isFalse);
    expect(painter.loop, isA<AlwaysStoppedAnimation<double>>());
    expect(painter.loop.value, 0);

    refreshCompleter.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('provides elastic always-scrollable physics', (tester) async {
    late ScrollPhysics physics;

    await tester.pumpWidget(
      WidgetHelpers.testable(
        child: CookieRefreshIndicator(
          onRefresh: () async {},
          child: Builder(
            builder: (context) {
              physics = ScrollConfiguration.of(
                context,
              ).getScrollPhysics(context);
              return ListView(children: const [SizedBox(height: 20)]);
            },
          ),
        ),
      ),
    );

    expect(physics, isA<BouncingScrollPhysics>());
    expect(physics.parent, isA<AlwaysScrollableScrollPhysics>());
  });
}

Future<ByteData> _paintCookie(WidgetTester tester, double progress) async {
  final key = ValueKey('cookie-$progress');
  await tester.pumpWidget(
    Center(
      child: RepaintBoundary(
        key: key,
        child: CookieLoadingMark(progress: progress, semanticLabel: null),
      ),
    ),
  );
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data;
  });
  return bytes!;
}
