/// Which conversations and threads enter Catch-up, and in what order.
///
/// A line-for-line port of Snack web's `snack-catchup/queue.ts`. The inputs
/// mirror the web's channel summary, unread snapshot and thread activity, so
/// the rules (and their tests) stay the same on both clients; the mobile
/// adapter in `catch_up_sources.dart` builds them from this app's unread
/// registry and read state.
library;

/// The channel facts Catch-up decides by (web `ChannelSummary`).
class CatchUpChannel {
  const CatchUpChannel({
    required this.id,
    this.channelType = 'stream',
    this.joined = true,
    this.huddle = false,
    this.archived = false,
    this.metadataPending = false,
    this.lastActivityAt,
  });

  final String id;

  /// `stream`, `forum`, `dm` or `system`.
  final String channelType;

  /// The viewer is a member (web: `members.includes(viewer)`).
  final bool joined;
  final bool huddle;
  final bool archived;
  final bool metadataPending;

  /// Unix seconds of the channel's newest activity, when known.
  final int? lastActivityAt;
}

/// What the channel's row shows after opening it quieted the row.
typedef CatchUpRowUnread = ({
  int observedCount,
  int attentionCount,
  int threadCount,
});

/// A channel's unread evidence (web `UnreadSnapshot`).
class CatchUpUnread {
  const CatchUpUnread({
    this.observedCount,
    this.attentionCount,
    this.manual = false,
    this.oldestUnreadId,
    this.latestCreatedAt,
    this.row,
  });

  /// Observed unread messages, never an exact total; null when unobserved.
  final int? observedCount;

  /// Unread mentions, DMs and replies in the viewer's threads.
  final int? attentionCount;

  /// Marked unread by hand (web `manual !== "none"`).
  final bool manual;

  /// The oldest unread message the channel's own timeline shows.
  final String? oldestUnreadId;

  /// Unix seconds of the newest message evidence.
  final int? latestCreatedAt;
  final CatchUpRowUnread? row;
}

/// One thread with unread replies for the viewer (web `ThreadActivityItem`).
class CatchUpThreadActivity {
  const CatchUpThreadActivity({
    required this.rootId,
    required this.latestMessageId,
    required this.createdAt,
    required this.unreadCount,
  });

  final String rootId;
  final String latestMessageId;
  final int createdAt;
  final int unreadCount;
}

/// A channel's threads with unread replies, and its unread timeline
/// mentions (web `ThreadActivitySnapshot`).
class CatchUpActivity {
  const CatchUpActivity({this.items = const [], this.mentions = const []});

  final List<CatchUpThreadActivity> items;

  /// Message ids of unread top-level mentions.
  final List<String> mentions;
}

/// Whether a channel's row shows unread (web `rowUnread`). A muted channel
/// still shows its mentions, and a muted DM still shows.
bool rowUnread(CatchUpUnread snapshot, bool dm, bool muted) {
  final observed = snapshot.row?.observedCount ?? snapshot.observedCount ?? 0;
  final attention =
      snapshot.row?.attentionCount ?? snapshot.attentionCount ?? 0;
  return snapshot.manual || (observed > 0 && (dm || !muted || attention > 0));
}

/// One card in the Catch-up stack: a conversation's top-level messages, or
/// one thread in it ([rootId]), which is its own card as in Slack.
class CatchUpEntry {
  const CatchUpEntry({
    required this.key,
    required this.channelId,
    this.rootId,
    this.latestMessageId,
    required this.dm,
    required this.attention,
    required this.count,
    required this.manual,
    this.whole = false,
    required this.latest,
  });

  /// [cardKey]`(channelId, rootId)`: what the stack orders and decides by.
  final String key;
  final String channelId;

  /// The thread this card shows; null for the conversation's own card.
  final String? rootId;

  /// A thread card's newest unread reply.
  final String? latestMessageId;
  final bool dm;

  /// Mentions of the viewer, a DM or a reply in their thread: these come first.
  final bool attention;

  /// Observed unread messages, never an exact total.
  final int count;

  /// Marked unread by hand rather than by new messages.
  final bool manual;

  /// A DM card that also stands for unread replies no thread card shows:
  /// reading it reads the whole DM so those replies never stay hidden.
  final bool whole;

  /// Unix seconds of the card's newest activity.
  final int latest;
}

/// Channel ids never hold ":", so this splits back with [parseCardKey].
String cardKey(String channelId, [String? rootId]) =>
    rootId == null || rootId.isEmpty ? channelId : '$channelId:$rootId';

({String channelId, String? rootId}) parseCardKey(String key) {
  final at = key.indexOf(':');
  return at < 0
      ? (channelId: key, rootId: null)
      : (channelId: key.substring(0, at), rootId: key.substring(at + 1));
}

