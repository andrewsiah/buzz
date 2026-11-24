import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/community/community_provider.dart';
import '../../shared/read_state/read_state_format.dart';
import '../../shared/read_state/read_state_provider.dart';
import '../../shared/relay/relay.dart';
import '../channels/channels_provider.dart';
import '../channels/unread_badge/observed_unread_event.dart';
import 'catch_up_queue.dart';
import 'catch_up_read.dart';
import 'catch_up_sources.dart';

/// How long a card's read waits before it is written, so Undo can cancel
/// it and nothing ever has to be marked unread again.
const catchUpReadDelay = Duration(seconds: 5);

/// The read-state writes Catch-up makes: the shared read state's own
/// operations, so a card read here is the same synced mark the channel and
/// thread pages, Activity and the web write.
abstract interface class CatchUpReadWrites {
  void markContextRead(
    String contextId,
    int unixTimestamp, {
    bool clearForcedMessages = false,
  });
  void clearForcedUnread(String contextId);
  void markContextUnread(String contextId, {required String channelId});
  void clearObservedUnreadCoveredByRead(String channelId, int readAt);
}

class _AppReadWrites implements CatchUpReadWrites {
  _AppReadWrites(this._ref);
  final Ref _ref;

  @override
  void markContextRead(
    String contextId,
    int unixTimestamp, {
    bool clearForcedMessages = false,
  }) => _ref
      .read(readStateProvider.notifier)
      .markContextRead(
        contextId,
        unixTimestamp,
        clearForcedMessages: clearForcedMessages,
      );

  @override
  void clearForcedUnread(String contextId) =>
      _ref.read(readStateProvider.notifier).clearForcedUnread(contextId);

  @override
  void markContextUnread(String contextId, {required String channelId}) => _ref
      .read(readStateProvider.notifier)
      .markContextUnread(contextId, channelId: channelId);

  @override
  void clearObservedUnreadCoveredByRead(String channelId, int readAt) => _ref
      .read(channelsProvider.notifier)
      .clearObservedUnreadCoveredByRead(channelId, readAt);
}

class _Pending {
  _Pending(this.timer);
  final Timer timer;
  final writes = <void Function()>[];
}

/// Catch-up's reads over the app's shared read state.
///
/// Each read is decided now, from the evidence the card showed, and written
/// [delay] later as synced read-state marks (`<channel>`,
/// `activity:<channel>`, `thread:<root>`, `msg:<id>`). Undo within that time
/// cancels the write, so the card simply stays unread everywhere; read marks
/// only move forward, so there is nothing to take back. [flush] writes
/// everything waiting at once (leaving Catch-up, the app pausing).
class MobileCatchUpReader implements CatchUpReader {
  MobileCatchUpReader({
    required Map<String, CatchUpEvidence> Function() evidence,
    required ReadStateState Function() readState,
    required CatchUpReadWrites writes,
    this.delay = catchUpReadDelay,
  }) : _evidenceOf = evidence,
       _readState = readState,
       _writes = writes;

  final Map<String, CatchUpEvidence> Function() _evidenceOf;
  final ReadStateState Function() _readState;
  final CatchUpReadWrites _writes;
  final Duration delay;

  /// Writes waiting per card key, in order.
  final _pending = <String, _Pending>{};

  /// Whether a read of [key] is waiting to be written.
  bool isPending(String key) => _pending.containsKey(key);

  CatchUpEvidence? _evidence(String channelId) => _evidenceOf()[channelId];

  ObservedUnreadEvent? _event(String channelId, String messageId) => _evidence(
    channelId,
  )?.unreadEvents.where((e) => e.id == messageId).firstOrNull;

  /// Queues [write] for card [key] and returns the read, whose undo cancels
  /// everything still waiting for that card.
  CatchUpReadResult _defer(String key, void Function() write) {
    final pending = _pending.putIfAbsent(
      key,
      () => _Pending(Timer(delay, () => _commit(key))),
    );
    pending.writes.add(write);
    final (:channelId, :rootId) = parseCardKey(key);
    return CatchUpReadResult(
      undo: () => markUnreadLocal(
        rootId == null
            ? CatchUpChannelTarget(channelId)
            : CatchUpThreadTarget(channelId, rootId),
      ),
    );
  }

  void _commit(String key) {
    final pending = _pending.remove(key);
    if (pending == null) return;
    pending.timer.cancel();
    for (final write in pending.writes) {
      write();
    }
  }

  /// Drops [key]'s waiting writes; returns whether any were waiting.
  bool cancel(String key) {
    final pending = _pending.remove(key);
    pending?.timer.cancel();
    return pending != null;
  }

  @override
  void flush() {
    for (final key in [..._pending.keys]) {
      _commit(key);
    }
  }

  /// Drops every waiting read without writing it.
  void dispose() {
    for (final pending in _pending.values) {
      pending.timer.cancel();
    }
    _pending.clear();
  }

  @override
  Future<CatchUpReadResult> readThread(String channelId, String rootId) async {
    final contextId = threadContextKey(rootId);
    final through = [
      for (final event
          in _evidence(channelId)?.unreadEvents ??
              const <ObservedUnreadEvent>[])
        if (event.rootId == rootId) event.createdAt,
    ].fold<int?>(null, (at, t) => max(at ?? t, t));
    return _defer(cardKey(channelId, rootId), () {
      if (through == null) {
        _writes.clearForcedUnread(contextId);
      } else {
        _writes.markContextRead(contextId, through);
      }
    });
  }

