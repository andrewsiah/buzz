import 'package:buzz/features/channels/message_content.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/snack_web/snack_web_launcher.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../helpers/message_link_finders.dart';

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
}

class _SnackRelay extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'wss://snack.wesnack.app');
}