/// Unread aimed at the viewer (DMs, mentions, replies in their threads, or
/// marked unread by hand), as the channel list decides unread: joined,
/// listed and not a huddle. Each thread with unread replies for the viewer
/// is its own card; the conversation keeps a card only for what its
/// timeline shows.
List<CatchUpEntry> unreadEntries(
  Iterable<CatchUpChannel> channels,
  Set<String> muted,
  CatchUpUnread Function(String channelId) snapshot,
  CatchUpActivity Function(String channelId) activity,
) {
  final entries = <CatchUpEntry>[];
  for (final channel in channels) {
    if (channel.huddle ||
        channel.archived ||
        channel.metadataPending ||
        channel.channelType == 'system' ||
        !channel.joined) {
      continue;
    }
    final dm = channel.channelType == 'dm';
    final unread = snapshot(channel.id);
    final channelActivity = activity(channel.id);
    final threads = channelActivity.items;
    // A thread with unread replies in the viewer's conversations is its own
    // card, even after the channel row went quiet. Like Slack, a muted
    // channel still brings replies in your threads.
    for (final thread in threads) {
      entries.add(
        CatchUpEntry(
          key: cardKey(channel.id, thread.rootId),
          channelId: channel.id,
          rootId: thread.rootId,
          latestMessageId: thread.latestMessageId,
          dm: dm,
          attention: true,
          count: thread.unreadCount,
          manual: false,
          latest: thread.createdAt,
        ),
      );
    }
    if (!rowUnread(unread, dm, muted.contains(channel.id))) continue;
    final shownAttention =
        unread.row?.attentionCount ?? unread.attentionCount ?? 0;
    final shownObserved = unread.row?.observedCount ?? unread.observedCount;
    final manual = unread.manual;
    // In a DM every reply is unread for the viewer, but only replies in their
    // conversations get a thread card. More unread than the thread cards
    // hold means some replies have no card: the DM's card covers them.
    final carded = threads.fold<int>(0, (sum, t) => sum + t.unreadCount);
    final whole =
        dm && threads.isNotEmpty && (unread.observedCount ?? 0) > carded;
    // Catch-up is only for what's aimed at you: DMs, mentions and replies in
    // your threads. With thread cards, the conversation's card covers only
    // its timeline: a DM's unread top-level messages, or a channel's
    // top-level mentions.
    if (!manual) {
      if (!dm && shownAttention == 0) continue;
      if (threads.isNotEmpty) {
        final timeline = dm
            ? unread.oldestUnreadId != null || whole
            : channelActivity.mentions.isNotEmpty;
        if (!timeline) continue;
      }
    }
    final latest = unread.latestCreatedAt ?? 0;
    entries.add(
      CatchUpEntry(
        key: channel.id,
        channelId: channel.id,
        dm: dm,
        attention: dm || shownAttention > 0,
        count: shownObserved ?? 0,
        manual: manual,
        whole: whole,
        latest: latest != 0 ? latest : (channel.lastActivityAt ?? 0),
      ),
    );
  }
  entries.sort((a, b) {
    final attention = (b.attention ? 1 : 0) - (a.attention ? 1 : 0);
    if (attention != 0) return attention;
    final latest = b.latest - a.latest;
    if (latest != 0) return latest;
    return a.key.compareTo(b.key);
  });
  return entries;
}

/// The stack keeps the order it first showed, so cards never reshuffle under
/// the reader: cards already in [order] keep their place (new replies update
/// them in place) and newly unread ones join the end. A card coming back (new
/// messages after the reader decided it, or unread again after it was read
/// elsewhere) also joins the end rather than jumping above the card on
/// [top], or replacing it once the reader decided it ([topDecided]). Undo's
/// cards ([restored]) keep the place Undo gave them.
List<String> stackOrder(
  List<String> order,
  Iterable<CatchUpEntry> entries, {
  String? top,
  bool topDecided = false,
  Set<String> handled = const {},
  Set<String> restored = const {},
}) {
  final known = order.toSet();
  final live = <String>{for (final entry in entries) entry.key};
  // Everything above the top card left the deck (the top too, once decided);
  // whatever shows again goes last.
  final above = top == null ? -1 : order.indexOf(top) + (topDecided ? 1 : 0);
  final back = <String>{
    for (var at = 0; at < order.length; at++)
      if (at < above &&
          live.contains(order[at]) &&
          !handled.contains(order[at]) &&
          !restored.contains(order[at]))
        order[at],
  };
  return [
    for (final key in order)
      if (!back.contains(key)) key,
    for (final key in order)
      if (back.contains(key)) key,
    for (final key in live)
      if (!known.contains(key)) key,
  ];
}
