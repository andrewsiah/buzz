// End-to-end check of the real Snack app on the iOS simulator against a live
// Snack stack. The test starts the app exactly like lib/main.dart, then runs
// commands a host-side driver (~/routines/snack-native-ios/e2e-driver.py on
// Olive) writes to /tmp/snack-e2e/cmd.<n> on the Mac. Each result goes to
// /tmp/snack-e2e/res.<n>. The cases (sign-in, channels, DMs, threads, Catch Up,
// web-only links) live in the driver, so it can screenshot and act as a second
// person between steps. No pumpAndSettle: the app has endless animations and
// live sockets, so every wait is a bounded pump loop.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buzz/app.dart';
import 'package:buzz/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Override with --dart-define=SNACK_E2E_DIR=... to run beside another e2e.
const _dir = String.fromEnvironment(
  'SNACK_E2E_DIR',
  defaultValue: '/tmp/snack-e2e',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('snack e2e (driver commands)', (tester) async {
    final errors = <String>[];
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString();
      errors.add(text);
      debugPrint('E2E_FLUTTER_ERROR ${text.split('\n').first}');
    };
    try {
      await runZonedGuarded(
        () => runBuzzApp(const App()),
        (e, s) => debugPrint('E2E_ASYNC_ERROR $e'),
      );
      await _pumpFor(tester, const Duration(seconds: 2));
      debugPrint('E2E_STEP started');
      await _serve(tester, errors);
    } finally {
      FlutterError.onError = originalOnError;
    }
  }, timeout: const Timeout(Duration(minutes: 90)));
}

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _serve(WidgetTester tester, List<String> errors) async {
  Directory(_dir).createSync(recursive: true);
  File('$_dir/ready').writeAsStringSync('${DateTime.now()}');
  var n = 1;
  var idle = DateTime.now();
  while (true) {
    final cmdFile = File('$_dir/cmd.$n');
    if (!cmdFile.existsSync()) {
      await tester.pump(const Duration(milliseconds: 150));
      if (DateTime.now().difference(idle) > const Duration(minutes: 30)) {
        debugPrint('E2E_STEP idle-timeout');
        return;
      }
      continue;
    }
    idle = DateTime.now();
    Map<String, dynamic> cmd;
    try {
      cmd = jsonDecode(cmdFile.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      await tester.pump(const Duration(milliseconds: 100));
      continue; // partially written; retry
    }
    Map<String, dynamic> res;
    try {
      res = await _run(tester, cmd, errors);
    } catch (e, s) {
      res = {
        'ok': false,
        'error': '$e',
        'stack': '$s'.split('\n').take(6).join('\n'),
      };
    }
    debugPrint('E2E_STEP ${cmd['op']} ${cmd['step'] ?? ''} ok=${res['ok']}');
    final tmp = File('$_dir/res.$n.tmp')..writeAsStringSync(jsonEncode(res));
    tmp.renameSync('$_dir/res.$n');
    n++;
    if (cmd['op'] == 'done') return;
  }
}

Finder _finder(Map<String, dynamic> f) {
  Finder base;
  if (f['key'] != null) {
    base = find.byKey(ValueKey<String>(f['key'] as String));
  } else if (f['keyPrefix'] != null) {
    final p = f['keyPrefix'] as String;
    base = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith(p),
    );
  } else if (f['text'] != null) {
    final t = f['text'] as String;
    base = f['exact'] == true
        ? find.text(t, findRichText: true)
        : find.textContaining(t, findRichText: true);
  } else if (f['tooltip'] != null) {
    base = find.byTooltip(f['tooltip'] as String);
  } else if (f['semantics'] != null) {
    base = find.bySemanticsLabel(
      RegExp(RegExp.escape(f['semantics'] as String)),
    );
  } else if (f['type'] != null) {
    final t = f['type'] as String;
    base = find.byWidgetPredicate((w) => w.runtimeType.toString() == t);
  } else if (f['icon'] != null) {
    final cp = f['icon'] as int;
    base = find.byWidgetPredicate((w) => w is Icon && w.icon?.codePoint == cp);
  } else {
    throw ArgumentError('bad finder $f');
  }
  if (f['in'] != null) {
    base = find.descendant(
      of: _finder(f['in'] as Map<String, dynamic>),
      matching: base,
    );
  }
  if (f['ancestor'] != null) {
    // The nearest ancestor of `base` that matches this finder.
    base = find.ancestor(
      of: base,
      matching: _finder(f['ancestor'] as Map<String, dynamic>),
    );
  }
  if (f['all'] != true) base = base.hitTestable();
  final i = f['index'];
  if (i is int) base = base.at(i);
  if (i == 'last') base = base.last;
  return base;
}

Future<bool> _waitFor(
  WidgetTester tester,
  Finder f,
  int seconds, {
  bool gone = false,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    final found = f.evaluate().isNotEmpty;
    if (found != gone) return true;
    await tester.pump(const Duration(milliseconds: 200));
  }
  return (f.evaluate().isNotEmpty) != gone;
}

List<String> _visibleTexts(WidgetTester tester) {
  final out = <String>[];
  final seen = <String>{};
  for (final e in find.byType(RichText).hitTestable().evaluate()) {
    final t = (e.widget as RichText).text.toPlainText().trim();
    if (t.isEmpty) continue;
    // Drop private-use icon glyphs.
    if (t.runes.every((r) => r >= 0xE000 && r <= 0xF8FF)) continue;
    if (seen.add(t)) out.add(t.length > 160 ? '${t.substring(0, 160)}…' : t);
  }
  return out;
}

