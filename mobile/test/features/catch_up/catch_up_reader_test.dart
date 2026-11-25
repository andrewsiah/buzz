// The mobile reader: a card's read waits so Undo can cancel it, reads only
// what the card stood for, and never hand-marks a thread.
import 'package:buzz/features/catch_up/catch_up_queue.dart';
import 'package:buzz/features/catch_up/catch_up_read.dart';
import 'package:buzz/features/catch_up/catch_up_reader.dart';
import 'package:buzz/features/catch_up/catch_up_sources.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/unread_badge/observed_unread_event.dart';
import 'package:buzz/shared/read_state/read_state_provider.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

class RecordingWrites implements CatchUpReadWrites {
  final log = <String>[];

  @override
  void markContextRead(
    String contextId,
    int unixTimestamp, {
    bool clearForcedMessages = false,
  }) => log.add('read $contextId@$unixTimestamp');

  @override
  void clearForcedUnread(String contextId) => log.add('clear $contextId');

  @override
  void markContextUnread(String contextId, {required String channelId}) =>
      log.add('unread $contextId');

  @override
  void clearObservedUnreadCoveredByRead(String channelId, int readAt) {}
}

Channel channel(String id) => Channel(
  id: id,
  name: id,
  channelType: 'dm',
  visibility: 'private',
  description: '',
  createdBy: 'x',
  createdAt: DateTime(2025),
  memberCount: 2,
  isMember: true,
  lastMessageAt: DateTime.fromMillisecondsSinceEpoch(900 * 1000),
);

ObservedUnreadEvent event(String id, int createdAt, {String? rootId}) =>
    makeObservedUnreadEvent(
      id: id,
      createdAt: createdAt,
      rootId: rootId,
      highPriority: true,
      channelType: 'dm',
      isThreadedReply: rootId != null,
    );

