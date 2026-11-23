// The mobile adapter: Catch-up's evidence comes from the same observed
// unread registry and synced read marks as the channel list, so a read in
// the channel (or on the web) takes the card away, and a hand mark adds one.
import 'package:buzz/features/catch_up/catch_up_queue.dart';
import 'package:buzz/features/catch_up/catch_up_sources.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/unread_badge/observed_unread_event.dart';
import 'package:flutter_test/flutter_test.dart';

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

ObservedUnreadEvent event(
  String id,
  int createdAt, {
  String? rootId,
  bool mention = false,
  bool dm = false,
}) => makeObservedUnreadEvent(
  id: id,
  createdAt: createdAt,
  rootId: rootId,
  highPriority: mention || dm,
  channelType: dm ? 'dm' : 'stream',
  isThreadedReply: rootId != null,
);

List<String> keys(
  List<Channel> channels,
  Map<String, List<ObservedUnreadEvent>> events, {
  Map<String, int> marks = const {},
  Map<String, String> forced = const {},
}) {
  final evidence = {
    for (final c in channels)
      c.id: buildCatchUpEvidence(
        channel: c,
        events: {for (final e in events[c.id] ?? const []) e.id: e},
        markerOf: (key) => marks[key],
        forcedUnreadContexts: forced,
      ),
  };
  return unreadEntries(
    [for (final c in channels) catchUpChannelOf(c)],
    {},
    (id) => evidence[id]!.unread,
    (id) => evidence[id]!.activity,
  ).map((entry) => entry.key).toList();
}

void main() {
  final launch = channel('launch');
  final dm = channel('dm', type: 'dm');
  final rows = <(String, List<String>, Map<String, int>, Map<String, String>)>[
    // An ordinary channel message is Activity's, not Catch-up's.
    ('ordinary only', [], const {}, const {}),
    // A mention, a reply in your thread and a DM each make a card.
    (
      'mention, thread, dm',
      ['dm', 'launch', 'launch:root'],
      const {},
      const {},
    ),
    // The channel mark reads everything in it, threads included.
    ('channel read', ['dm'], const {'launch': 500}, const {}),
    // The thread mark reads only that thread.
    ('thread read', ['dm', 'launch'], const {'thread:root': 500}, const {}),
    // A message mark reads that message only.
    ('mention read', ['dm', 'launch:root'], const {'msg:m1': 100}, const {}),
    // A hand mark keeps the conversation with nothing else unread.
    (
      'hand mark',
      ['launch'],
      const {'launch': 500, 'dm': 500},
      const {'launch': 'launch'},
    ),
  ];
  for (final (name, expected, marks, forced) in rows) {
    test('evidence: $name', () {
      final events = name == 'ordinary only'
          ? {
              'launch': [event('o1', 50)],
            }
          : {
              'launch': [
                event('o1', 50),
                event('m1', 100, mention: true),
                event('r1', 200, rootId: 'root'),
              ],
              'dm': [event('d1', 300, dm: true)],
            };
      expect(
        keys([launch, dm], events, marks: marks, forced: forced),
        expected,
      );
    });
  }
}
