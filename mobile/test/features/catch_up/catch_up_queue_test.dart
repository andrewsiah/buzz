// Ported from Snack web's `snack-catchup/queue.test.ts`, case for case.
import 'package:buzz/features/catch_up/catch_up_queue.dart';
import 'package:flutter_test/flutter_test.dart';

CatchUpChannel channel(
  String id, {
  String channelType = 'stream',
  bool joined = true,
  bool huddle = false,
}) => CatchUpChannel(
  id: id,
  channelType: channelType,
  joined: joined,
  huddle: huddle,
);

CatchUpUnread unread(
  int observedCount, [
  int attentionCount = 0,
  int createdAt = 0,
  String? oldestUnreadId,
  CatchUpRowUnread? row,
]) => CatchUpUnread(
  observedCount: observedCount,
  attentionCount: attentionCount,
  latestCreatedAt: createdAt,
  oldestUnreadId: oldestUnreadId,
  row: row,
);

CatchUpActivity quiet(String channelId) => const CatchUpActivity();

CatchUpActivity threads(
  String channelId,
  Map<String, int> roots, [
  int mentions = 0,
]) => CatchUpActivity(
  items: [
    for (final MapEntry(key: rootId, value: createdAt) in roots.entries)
      CatchUpThreadActivity(
        rootId: rootId,
        latestMessageId: '$rootId-reply',
        createdAt: createdAt,
        unreadCount: 2,
      ),
  ],
  mentions: [for (var index = 0; index < mentions; index++) 'mention-$index'],
);

List<CatchUpEntry> live(List<String> keys) => [
  for (final key in keys)
    CatchUpEntry(
      key: key,
      channelId: key,
      dm: false,
      attention: false,
      count: 0,
      manual: false,
      latest: 0,
    ),
];

