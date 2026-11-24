// Ported from Snack web's `snack-catchup/read.test.ts`, case for case.
import 'package:buzz/features/catch_up/catch_up_queue.dart';
import 'package:buzz/features/catch_up/catch_up_read.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Row = ({String id, bool unread, String? threadRootId});

class FakeReader implements CatchUpReader {
  FakeReader([this.rows = const []]);

  final List<Row> rows;
  final calls = <String, List<Object?>>{};
  Object? threadError;
  List<String> mentions = ['m-mention'];

  bool called(String name) => calls.containsKey(name);

  Future<CatchUpReadResult> _record(
    String name,
    Object? args, [
    CatchUpReadResult result = const CatchUpReadResult(),
  ]) async {
    calls[name] = [args];
    return result;
  }

  @override
  Future<CatchUpReadResult> readThread(String channelId, String rootId) {
    calls['readThread'] = [channelId, rootId];
    if (threadError != null) return Future.error(threadError!);
    return Future.value(const CatchUpReadResult());
  }

  @override
  Future<CatchUpReadResult> markThrough(
    CatchUpThreadTarget target,
    String messageId,
  ) {
    calls['markThrough'] = [target, messageId];
    return Future.value(const CatchUpReadResult());
  }

  @override
  Future<CatchUpReadResult> markChannelRead(String channelId) =>
      _record('markChannelRead', channelId);

  @override
  Future<CatchUpReadResult> markTimelineRead(
    String channelId,
    List<String> messageIds,
  ) {
    calls['markTimelineRead'] = [channelId, messageIds];
    return Future.value(CatchUpReadResult(undo: () async {}));
  }

  @override
  Future<CatchUpReadResult> markMessagesRead(List<String> messageIds) =>
      _record('markMessagesRead', messageIds);

  @override
  Future<CatchUpReadResult> clearUnreadLocal(CatchUpTarget target) =>
      _record('clearUnreadLocal', target);

  @override
  Future<CatchUpReadResult> markUnreadLocal(CatchUpTarget target) =>
      _record('markUnreadLocal', target);

  @override
  List<CatchUpTimelineRow> timelineRows(String channelId) => [
    for (final row in rows)
      if (row.threadRootId == null) (id: row.id, unread: row.unread),
  ];

  @override
  List<String> timelineMentions(String channelId) => mentions;

  @override
  void flush() => calls['flush'] = const [];
}

CatchUpEntry entry({
  String channelId = 'c',
  String? rootId,
  String? latestMessageId,
  bool dm = false,
  bool manual = false,
  bool whole = false,
}) => CatchUpEntry(
  key: cardKey(channelId, rootId),
  channelId: channelId,
  rootId: rootId,
  latestMessageId: latestMessageId,
  dm: dm,
  attention: false,
  count: 1,
  manual: manual,
  whole: whole,
  latest: 0,
);

Row row(String id, bool unread, [String? threadRootId]) =>
    (id: id, unread: unread, threadRootId: threadRootId);

void main() {
  group('readCard', () {
    test("reads a thread card's replies only", () async {
      final reader = FakeReader();
      await readCard(reader, cardKey('c', 'r'), [entry(rootId: 'r')]);
      expect(reader.calls['readThread'], ['c', 'r']);
      expect(reader.called('markChannelRead'), isFalse);
    });

    test(
      "falls back to the newest reply when the root can't be verified",
      () async {
        final reader = FakeReader()..threadError = StateError('gone');
        await readCard(reader, cardKey('c', 'r'), [
          entry(rootId: 'r', latestMessageId: 'm9'),
        ]);
        expect(reader.calls['markThrough'], [
          const CatchUpThreadTarget('c', 'r'),
          'm9',
        ]);
      },
    );

    test('reads the whole channel when no thread has its own card', () async {
      final reader = FakeReader();
      await readCard(reader, cardKey('c'), [entry()]);
      expect(reader.calls['markChannelRead'], ['c']);
    });

    test(
      "reads the conversation's own messages, not its threads, when threads have their own cards",
      () async {
        final reader = FakeReader([
          row('m1', true),
          row('m2', false),
          row('b1', true, 'r'),
        ]);
        final result = await readCard(reader, cardKey('c'), [
          entry(),
          entry(rootId: 'r'),
        ]);
        expect(reader.calls['markTimelineRead'], [
          'c',
          ['m1', 'm2'],
        ]);
        expect(reader.called('markChannelRead'), isFalse);
        expect(reader.called('clearUnreadLocal'), isFalse);
        expect(result?.undo, isNotNull);
      },
    );

    test(
      'reads only the unread messages shown in a DM with thread cards',
      () async {
        final reader = FakeReader([row('m1', true), row('m2', false)]);
        await readCard(reader, cardKey('c'), [
          entry(dm: true),
          entry(rootId: 'r', dm: true),
        ]);
        expect(reader.called('markTimelineRead'), isFalse);
        expect(reader.calls['markMessagesRead'], [
          ['m1', 'm-mention'],
        ]);
        expect(reader.called('markChannelRead'), isFalse);
      },
    );

    test(
      'reads the whole DM when its card covers replies with no card',
      () async {
        final reader = FakeReader([row('m1', false)]);
        await readCard(reader, cardKey('c'), [
          entry(dm: true, whole: true),
          entry(rootId: 'r', dm: true),
        ]);
        expect(reader.calls['markChannelRead'], ['c']);
        expect(reader.called('markMessagesRead'), isFalse);
      },
    );

    test(
      'clears a hand mark without reading the threads, and drops the expired undo',
      () async {
        final reader = FakeReader([row('m1', true)]);
        final result = await readCard(reader, cardKey('c'), [
          entry(manual: true),
          entry(rootId: 'r'),
        ]);
        expect(reader.calls['clearUnreadLocal'], [
          const CatchUpChannelTarget('c'),
        ]);
        expect(reader.called('markChannelRead'), isFalse);
        expect(result?.undo, isNull);
      },
    );

    test(
      'never reads the whole channel when nothing is shown but threads have cards',
      () async {
        final reader = FakeReader()..mentions = [];
        await readCard(reader, cardKey('c'), [
          entry(manual: true),
          entry(rootId: 'r'),
        ]);
        expect(reader.called('markChannelRead'), isFalse);
        expect(reader.called('clearUnreadLocal'), isTrue);
      },
    );

    test(
      'reports nothing read when an unmarked card has nothing left',
      () async {
        final reader = FakeReader()..mentions = [];
        final result = await readCard(reader, cardKey('c'), [
          entry(),
          entry(rootId: 'r'),
        ]);
        expect(result, isNull);
        expect(reader.called('clearUnreadLocal'), isFalse);
        expect(reader.called('markChannelRead'), isFalse);
      },
    );
  });

  group('unreadCard', () {
    test("prefers the read's own undo", () async {
      final reader = FakeReader();
      var undone = false;
      await unreadCard(reader, cardKey('c', 'r'), () async => undone = true);
      expect(undone, isTrue);
      expect(reader.called('markUnreadLocal'), isFalse);
    });

    test('marks the thread unread without an undo', () async {
      final reader = FakeReader();
      await unreadCard(reader, cardKey('c', 'r'), null);
      expect(reader.calls['markUnreadLocal'], [
        const CatchUpThreadTarget('c', 'r'),
      ]);
    });
  });
}
