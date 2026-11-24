/// How a Catch-up card is read, and brought back unread by Undo.
///
/// A port of Snack web's `snack-catchup/read.ts` over [CatchUpReader], the
/// handful of read-state operations it needs. The mobile implementation
/// (`catch_up_sources.dart`) writes the same synced read-state contexts the
/// web writes (`<channel>`, `activity:<channel>`, `thread:<root>`,
/// `msg:<id>`), so reading here, in the channel or on the web agree.
library;

import 'catch_up_queue.dart';

/// What a read or unread mark targets.
sealed class CatchUpTarget {
  const CatchUpTarget(this.channelId);
  final String channelId;
}

class CatchUpChannelTarget extends CatchUpTarget {
  const CatchUpChannelTarget(super.channelId);

  @override
  bool operator ==(Object other) =>
      other is CatchUpChannelTarget && other.channelId == channelId;

  @override
  int get hashCode => channelId.hashCode;
}

class CatchUpThreadTarget extends CatchUpTarget {
  const CatchUpThreadTarget(super.channelId, this.rootId);
  final String rootId;

  @override
  bool operator ==(Object other) =>
      other is CatchUpThreadTarget &&
      other.channelId == channelId &&
      other.rootId == rootId;

  @override
  int get hashCode => Object.hash(channelId, rootId);
}

/// A read's outcome; [undo] is the read's own inverse, when there is one.
class CatchUpReadResult {
  const CatchUpReadResult({this.undo});
  final Future<void> Function()? undo;

  CatchUpReadResult withoutUndo() => const CatchUpReadResult();
}

/// A top-level row of a conversation's own timeline.
typedef CatchUpTimelineRow = ({String id, bool unread});

/// The read-state operations Catch-up needs (web `session.unread` and
/// `session.channels.window`).
abstract interface class CatchUpReader {
  /// Reads one thread's replies; throws when the root can't be verified.
  Future<CatchUpReadResult> readThread(String channelId, String rootId);

  /// Reads [target] through [messageId].
  Future<CatchUpReadResult> markThrough(
    CatchUpThreadTarget target,
    String messageId,
  );

  /// Reads everything in the channel, threads included.
  Future<CatchUpReadResult> markChannelRead(String channelId);

  /// The channel's catch-up mark: ordinary messages through the newest of
  /// [messageIds], plus each unread mention, broadcast and marked message.
  /// Throws for a DM or a row it can't verify.
  Future<CatchUpReadResult> markTimelineRead(
    String channelId,
    List<String> messageIds,
  );

  /// Reads exactly these messages.
  Future<CatchUpReadResult> markMessagesRead(List<String> messageIds);

  Future<CatchUpReadResult> clearUnreadLocal(CatchUpTarget target);
  Future<CatchUpReadResult> markUnreadLocal(CatchUpTarget target);

  /// The conversation's own top-level rows (no replies), oldest first.
  List<CatchUpTimelineRow> timelineRows(String channelId);

  /// Unread top-level mentions of the viewer in [channelId].
  List<String> timelineMentions(String channelId);

  /// Writes any reads still waiting (see `catchUpReadDelay`) now.
  void flush();
}

/// Reads one card and nothing its other cards show; null when nothing was
/// left to read, so Undo marks nothing. A thread reads its replies. A
/// conversation whose threads have their own cards reads its own timeline
/// (and clears its hand mark), never its replies, so those threads stay.
Future<CatchUpReadResult?> readCard(
  CatchUpReader reader,
  String key,
  List<CatchUpEntry> entries,
) async {
  final (:channelId, :rootId) = parseCardKey(key);
  final entry = entries.where((item) => item.key == key).firstOrNull;
  if (rootId != null) {
    try {
      return await reader.readThread(channelId, rootId);
    } catch (_) {
      // The root cannot be verified (deleted, not retained): read the
      // replies through the newest one instead.
      final latest = entry?.latestMessageId;
      if (latest == null) rethrow;
      return reader.markThrough(CatchUpThreadTarget(channelId, rootId), latest);
    }
  }
  final threads = entries.any(
    (item) => item.channelId == channelId && item.rootId != null,
  );
  // A DM with unread replies no card shows reads whole, as before thread cards.
  if (!threads || (entry?.whole ?? false)) {
    return reader.markChannelRead(channelId);
  }
  // Its threads have their own cards: read the conversation's own messages,
  // never its replies. Reading the whole channel would read those threads.
  final rows = reader.timelineRows(channelId);
  CatchUpReadResult? result;
  if (!(entry?.dm ?? false) && rows.isNotEmpty) {
    try {
      result = await reader.markTimelineRead(channelId, [
        for (final row in rows) row.id,
      ]);
    } catch (_) {
      // A DM or an unverified row: read only the unread messages shown.
    }
  }
  if (result == null) {
    final shown = <String>{
      for (final row in rows)
        if (row.unread) row.id,
      ...reader.timelineMentions(channelId),
    }.toList();
    if (shown.isNotEmpty) result = await reader.markMessagesRead(shown);
  }
  if (!(entry?.manual ?? false)) return result;
  // A hand mark clears too. That later write expires the read's undo, so
  // Undo marks the conversation unread instead.
  final cleared = await reader.clearUnreadLocal(
    CatchUpChannelTarget(channelId),
  );
  return (result ?? cleared).withoutUndo();
}

/// Brings a read card back unread: the read's own inverse, else a mark on
/// the card's own conversation or thread.
Future<void> unreadCard(
  CatchUpReader reader,
  String key,
  Future<void> Function()? undo,
) async {
  if (undo != null) return undo();
  final (:channelId, :rootId) = parseCardKey(key);
  await reader.markUnreadLocal(
    rootId != null
        ? CatchUpThreadTarget(channelId, rootId)
        : CatchUpChannelTarget(channelId),
  );
}