void main() {
  group('Catch up stack', () {
    test(
      'lists only unread aimed at the viewer, mentions and DMs first, then newest',
      () {
        final snapshots = {
          'old': unread(3, 0, 100),
          'fresh': unread(1, 0, 300),
          'mention': unread(2, 1, 50),
          'dm': unread(1, 0, 10),
          'read': unread(0, 0, 400),
          'mutedQuiet': unread(5, 0, 500),
          'mutedMention': unread(5, 1, 20),
          'notJoined': unread(4, 0, 600),
          'huddle': unread(4, 0, 600),
        };
        final entries = unreadEntries(
          [
            channel('old'),
            channel('fresh'),
            channel('mention'),
            channel('dm', channelType: 'dm'),
            channel('read'),
            channel('mutedQuiet'),
            channel('mutedMention'),
            channel('notJoined', joined: false),
            channel('huddle', huddle: true),
          ],
          {'mutedQuiet', 'mutedMention'},
          (id) => snapshots[id]!,
          quiet,
        );
        expect(entries.map((entry) => entry.channelId), [
          'mention',
          'mutedMention',
          'dm',
        ]);
      },
    );

    test(
      'keeps the order it showed and adds newly unread conversations last',
      () {
        final entries = unreadEntries(
          [channel('b'), channel('c')],
          {},
          (id) => id == 'c' ? unread(1, 1, 900) : unread(1, 1, 1),
          quiet,
        );
        expect(stackOrder(['a', 'b'], entries), ['a', 'b', 'c']);
      },
    );

    group('while the reader is on a card', () {
      test('adds new arrivals below everything, never above the top card', () {
        expect(stackOrder(['a', 'b'], live(['b', 'z', 'c']), top: 'a'), [
          'a',
          'b',
          'z',
          'c',
        ]);
      });

      test('keeps a card that got a new reply in its place', () {
        expect(stackOrder(['a', 'b', 'c'], live(['a', 'b', 'c']), top: 'a'), [
          'a',
          'b',
          'c',
        ]);
      });

      test('sends a decided card that got a new reply to the bottom', () {
        // "a" was read, "b" kept; both got new replies while "c" is on top.
        expect(
          stackOrder(
            ['a', 'b', 'c', 'd'],
            live(['a', 'b', 'c', 'd']),
            top: 'c',
          ),
          ['c', 'd', 'a', 'b'],
        );
      });

      test(
        'sends a card read elsewhere that is unread again to the bottom',
        () {
          expect(stackOrder(['a', 'b', 'c'], live(['a', 'b', 'c']), top: 'b'), [
            'b',
            'c',
            'a',
          ]);
        },
      );

      test('leaves decided cards with nothing new where they were', () {
        expect(
          stackOrder(
            ['a', 'b', 'c'],
            live(['a', 'b', 'c']),
            top: 'c',
            handled: {'a', 'b'},
          ),
          ['a', 'b', 'c'],
        );
      });

      test('keeps an undone card on top where Undo put it', () {
        expect(
          stackOrder(
            ['a', 'b', 'c'],
            live(['a', 'b', 'c']),
            top: 'b',
            restored: {'a'},
          ),
          ['a', 'b', 'c'],
        );
      });

      test(
        'sends the top card to the bottom when a reply lands as it is decided',
        () {
          expect(
            stackOrder(
              ['a', 'b', 'c'],
              live(['a', 'b', 'c']),
              top: 'a',
              topDecided: true,
            ),
            ['b', 'c', 'a'],
          );
        },
      );

      test('is settled after one pass', () {
        final once = stackOrder(
          ['a', 'b', 'c'],
          live(['a', 'c', 'd']),
          top: 'b',
        );
        expect(stackOrder(once, live(['a', 'c', 'd']), top: 'b'), once);
      });
    });

    test(
      'gives each thread with unread replies its own card, newest first',
      () {
        final entries = unreadEntries(
          [channel('launch'), channel('design')],
          {},
          (id) => id == 'launch' ? unread(3, 3, 500) : unread(1, 1, 50),
          (id) => id == 'launch'
              ? threads(id, {'rootA': 400, 'rootB': 500})
              : threads(id, {}, 1),
        );
        expect(entries.map((entry) => entry.key), [
          'launch:rootB',
          'launch:rootA',
          'design',
        ]);
        expect(entries[0].channelId, 'launch');
        expect(entries[0].rootId, 'rootB');
        expect(entries[0].attention, isTrue);
        expect(entries[0].count, 2);
      },
    );

    test(
      'keeps a conversation card beside its threads only for timeline mentions',
      () {
        final entries = unreadEntries(
          [channel('launch'), channel('design')],
          {},
          (_) => unread(3, 3, 500),
          (id) => id == 'launch'
              ? threads(id, {'rootA': 400}, 1)
              : threads(id, {'rootB': 300}),
        );
        expect(entries.map((entry) => entry.key).toList()..sort(), [
          'design:rootB',
          'launch',
          'launch:rootA',
        ]);
      },
    );

    test(
      'keeps a DM card beside its thread cards only for unread top-level messages',
      () {
        final dm = channel('dm', channelType: 'dm');
        expect(
          unreadEntries(
            [dm],
            {},
            (_) => unread(2, 0, 500, 'top'),
            (id) => threads(id, {'root': 400}),
          ).map((entry) => entry.key),
          ['dm', 'dm:root'],
        );
        expect(
          unreadEntries(
            [dm],
            {},
            (_) => unread(2, 0, 500),
            (id) => threads(id, {'root': 400}),
          ).map((entry) => entry.key),
          ['dm:root'],
        );
      },
    );

    test(
      'keeps a DM card for unread replies that have no thread card, and reads it whole',
      () {
        final dm = channel('dm', channelType: 'dm');
        final entries = unreadEntries(
          [dm],
          {},
          (_) => unread(5, 0, 500),
          (id) => threads(id, {'root': 400}),
        );
        expect(entries.map((entry) => entry.key), ['dm', 'dm:root']);
        expect(entries.firstWhere((entry) => entry.key == 'dm').whole, isTrue);
      },
    );

    test('shows a thread even after its channel row went quiet', () {
      final seen = unread(2, 2, 500, null, (
        observedCount: 0,
        attentionCount: 0,
        threadCount: 0,
      ));
      expect(
        unreadEntries(
          [channel('launch')],
          {},
          (_) => seen,
          (id) => threads(id, {'root': 400}),
        ).map((entry) => entry.key),
        ['launch:root'],
      );
    });

    test('round-trips card keys', () {
      expect(parseCardKey(cardKey('launch', 'root')), (
        channelId: 'launch',
        rootId: 'root',
      ));
      expect(parseCardKey(cardKey('launch')), (
        channelId: 'launch',
        rootId: null,
      ));
    });
  });
}
