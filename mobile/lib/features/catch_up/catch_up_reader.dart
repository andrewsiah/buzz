import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/read_state/read_state_format.dart';
import '../../shared/read_state/read_state_provider.dart';
import '../channels/channels_provider.dart';
import '../channels/unread_badge/observed_unread_event.dart';
import 'catch_up_read.dart';
import 'catch_up_sources.dart';

/// Catch-up's reads over the app's shared read state ([readStateProvider]).
///
/// Every read is a synced read-state mark, the same contexts the channel
/// and thread pages, Activity and the web write, so a card read here is
/// read everywhere. Read marks only move forward, so a read has no inverse
/// of its own: Undo marks the conversation or thread unread instead, with
/// the same hand mark the channel tile's "Mark unread" uses.
class MobileCatchUpReader implements CatchUpReader {
  MobileCatchUpReader(this._ref);

  final Ref _ref;

  ReadStateNotifier get _reads => _ref.read(readStateProvider.notifier);
  CatchUpEvidence? _evidence(String channelId) =>
      _ref.read(catchUpEvidenceProvider)[channelId];

  ObservedUnreadEvent? _event(String channelId, String messageId) => _ref
      .read(channelsProvider.notifier)
      .observedUnreadEventsByChannel[channelId]?[messageId];

  @override
  Future<CatchUpReadResult> readThread(String channelId, String rootId) async {
    final replies = [
      for (final event
          in _evidence(channelId)?.unreadEvents ??
              const <ObservedUnreadEvent>[])
        if (event.rootId == rootId) event,
    ];
    final key = threadContextKey(rootId);
    if (replies.isEmpty) {
      _reads.clearForcedUnread(key);
      return const CatchUpReadResult();
    }
    _reads.markContextRead(key, replies.map((e) => e.createdAt).reduce(max));
    return const CatchUpReadResult();
  }

  @override
  Future<CatchUpReadResult> markThrough(
    CatchUpThreadTarget target,
    String messageId,
  ) async {
    final event = _event(target.channelId, messageId);
    if (event == null) throw StateError('Read target unavailable');
    _reads.markContextRead(threadContextKey(target.rootId), event.createdAt);
    return const CatchUpReadResult();
  }

  @override
  Future<CatchUpReadResult> markChannelRead(String channelId) async {
    final evidence = _evidence(channelId);
    final lastMessageAt = evidence?.channel.lastMessageAt;
    final through = [
      _ref.read(channelsProvider.notifier).latestObservedByChannel[channelId],
      evidence?.unread.latestCreatedAt,
      if (lastMessageAt != null) lastMessageAt.millisecondsSinceEpoch ~/ 1000,
    ].whereType<int>().fold<int?>(null, (a, b) => max(a ?? 0, b));
    if (through == null) {
      _reads.clearForcedUnread(channelId);
      return const CatchUpReadResult();
    }
    _reads.markContextRead(channelId, through, clearForcedMessages: true);
    _ref
        .read(channelsProvider.notifier)
        .clearObservedUnreadCoveredByRead(channelId, through);
    return const CatchUpReadResult();
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
    final readState = _ref.read(readStateProvider);
    final covered =
        max(
          readState.effectiveTimestamp(activityContextKey(channelId)) ?? -1,
          readState.effectiveTimestamp(channelId) ?? -1,
        ) >=
        cut;
    if (!covered) _reads.markContextRead(activityContextKey(channelId), cut);
    final unread = {for (final e in evidence.unreadEvents) e.id};
    for (final event in events) {
      final key = msgContextKey(event.id);
      if ((!event.channelCatchUp || readState.isForcedUnread(key)) &&
          unread.contains(event.id)) {
        _reads.markContextRead(key, event.createdAt);
      }
    }
    return const CatchUpReadResult();
  }

  @override
  Future<CatchUpReadResult> markMessagesRead(List<String> messageIds) async {
    final evidence = _ref.read(catchUpEvidenceProvider);
    final byId = {
      for (final item in evidence.values)
        for (final event in item.unreadEvents) event.id: event,
    };
    final selected = [for (final id in messageIds) byId[id]];
    if (selected.isEmpty || selected.contains(null)) {
      throw StateError('Verified readable message evidence unavailable');
    }
    for (final event in selected.cast<ObservedUnreadEvent>()) {
      _reads.markContextRead(msgContextKey(event.id), event.createdAt);
    }
    return const CatchUpReadResult();
  }

  @override
  Future<CatchUpReadResult> clearUnreadLocal(CatchUpTarget target) async {
    _reads.clearForcedUnread(_contextOf(target));
    return const CatchUpReadResult();
  }

  @override
  Future<CatchUpReadResult> markUnreadLocal(CatchUpTarget target) async {
    _reads.markContextUnread(_contextOf(target), channelId: target.channelId);
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

  static String _contextOf(CatchUpTarget target) => switch (target) {
    CatchUpChannelTarget(:final channelId) => channelId,
    CatchUpThreadTarget(:final rootId) => threadContextKey(rootId),
  };
}

final catchUpReaderProvider = Provider<CatchUpReader>(MobileCatchUpReader.new);
