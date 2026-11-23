// Ported from Snack web's `snack-catchup/CatchUpCard.test.tsx`: which
// conversation a card shows, and that threads open inside it.
import 'package:buzz/features/catch_up/catch_up_card.dart';
import 'package:buzz/features/catch_up/catch_up_messages.dart';
import 'package:buzz/features/catch_up/catch_up_sources.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart';

import '../../helpers/widget_helpers.dart';

final launch = Channel(
  id: 'launch',
  name: 'launch',
  channelType: 'stream',
  visibility: 'open',
  description: '',
  createdBy: 'x',
  createdAt: DateTime(2025),
  memberCount: 2,
  isMember: true,
);

final author = 'b' * 64;

/// Card content, from the same providers the app reads, faked at the seam.
List<Override> cardOverrides() => [
  catchUpEvidenceProvider.overrideWithValue(const {}),
  catchUpMuteProvider.overrideWithValue(
    CatchUpMuteControl(muted: const {}, setMuted: (_, _) {}),
  ),
  catchUpAuthorLabelProvider.overrideWith(
    (ref, _) =>
        (_) => 'Ada',
  ),
  catchUpProfilesProvider.overrideWithValue(const {}),
  catchUpTimelineProvider.overrideWith(
    (ref, _) => AsyncData([
      CatchUpMessage(
        id: 'root',
        pubkey: author,
        content: 'message root',
        createdAt: 100,
        replyCount: 2,
      ),
      CatchUpMessage(
        id: 'later',
        pubkey: author,
        content: 'message later',
        createdAt: 101,
      ),
    ]),
  ),
  catchUpThreadProvider.overrideWith(
    (ref, args) => AsyncData([
      CatchUpMessage(
        id: args.rootId,
        pubkey: author,
        content: 'thread ${args.rootId}',
        createdAt: 100,
      ),
    ]),
  ),
];

Finder threadRegion() => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == 'Thread',
);

Future<List<String>> pumpCard(WidgetTester tester, {String? rootId}) async {
  final opened = <String>[];
  await tester.pumpWidget(
    WidgetHelpers.testable(
      overrides: cardOverrides(),
      child: CatchUpCard(
        channel: launch,
        channelId: 'launch',
        rootId: rootId,
        entry: null,
        newLineId: null,
        viewer: 'a' * 64,
        onOpen: (channelId, messageId, _) => opened.add('$messageId'),
        onDecide: (_) {},
      ),
    ),
  );
  await tester.pump();
  return opened;
}

void main() {
  testWidgets("shows a thread card's thread itself, not its channel", (
    tester,
  ) async {
    await pumpCard(tester, rootId: 'root');
    expect(threadRegion(), findsOneWidget);
    expect(
      find.descendant(of: threadRegion(), matching: find.text('thread root')),
      findsOneWidget,
    );
    expect(find.text('message later'), findsNothing);
    expect(find.text('New replies in a thread'), findsOneWidget);
  });

  testWidgets(
    "opens a conversation card's replies inside the card and comes back",
    (tester) async {
      final opened = await pumpCard(tester);
      await tester.tap(find.text('2 replies'));
      await tester.pump();
      expect(opened, isEmpty);
      expect(
        find.descendant(of: threadRegion(), matching: find.text('thread root')),
        findsOneWidget,
      );
      await tester.tap(find.textContaining('Back to'));
      await tester.pump();
      expect(find.text('message later'), findsOneWidget);
      expect(threadRegion(), findsNothing);

      // Tapping a message opens the real conversation at it.
      await tester.tap(find.text('message later'));
      expect(opened, ['later']);
    },
  );
}
