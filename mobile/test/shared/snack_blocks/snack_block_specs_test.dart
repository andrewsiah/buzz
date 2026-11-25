import 'package:buzz/features/channels/message_content/preview_text.dart';
import 'package:buzz/shared/snack_blocks/snack_block_specs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'snack_progress_failed_sample.dart';
import 'snack_progress_sample.dart';

void main() {
  test('reads a real progress card the way the web card does', () {
    final progress = SnackProgress.parse(snackProgressSample)!;
    expect(progress.title, 'Sign in thesvpn X account');
    expect(progress.count, 13);
    // Raw shell commands become plain labels, as on the web.
    expect(progress.steps.map((s) => s.text), [
      'Read /home/user/thesvpn_screenshot_IMG_1386.png',
      'Read a file',
      'Ran which snack-computer',
      'Made a web request',
    ]);
    const now = snackProgressNow;
    expect(progress.label(now), 'Working');
    expect(progress.elapsed(now), '2m 0s');
    expect(
      snackBlockSummary('snack-progress', snackProgressSample),
      'Sign in thesvpn X account · 13 steps',
    );
    // Seven quiet minutes later it has lost contact.
    expect(progress.label(now + 7 * 60), 'No update for 7m 30s');
  });

  test('progress statuses, bad blocks and other blocks', () {
    String? summary(String language, String code) =>
        snackBlockSummary(language, code);
    const cases = <(String, String), String?>{
      (
        'snack-progress',
        '{"title":"Ship","status":"done","startedAt":1000,"updatedAt":1100,"count":1}',
      ): 'Done · Ship · 1 step',
      (
        'SNACK-PROGRESS',
        '{"title":"Ship","status":"failed","startedAt":1000,"steps":[]}',
      ): "Couldn't finish · Ship · 0 steps",
      ('snack-progress', '{"title":"Half'): 'Progress',
      ('snack-progress', '{"title":"No start"}'): 'Progress',
      (
        'snack-choices',
        '{"question":"Start a goal agent?","options":["Yes","Not now"]}',
      ): 'Start a goal agent?',
      ('snack-choices', '{"options":["A","B"]}'): 'A / B',
      ('snack-choices', '{"question":"Q","options":[]}'): 'Choices',
      ('buzz-chart', '{"type":"bar","title":"Signups"}'): 'Chart: Signups',
      (' BUZZ-CHART ', '{"type":"bar"}'): 'Chart',
      ('buzz-chart', '{"type":'): 'Chart',
      ('buzz-chart', '[1, 2]'): 'Chart',
      ('json', '{"title":"Signups"}'): null,
      ('', 'plain'): null,
    };
    for (final MapEntry(key: (language, code), :value) in cases.entries) {
      expect(summary(language, code), value, reason: '$language $code');
    }
  });

  test('shell commands get the web card plain labels', () {
    const cases = {
      'cd ~ && buzz channels list': 'Ran buzz channels',
      'sleep 30': 'Waited 30s',
      'curl -sI https://example.org/x': 'Fetched example.org',
      'FOO=1 sudo grep -r x .': 'Searched files',
      'for f in a b; do cat \$f; done': 'Read a file',
      'export A=1': 'Ran a command',
    };
    for (final MapEntry(key: command, :value) in cases.entries) {
      expect(shellCommandLabel(command), value, reason: command);
    }
  });

  test('draws simple version 1 charts natively, titles the rest', () {
    final bar = SnackChart.parse(
      '{"version":1,"type":"bar","title":"Signups","x":"day","y":"count",'
      '"data":[{"day":"Mon","count":4},{"day":"Tue","count":7}]}',
    );
    expect(bar.type, 'bar');
    expect(bar.points.map((p) => (p.label, p.y)), [('Mon', 4.0), ('Tue', 7.0)]);
    for (final other in [
      '{"version":2,"title":"T","option":{}}',
      '{"version":1,"type":"bar","title":"T","x":"d","y":"c","series":"s",'
          '"data":[{"d":"a","c":1,"s":"x"}]}',
      '{"version":1,"type":"pie","title":"T","x":"d","y":"c","data":[]}',
    ]) {
      final chart = SnackChart.parse(other);
      expect(chart.points, isEmpty, reason: other);
      expect(chart.summary, 'Chart: T');
    }
  });

  test('splits cards out of message text, leaving other code alone', () {
    final segments = splitSnackBlocks(
      'Hi\n```dart\nfinal x = 1;\n```\n'
      '```snack-choices\n{"question":"Q","options":["A"]}\n```\nBye',
    );
    expect(segments, [
      (text: 'Hi\n```dart\nfinal x = 1;\n```', language: null),
      (text: '{"question":"Q","options":["A"]}', language: 'snack-choices'),
      (text: 'Bye', language: null),
    ]);
    // An agent still writing a card: the rest is the card.
    expect(splitSnackBlocks('a\n```snack-progress\n{"title"'), [
      (text: 'a', language: null),
      (text: '{"title"', language: 'snack-progress'),
    ]);
  });

  test('plain-text places (search, reminders) get summaries too', () {
    expect(
      snackBlocksAsText(snackProgressMessage),
      'Working on this in the background.\nSign in thesvpn X account · 13 steps',
    );
    expect(snackBlocksAsText('no fences'), 'no fences');
  });

  test('previews show a card as one line, never its JSON', () {
    final text = messagePreviewPieces(
      snackProgressMessage,
      maxLines: 3,
    ).whereType<PreviewText>().map((piece) => piece.text).join();
    expect(text, startsWith('Working on this in the background.\n'));
    expect(text, contains('Sign in thesvpn X account · 13 steps'));
    expect(text, isNot(contains('{')));
    // Text after the card still shows.
    final after = messagePreviewPieces(
      '```snack-choices\n{"question":"Go?","options":["Yes"]}\n```\nthanks',
      maxLines: 3,
    ).whereType<PreviewText>().map((piece) => piece.text).join();
    expect(after, 'Go?\nthanks');
    // An unclosed card ends the preview instead of leaking its JSON.
    final open = messagePreviewPieces(
      'hi\n```snack-progress\n{"title":"T",\n"steps":[]',
      maxLines: 3,
    ).whereType<PreviewText>().map((piece) => piece.text).join();
    expect(open, 'hi\nProgress');
  });

  test('a long failed card draws as a card, not raw JSON', () {
    final segments = splitSnackBlocks(snackProgressFailedMessage);
    expect(segments.map((s) => s.language), [null, 'snack-progress']);
    expect(segments.first.text, "Couldn't finish this.");
    final progress = SnackProgress.parse(segments.last.text)!;
    expect(progress.title, 'End-to-end test for job watchdog');
    expect(progress.count, 63);
    expect(progress.label(progress.updatedAt), "Couldn't finish");
    expect(snackBlocksAsText(snackProgressFailedMessage), isNot(contains('{')));
  });
}