void main() {
  late List<ObservedUnreadEvent> events;
  late RecordingWrites writes;
  late MobileCatchUpReader reader;

  setUp(() {
    events = [event('d1', 100), event('r1', 200, rootId: 'root')];
    writes = RecordingWrites();
    reader = MobileCatchUpReader(
      evidence: () => {
        'dm': buildCatchUpEvidence(
          channel: channel('dm'),
          events: {for (final e in events) e.id: e},
          markerOf: (_) => null,
          forcedUnreadContexts: const {},
        ),
      },
      readState: () => const ReadStateState.inert(),
      writes: writes,
    );
  });

  test('writes a read only after the delay, and only what the card showed', () {
    fakeAsync((async) {
      reader.markChannelRead('dm');
      // A message arriving while the card was on screen is not read.
      events = [...events, event('d2', 800)];
      async.elapse(catchUpReadDelay - const Duration(milliseconds: 1));
      expect(writes.log, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(writes.log, ['read dm@200']);
    });
  });

  test('Undo before the write cancels it, so nothing is marked unread', () {
    fakeAsync((async) {
      final entries = [
        const CatchUpEntry(
          key: 'dm',
          channelId: 'dm',
          dm: true,
          attention: true,
          count: 1,
          manual: false,
          latest: 100,
        ),
      ];
      late CatchUpReadResult? result;
      readCard(reader, 'dm', entries).then((value) => result = value);
      async.flushMicrotasks();
      unreadCard(reader, 'dm', result?.undo);
      async.elapse(catchUpReadDelay * 2);
      expect(writes.log, isEmpty);

      // A thread's undo cancels too, and never leaves a hand mark.
      reader.readThread('dm', 'root');
      unreadCard(reader, cardKey('dm', 'root'), null);
      async.elapse(catchUpReadDelay * 2);
      expect(writes.log, isEmpty);
    });
  });

  test('Undo after the write marks a conversation unread, never a thread', () {
    fakeAsync((async) {
      reader.markChannelRead('dm');
      reader.readThread('dm', 'root');
      reader.flush();
      expect(writes.log, ['read dm@200', 'read thread:root@200']);
      unreadCard(reader, 'dm', null);
      unreadCard(reader, cardKey('dm', 'root'), null);
      async.flushMicrotasks();
      expect(writes.log.skip(2), ['unread dm']);
      async.elapse(catchUpReadDelay * 2);
      expect(writes.log, hasLength(3));
    });
  });

  // SNACK: a mention read in Catch-up is read by its own `msg:` mark, which
  // never syncs; the web or a reinstall showed it unread again.
  group('a mention marked read stays read on every device', () {
    ObservedUnreadEvent streamEvent(
      String id,
      int createdAt, {
      String? rootId,
      bool mention = false,
    }) => makeObservedUnreadEvent(
      id: id,
      createdAt: createdAt,
      rootId: rootId,
      highPriority: mention || rootId != null,
      channelType: 'stream',
      isThreadedReply: rootId != null,
    );

    late Map<String, int> marks;
    late Map<String, String> forced;
    late MobileCatchUpReader streamReader;
    late RecordingWrites log;

    void build(List<ObservedUnreadEvent> observed) {
      marks = {};
      forced = {};
      log = _MarkingWrites(marks);
      streamReader = MobileCatchUpReader(
        evidence: () => {
          'room': buildCatchUpEvidence(
            channel: Channel(
              id: 'room',
              name: 'room',
              channelType: 'stream',
              visibility: 'open',
              description: '',
              createdBy: 'x',
              createdAt: DateTime(2025),
              memberCount: 2,
              isMember: true,
            ),
            events: {for (final e in observed) e.id: e},
            markerOf: (context) => marks[context],
            forcedUnreadContexts: forced,
          ),
        },
        readState: () => const ReadStateState.inert(),
        writes: log,
      );
    }

    const entries = [
      CatchUpEntry(
        key: 'room',
        channelId: 'room',
        dm: false,
        attention: true,
        count: 1,
        manual: false,
        latest: 0,
      ),
      CatchUpEntry(
        key: 'room:root',
        channelId: 'room',
        rootId: 'root',
        dm: false,
        attention: true,
        count: 1,
        manual: false,
        latest: 0,
      ),
    ];

    for (final (name, replyAt, mentionAt) in [
      ('newer than an unread reply', 120, 130),
      ('older than an unread reply', 130, 120),
    ]) {
      test('a mention $name', () {
        fakeAsync((async) {
          build([
            streamEvent('r1', replyAt, rootId: 'root'),
            streamEvent('m1', mentionAt, mention: true),
          ]);
          readCard(streamReader, 'room', entries);
          async.flushMicrotasks();
          streamReader.flush();
          expect(log.log, contains('read msg:m1@$mentionAt'));
          // The channel's synced mark reads the mention, never the reply.
          final channelReads = log.log.where((l) => l.startsWith('read room@'));
          if (mentionAt < replyAt) {
            expect(channelReads, ['read room@$mentionAt']);
          } else {
            expect(channelReads, isEmpty);
          }

          // Reading the thread card syncs the mention once nothing older is
          // unread.
          readCard(streamReader, 'room:root', entries);
          async.flushMicrotasks();
          streamReader.flush();
          expect(log.log.last, 'read room@$mentionAt');
        });
      });
    }

    test('a hand mark anywhere in the channel holds it back', () {
      fakeAsync((async) {
        build([streamEvent('m1', 130, mention: true)]);
        forced['thread:other'] = 'room';
        readCard(streamReader, 'room', entries);
        async.flushMicrotasks();
        streamReader.flush();
        expect(log.log.where((l) => l.startsWith('read room@')), isEmpty);
      });
    });
  });
}

class _MarkingWrites extends RecordingWrites {
  _MarkingWrites(this.marks);
  final Map<String, int> marks;

  @override
  void markContextRead(
    String contextId,
    int unixTimestamp, {
    bool clearForcedMessages = false,
  }) {
    super.markContextRead(contextId, unixTimestamp);
    marks[contextId] = unixTimestamp;
  }
}
