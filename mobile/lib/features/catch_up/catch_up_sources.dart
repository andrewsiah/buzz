import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/read_state/read_state_format.dart';
import '../../shared/read_state/read_state_provider.dart';
import '../channels/channel.dart';
import '../channels/channel_mutes/channel_mutes_provider.dart';
import '../channels/channels_provider.dart';
import '../channels/unread_badge/observed_unread_event.dart';
import 'catch_up_queue.dart';

/// One channel's unread evidence in Catch-up's terms, derived from the same
/// observed-unread registry and read marks that drive the channel list's
/// highlights and the app badge. Nothing here fetches.
class CatchUpEvidence {
  const CatchUpEvidence({
    required this.channel,
    required this.unread,
    required this.activity,
    required this.unreadEvents,
    this.ownMarkReads = const [],
    this.handMarked = false,
  });

  final Channel channel;
  final CatchUpUnread unread;
  final CatchUpActivity activity;

  /// The channel's unread observed events, oldest first.
  final List<ObservedUnreadEvent> unreadEvents;

  /// When each observed event read by its own `msg:` mark was posted: a mark
  /// that never syncs (a mention read in Catch-up).
  final List<int> ownMarkReads;

  /// The newest of [ownMarkReads] posted [before] that time (any, if null).
  int? ownMarkReadThrough({int? before}) => ownMarkReads
      .where((at) => before == null || at < before)
      .fold<int?>(null, (newest, at) => max(newest ?? at, at));

  /// A hand mark on the channel, one of its threads or one of its messages.
  final bool handMarked;

  /// Unread top-level events: what the conversation's own timeline shows.
  Iterable<ObservedUnreadEvent> get timelineEvents =>
      unreadEvents.where((event) => event.rootId == null);
}

/// Builds [channel]'s evidence from its observed [events] and read marks.
///
/// - A reply in a thread (not a broadcast) belongs to that thread's card.
///   The registry only holds replies in the viewer's threads, followed
///   threads, and replies that mention them, the same as web's thread
///   activity.
/// - Attention follows the channel list's attention dot: a DM, a mention or
///   broadcast, or a reply in the viewer's thread
///   (`computeChannelListHighlights`).
/// - A hand mark ([forcedUnreadContexts]) on the channel or one of its
///   messages makes the conversation "marked unread".
CatchUpEvidence buildCatchUpEvidence({
  required Channel channel,
  required Map<String, ObservedUnreadEvent>? events,
  required int? Function(String contextId) markerOf,
  required Map<String, String> forcedUnreadContexts,
}) {
  final unreadEvents = <ObservedUnreadEvent>[
    for (final event in events?.values ?? const <ObservedUnreadEvent>[])
      if (_isUnread(event, channel.id, markerOf)) event,
  ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  final threads = <String, List<ObservedUnreadEvent>>{};
  for (final event in unreadEvents) {
    final rootId = event.rootId;
    if (rootId != null) threads.putIfAbsent(rootId, () => []).add(event);
  }
  final timeline = unreadEvents.where((event) => event.rootId == null);
  final attention = unreadEvents
      .where((event) => channel.isDm || !event.channelCatchUp)
      .length;
  final manual = forcedUnreadContexts.entries.any(
    (forced) =>
        forced.value == channel.id &&
        !forced.key.startsWith(threadContextPrefix),
  );
  final ownMarkReads = [
    for (final event in events?.values ?? const <ObservedUnreadEvent>[])
      if ((markerOf(msgContextKey(event.id)) ?? -1) >= event.createdAt)
        event.createdAt,
  ];
  int? latest;
  for (final event in unreadEvents) {
    latest = max(latest ?? 0, event.createdAt);
  }

  return CatchUpEvidence(
    channel: channel,
    unreadEvents: unreadEvents,
    ownMarkReads: ownMarkReads,
    handMarked: forcedUnreadContexts.values.contains(channel.id),
    unread: CatchUpUnread(
      observedCount: unreadEvents.length,
      attentionCount: attention,
      manual: manual,
      oldestUnreadId: timeline.firstOrNull?.id,
      latestCreatedAt: latest,
    ),
    activity: CatchUpActivity(
      items: [
        for (final MapEntry(key: rootId, value: replies) in threads.entries)
          CatchUpThreadActivity(
            rootId: rootId,
            latestMessageId: replies.last.id,
            createdAt: replies.last.createdAt,
            unreadCount: replies.length,
          ),
      ],
      mentions: [
        for (final event in timeline)
          if (event.highPriority && !channel.isDm) event.id,
      ],
    ),
  );
}

bool _isUnread(
  ObservedUnreadEvent event,
  String channelId,
  int? Function(String contextId) markerOf,
) {
  final readAt = observedUnreadEventReadAt(event, channelId, markerOf);
  return readAt == null || event.createdAt > readAt;
}

CatchUpChannel catchUpChannelOf(Channel channel) => CatchUpChannel(
  id: channel.id,
  channelType: channel.channelType,
  joined: channel.isMember,
  archived: channel.isArchived,
  lastActivityAt: channel.lastMessageAt == null
      ? null
      : channel.lastMessageAt!.millisecondsSinceEpoch ~/ 1000,
);

/// Every listed channel's Catch-up evidence, by channel id. Empty until the
/// read state is ready, like the channel list's unread badge.
final catchUpEvidenceProvider = Provider<Map<String, CatchUpEvidence>>((ref) {
  final channels = ref.watch(channelsProvider).value;
  final readState = ref.watch(readStateProvider);
  if (channels == null || !readState.isReady) return const {};
  final notifier = ref.read(channelsProvider.notifier);
  final observed = notifier.observedUnreadEventsByChannel;
  return {
    for (final channel in channels)
      channel.id: buildCatchUpEvidence(
        channel: channel,
        events: observed[channel.id],
        markerOf: readState.effectiveTimestamp,
        forcedUnreadContexts: readState.forcedUnreadContexts,
      ),
  };
});

/// The listed channels, for card titles and opening a conversation.
final catchUpChannelsProvider = Provider<List<Channel>>(
  (ref) => ref.watch(channelsProvider).value ?? const [],
);

/// Channels the viewer muted.
final catchUpMutedChannelIdsProvider = Provider<Set<String>>((ref) {
  final store = ref.watch(channelMutesProvider).store;
  return {
    for (final entry in store.channels.entries)
      if (entry.value.muted) entry.key,
  };
});

/// The Catch-up queue, before the stack's own ordering.
final catchUpEntriesProvider = Provider<List<CatchUpEntry>>((ref) {
  final evidence = ref.watch(catchUpEvidenceProvider);
  if (evidence.isEmpty) return const [];
  return unreadEntries(
    [for (final item in evidence.values) catchUpChannelOf(item.channel)],
    ref.watch(catchUpMutedChannelIdsProvider),
    (channelId) => evidence[channelId]!.unread,
    (channelId) => evidence[channelId]!.activity,
  );
});

/// Cards (conversations and threads) waiting in Catch-up, for the home
/// entry's badge (web `CatchUpBadge`).
final catchUpBadgeCountProvider = Provider<int>(
  (ref) => ref.watch(catchUpEntriesProvider).length,
);

/// Whether the queue is still being worked out.
final catchUpLoadingProvider = Provider<bool>((ref) {
  final channels = ref.watch(channelsProvider);
  final readState = ref.watch(readStateProvider);
  return !channels.hasValue || !readState.isReady;
});
