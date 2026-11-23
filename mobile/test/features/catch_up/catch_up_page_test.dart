// The Catch-up page's journey: empty state, a card shows, Mark as read
// advances and reads it, Undo brings it back unread, Keep unread holds it
// for a second pass, and the screen-reader actions decide too.
import 'package:buzz/features/catch_up/catch_up_page.dart';
import 'package:buzz/features/catch_up/catch_up_queue.dart';
import 'package:buzz/features/catch_up/catch_up_read.dart';
import 'package:buzz/features/catch_up/catch_up_reader.dart';
import 'package:buzz/features/catch_up/catch_up_sources.dart';
import 'package:buzz/features/catch_up/catch_up_state.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/widget_helpers.dart';
import 'catch_up_card_test.dart' show cardOverrides;
import 'catch_up_read_test.dart' show FakeReader;

Channel channel(String id, {String type = 'stream'}) => Channel(
  id: id,
  name: id,
  channelType: type,
  visibility: 'open',
  description: '',
  createdBy: 'x',
  createdAt: DateTime(2025),
  memberCount: 2,
  isMember: true,
);

CatchUpEntry entry(String channelId, int latest, {bool dm = false}) =>
    CatchUpEntry(
      key: channelId,
      channelId: channelId,
      dm: dm,
      attention: true,
      count: 1,
      manual: false,
      latest: latest,
    );

Future<FakeReader> pumpPage(
  WidgetTester tester,
  List<CatchUpEntry> entries,
) async {
  final reader = FakeReader();
  await tester.pumpWidget(
    WidgetHelpers.testable(
      overrides: [
        ...cardOverrides(),
        catchUpEntriesProvider.overrideWithValue(entries),
        catchUpLoadingProvider.overrideWithValue(false),
        catchUpChannelsProvider.overrideWithValue([
          channel('alice', type: 'dm'),
          channel('launch'),
        ]),
        catchUpStateProvider.overrideWith((ref) => CatchUpState()),
        catchUpReaderProvider.overrideWithValue(reader),
        myPubkeyProvider.overrideWithValue('a' * 64),
      ],
      child: const CatchUpPage(),
    ),
  );
  await tester.pump();
  return reader;
}

Finder markRead() => find.widgetWithText(FilledButton, 'Mark as read');

void main() {
  testWidgets('shows the empty state when nothing is aimed at you', (
    tester,
  ) async {
    await pumpPage(tester, const []);
    expect(find.text("You're all caught up"), findsOneWidget);
    expect(
      find.text(
        'Mentions, DMs and replies in your threads show up here as cards.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('goes through the stack card by card', (tester) async {
    final semantics = tester.ensureSemantics();
    final reader = await pumpPage(tester, [
      entry('alice', 300, dm: true),
      entry('launch', 200),
    ]);
    expect(find.text('2 Left'), findsOneWidget);
    expect(find.text('Direct message'), findsOneWidget);
    expect(find.text('Undo'), findsNothing);

    // Mark as read reads the card and shows the next one.
    await tester.tap(markRead());
    await tester.pump();
    expect(reader.calls['markChannelRead'], ['alice']);
    expect(find.text('1 Left'), findsOneWidget);
    expect(find.text('For you'), findsOneWidget);

    // Undo brings it back on top, unread again.
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(find.text('2 Left'), findsOneWidget);
    expect(find.text('Direct message'), findsOneWidget);
    expect(reader.calls['markUnreadLocal'], [
      const CatchUpChannelTarget('alice'),
    ]);

    // Keep unread holds both for later, without reading them.
    reader.calls.clear();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Keep unread'));
    await tester.pump();
    tester.semantics.customAction(
      find.semantics.byLabel(RegExp('^launch: For you')),
      const CustomSemanticsAction(label: 'Keep unread'),
    );
    await tester.pump();
    semantics.dispose();
    expect(reader.calls, isEmpty);
    expect(
      find.text('You kept 2 conversations unread for later.'),
      findsOneWidget,
    );

    // A second pass goes through the kept ones.
    await tester.tap(find.text('Go through kept conversations'));
    await tester.pump();
    expect(find.text('2 Left'), findsOneWidget);

    // A swipe right reads too.
    await tester.drag(find.text('Direct message'), const Offset(300, 0));
    await tester.pump();
    expect(reader.calls['markChannelRead'], ['alice']);
    expect(find.text('1 Left'), findsOneWidget);
  });
}