List<String> _visibleKeys(WidgetTester tester) {
  final out = <String>{};
  for (final e
      in find
          .byWidgetPredicate((w) => w.key is ValueKey<String>)
          .hitTestable()
          .evaluate()) {
    out.add((e.widget.key! as ValueKey<String>).value);
  }
  return out.toList();
}

List<String> _tooltips() {
  final out = <String>{};
  for (final e in find.byType(Tooltip).hitTestable().evaluate()) {
    final m = (e.widget as Tooltip).message;
    if (m != null) out.add(m);
  }
  return out.toList();
}

List<String> _semantics(WidgetTester tester) {
  final out = <String>{};
  final root = tester.binding.rootPipelineOwner;
  void walk(SemanticsNode n) {
    final l = n.label.trim();
    if (l.isNotEmpty && n.getSemanticsData().hasAction(SemanticsAction.tap)) {
      out.add(l.length > 80 ? '${l.substring(0, 80)}…' : l);
    }
    n.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  void visitOwner(PipelineOwner o) {
    final r = o.semanticsOwner?.rootSemanticsNode;
    if (r != null) walk(r);
    o.visitChildren(visitOwner);
  }

  visitOwner(root);
  return out.toList();
}

Future<Map<String, dynamic>> _run(
  WidgetTester tester,
  Map<String, dynamic> cmd,
  List<String> errors,
) async {
  final timeout = (cmd['timeout'] as int?) ?? 20;
  switch (cmd['op']) {
    case 'ping':
      return {'ok': true};
    case 'pump':
      await _pumpFor(
        tester,
        Duration(milliseconds: (cmd['ms'] as int?) ?? 1000),
      );
      return {'ok': true};
    case 'wait':
      final f = _finder(cmd['find'] as Map<String, dynamic>);
      final ok = await _waitFor(tester, f, timeout, gone: cmd['gone'] == true);
      return {'ok': ok, if (!ok) 'texts': _visibleTexts(tester)};
    case 'count':
      final f = _finder(cmd['find'] as Map<String, dynamic>);
      return {'ok': true, 'count': f.evaluate().length};
    case 'text':
      // Plain text of the widget(s) matched, e.g. a badge count.
      final f = _finder(cmd['find'] as Map<String, dynamic>);
      final texts = <String>[];
      for (final e in f.evaluate()) {
        for (final r
            in find
                .descendant(
                  of: find.byElementPredicate((x) => x == e),
                  matching: find.byType(RichText),
                )
                .evaluate()) {
          texts.add((r.widget as RichText).text.toPlainText());
        }
      }
      return {'ok': texts.isNotEmpty, 'texts': texts};
    case 'tap':
      final f = _finder(cmd['find'] as Map<String, dynamic>);
      if (!await _waitFor(tester, f, timeout)) {
        return {
          'ok': false,
          'error': 'not found',
          'texts': _visibleTexts(tester),
        };
      }
      await tester.tap(f.first, warnIfMissed: false);
      await _pumpFor(
        tester,
        Duration(milliseconds: (cmd['settle'] as int?) ?? 800),
      );
      return {'ok': true};
    case 'longpress':
      final f = _finder(cmd['find'] as Map<String, dynamic>);
      if (!await _waitFor(tester, f, timeout)) {
        return {
          'ok': false,
          'error': 'not found',
          'texts': _visibleTexts(tester),
        };
      }
      await tester.longPress(f.first, warnIfMissed: false);
      await _pumpFor(tester, const Duration(milliseconds: 800));
      return {'ok': true};
    case 'enter':
      final f = _finder(cmd['find'] as Map<String, dynamic>);
      if (!await _waitFor(tester, f, timeout)) {
        return {
          'ok': false,
          'error': 'not found',
          'texts': _visibleTexts(tester),
        };
      }
      await tester.tap(f.first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(f.first, cmd['value'] as String);
      await _pumpFor(tester, const Duration(milliseconds: 500));
      return {'ok': true};
    case 'action':
      // Keyboard action on the focused field: done / send / go.
      final name = (cmd['value'] as String?) ?? 'done';
      await tester.testTextInput.receiveAction(
        TextInputAction.values.firstWhere((a) => a.name == name),
      );
      await _pumpFor(tester, const Duration(milliseconds: 800));
      return {'ok': true};
    case 'scroll':
      final f = _finder(cmd['find'] as Map<String, dynamic>);
      await tester.drag(
        f.first,
        Offset(0, ((cmd['dy'] as num?) ?? -300).toDouble()),
        warnIfMissed: false,
      );
      await _pumpFor(tester, const Duration(milliseconds: 800));
      return {'ok': true};
    case 'back':
      final back = find.byType(BackButton).hitTestable();
      final tip = find.byTooltip('Back').hitTestable();
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back.first, warnIfMissed: false);
      } else if (tip.evaluate().isNotEmpty) {
        await tester.tap(tip.first, warnIfMissed: false);
      } else {
        await tester.binding.handlePopRoute();
      }
      await _pumpFor(tester, const Duration(milliseconds: 1000));
      return {'ok': true};
    case 'dump':
      return {
        'ok': true,
        'texts': _visibleTexts(tester),
        'keys': _visibleKeys(tester),
        'tooltips': _tooltips(),
        'semantics': cmd['semantics'] == true ? _semantics(tester) : null,
        'errors': errors.length,
      };
    case 'errors':
      return {
        'ok': true,
        'errors': errors.map((e) => e.split('\n').take(3).join(' | ')).toList(),
      };
    case 'unfocus':
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await _pumpFor(tester, const Duration(milliseconds: 500));
      return {'ok': true};
    case 'done':
      return {'ok': true, 'errors': errors.length};
  }
  return {'ok': false, 'error': 'unknown op ${cmd['op']}'};
}
