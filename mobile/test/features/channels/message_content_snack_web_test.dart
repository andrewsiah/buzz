import 'package:buzz/features/channels/message_content.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/snack_web/snack_web_launcher.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../helpers/message_link_finders.dart';
import '../../shared/snack_blocks/snack_progress_sample.dart';

const _channelId = '580ca78b-9dae-46f3-8854-bd671853ba32';

void main() {
  testWidgets('Snack web links and Snack-only blocks in a message', (
    tester,
  ) async {
    final opened = <Uri>[];
    String? tappedChannel;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayConfigProvider.overrideWith(_SnackRelay.new),
          webLinkLauncherProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return true;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => AppMarkdownTheme(child: child!),
          home: Scaffold(
            body: MessageContent(
              content:
                  'See [the board](https://wesnack.app/?channel=$_channelId'
                  '&panel=board), [this channel](https://wesnack.app/'
                  '?community=https%3A%2F%2Fsnack.wesnack.app'
                  '&channel=$_channelId) and [elsewhere](https://example.org/x)'
                  '\n\n```buzz-chart\n'
                  '{"version":1,"type":"bar","title":"Signups","data":[]}\n'
                  '```\n',
              onChannelTap: (id) => tappedChannel = id,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A web-only page goes to the launcher, which opens it in the sheet.
    await tester.tapAt(linkCenter(tester, 'the board'));
    await tester.pump();
    expect(opened.single.toString(), contains('panel=board'));

    // A channel here opens natively, not on the web.
    await tester.tapAt(linkCenter(tester, 'this channel'));
    await tester.pump();
    expect(tappedChannel, _channelId);
    expect(opened, hasLength(1));

    await tester.tapAt(linkCenter(tester, 'elsewhere'));
    await tester.pump();
    expect(opened.last, Uri.parse('https://example.org/x'));

    // The chart is a row that opens Snack, not raw JSON.
    expect(find.textContaining('"type"', findRichText: true), findsNothing);
    expect(find.bySemanticsLabel('Chart: Signups, Open in Snack'), findsOne);
    await tester.tap(find.byKey(const ValueKey('snack-web-only-block')));
    await tester.pump();
    expect(
      opened.last.toString(),
      'https://wesnack.app/?community=https%3A%2F%2Fsnack.wesnack.app',
    );

    // VoiceOver's activate opens it too.
    final semantics = tester.ensureSemantics();
    tester.semantics.tap(
      find.semantics.byLabel('Chart: Signups, Open in Snack'),
    );
    await tester.pump();
    expect(opened, hasLength(4));
    semantics.dispose();
  });

  testWidgets('Snack cards in a message: progress, choices and a chart', (
    tester,
  ) async {
    final answers = <String>[];
    var fail = true;
    await tester.pumpWidget(
      _app(
        MessageContent(
          choiceKey: 'message-1',
          onChoice: (option) async {
            if (fail) {
              fail = false;
              throw StateError('offline');
            }
            answers.add(option);
          },
          content:
              '$snackProgressMessage\n\n'
              '```snack-choices\n'
              '{"question":"Start a goal agent?","options":["Yes","Not now"]}\n'
              '```\n\n'
              '```buzz-chart\n'
              '{"version":1,"type":"bar","title":"Signups","x":"day",'
              '"y":"count","data":[{"day":"Mon","count":4},'
              '{"day":"Tue","count":7}]}\n'
              '```\n',
        ),
      ),
    );
    await tester.pump();

    // No raw JSON anywhere: each block is a card.
    expect(find.textContaining('{', findRichText: true), findsNothing);
    expect(
      find.textContaining('snack-progress', findRichText: true),
      findsNothing,
    );
    expect(find.text('Working on this in the background.'), findsOne);
    expect(find.byKey(const ValueKey('snack-progress-card')), findsOne);
    expect(find.text('Sign in thesvpn X account'), findsOne);
    expect(
      find.textContaining('13 steps · Last: Made a web request'),
      findsOne,
    );
    expect(find.text('Start a goal agent?'), findsOne);
    expect(find.byKey(const ValueKey('snack-chart-card')), findsOne);
    expect(find.bySemanticsLabel('Chart: Signups, 2 points'), findsOne);

    // A failed answer gives the buttons back and says so.
    await tester.tap(find.text('Yes'));
    await tester.pump();
    expect(find.text("Couldn't send that. Try again."), findsOne);
    expect(answers, isEmpty);
    // Then an answer posts once and settles the buttons.
    await tester.tap(find.text('Yes'));
    await tester.pump();
    expect(answers, ['Yes']);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Not now'),
          )
          .onPressed,
      isNull,
    );
    expect(find.widgetWithText(FilledButton, 'Yes'), findsOne);
    await tester.tap(find.text('Not now'), warnIfMissed: false);
    await tester.pump();
    expect(answers, ['Yes']);
    // The live card ticks; stop its clock before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without a sender, choices are listed, not buttons', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const MessageContent(
          content:
              '```snack-choices\n'
              '{"question":"Pick one","options":["Red","Blue"]}\n```',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Pick one'), findsOne);
    expect(find.text('• Red'), findsOne);
    expect(find.byType(OutlinedButton), findsNothing);
  });
}

Widget _app(Widget body) => ProviderScope(
  child: MaterialApp(
    theme: AppTheme.light(),
    builder: (context, child) => AppMarkdownTheme(child: child!),
    home: Scaffold(body: SingleChildScrollView(child: body)),
  ),
);

class _SnackRelay extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'wss://snack.wesnack.app');
}