  @override
  Future<CatchUpReadResult> markThrough(
    CatchUpThreadTarget target,
    String messageId,
  ) async {
    final event = _event(target.channelId, messageId);
    if (event == null) throw StateError('Read target unavailable');
    return _defer(
      cardKey(target.channelId, target.rootId),
      () => _writes.markContextRead(
        threadContextKey(target.rootId),
        event.createdAt,
      ),
    );
  }

  /// Reads the channel through the newest unread message the card stood for
  /// when the reader decided, never a message that arrived after it.
  @override
  Future<CatchUpReadResult> markChannelRead(String channelId) async {
    final through = _evidence(channelId)?.unread.latestCreatedAt;
    return _defer(channelId, () {
      if (through == null) {
        _writes.clearForcedUnread(channelId);
        return;
      }
      _writes.markContextRead(channelId, through, clearForcedMessages: true);
      _writes.clearObservedUnreadCoveredByRead(channelId, through);
    });
  }

  @override
  Future<CatchUpReadResult> markTimelineRead(
    String channelId,
    List<String> messageIds,
  ) async {
    final evidence = _evidence(channelId);
    // A DM's catch-up is its channel read, never `activity:`.
    if (evidence == null || evidence.channel.isDm) {
      throw StateError('Read target unavailable');
    }
    final shown = [for (final id in messageIds) _event(channelId, id)];
    if (shown.isEmpty || shown.any((e) => e == null || e.rootId != null)) {
      throw StateError('A thread reply cannot advance the channel frontier');
    }
    final events = shown.cast<ObservedUnreadEvent>();
    final cut = events
        .where((e) => e.channelCatchUp)
        .fold<int>(-1, (at, e) => max(at, e.createdAt));
    final readState = _readState();
    final covered =
        max(
          readState.effectiveTimestamp(activityContextKey(channelId)) ?? -1,
          readState.effectiveTimestamp(channelId) ?? -1,
        ) >=
        cut;
    final marks = [
      for (final event in events)
        if (!event.channelCatchUp ||
            readState.isForcedUnread(msgContextKey(event.id)))
          event,
    ];
    return _defer(channelId, () {
      if (!covered) _writes.markContextRead(activityContextKey(channelId), cut);
      for (final event in marks) {
        _writes.markContextRead(msgContextKey(event.id), event.createdAt);
      }
    });
  }

  @override
  Future<CatchUpReadResult> markMessagesRead(List<String> messageIds) async {
    final byId = {
      for (final item in _evidenceOf().values)
        for (final event in item.unreadEvents)
          event.id: (channelId: item.channel.id, event: event),
    };
    final selected = [for (final id in messageIds) byId[id]];
    if (selected.isEmpty || selected.contains(null)) {
      throw StateError('Verified readable message evidence unavailable');
    }
    final found = selected.nonNulls.toList();
    CatchUpReadResult? result;
    for (final channelId in {for (final s in found) s.channelId}) {
      result = _defer(channelId, () {
        for (final s in found) {
          if (s.channelId != channelId) continue;
          _writes.markContextRead(msgContextKey(s.event.id), s.event.createdAt);
        }
      });
    }
    return result!;
  }

  @override
  Future<CatchUpReadResult> clearUnreadLocal(CatchUpTarget target) async =>
      _defer(
        _keyOf(target),
        () => _writes.clearForcedUnread(_contextOf(target)),
      );

  /// Undo without the read's own inverse: cancels the card's waiting read,
  /// so the card is unread as it was. A read already written stays; a
  /// conversation then gets the channel tile's "Mark unread" hand mark,
  /// while a thread does not, since a thread's hand mark would bold its whole
  /// channel and outlive reading the thread.
  @override
  Future<CatchUpReadResult> markUnreadLocal(CatchUpTarget target) async {
    if (cancel(_keyOf(target))) return const CatchUpReadResult();
    if (target is CatchUpChannelTarget) {
      _writes.markContextUnread(target.channelId, channelId: target.channelId);
    }
    return const CatchUpReadResult();
  }

  @override
  List<CatchUpTimelineRow> timelineRows(String channelId) => [
    for (final event
        in _evidence(channelId)?.timelineEvents ??
            const <ObservedUnreadEvent>[])
      (id: event.id, unread: true),
  ];

  @override
  List<String> timelineMentions(String channelId) =>
      _evidence(channelId)?.activity.mentions ?? const [];

  static String _keyOf(CatchUpTarget target) => switch (target) {
    CatchUpChannelTarget(:final channelId) => channelId,
    CatchUpThreadTarget(:final channelId, :final rootId) => cardKey(
      channelId,
      rootId,
    ),
  };

  static String _contextOf(CatchUpTarget target) => switch (target) {
    CatchUpChannelTarget(:final channelId) => channelId,
    CatchUpThreadTarget(:final rootId) => threadContextKey(rootId),
  };
}

final catchUpReaderProvider = Provider<CatchUpReader>((ref) {
  // Another community or account gets its own reader.
  ref.watch(activeCommunityProvider.select((value) => value.value?.id));
  ref.watch(myPubkeyProvider);
  final reader = MobileCatchUpReader(
    evidence: () => ref.read(catchUpEvidenceProvider),
    readState: () => ref.read(readStateProvider),
    writes: _AppReadWrites(ref),
  );
  // Write what is waiting before the app may be suspended or killed.
  ref.listen(appLifecycleProvider, (_, next) {
    if (next != AppLifecycleState.resumed) reader.flush();
  });
  ref.onDispose(reader.dispose);
  return reader;
});
