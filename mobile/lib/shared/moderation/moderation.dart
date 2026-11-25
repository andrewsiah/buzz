import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/theme_provider.dart' show savedPrefsProvider;

/// What this device hides: people the user blocked and messages they
/// reported. Kept on the device; reports also go to Snack (see
/// [SnackAccount.report]) so a person reviews them.
@immutable
class ModerationState {
  const ModerationState({
    this.blocked = const {},
    this.hiddenMessages = const {},
  });

  /// Blocked hex pubkeys (lowercase) → the name shown when they were blocked.
  final Map<String, String> blocked;

  /// Event ids the user reported; hidden from every timeline.
  final Set<String> hiddenMessages;

  static const empty = ModerationState();

  bool isBlocked(String pubkey) => blocked.containsKey(pubkey.toLowerCase());

  /// Whether a message by [pubkey] with [eventId] should not be shown.
  bool hides(String eventId, String pubkey) =>
      hiddenMessages.contains(eventId) || isBlocked(pubkey);

  bool get isEmpty => blocked.isEmpty && hiddenMessages.isEmpty;

  Map<String, Object?> toJson() => {
    'blocked': blocked,
    'hidden': hiddenMessages.toList(),
  };

  factory ModerationState.fromJson(Object? json) {
    if (json is! Map) return empty;
    final blocked = <String, String>{};
    final rawBlocked = json['blocked'];
    if (rawBlocked is Map) {
      rawBlocked.forEach((key, value) {
        if (key is String && _hex64.hasMatch(key)) {
          blocked[key.toLowerCase()] = value is String ? value : '';
        }
      });
    }
    final hidden = <String>{};
    final rawHidden = json['hidden'];
    if (rawHidden is List) {
      for (final id in rawHidden) {
        if (id is String && id.isNotEmpty) hidden.add(id);
      }
    }
    return ModerationState(blocked: blocked, hiddenMessages: hidden);
  }
}

final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// The latest moderation state, read by [formatTimeline] so every timeline
/// (channels, threads, DMs, huddle history) drops blocked people's messages.
/// Widgets that format timelines also watch [moderationProvider] so they
/// rebuild when it changes.
ModerationState currentModeration = ModerationState.empty;

class ModerationNotifier extends Notifier<ModerationState> {
  static const storageKey = 'snack_moderation_v1';

  SharedPreferences? get _prefs {
    try {
      return ref.read(savedPrefsProvider);
    } catch (_) {
      return null; // Tests without preferences keep it in memory only.
    }
  }

  @override
  ModerationState build() {
    var loaded = ModerationState.empty;
    final raw = _prefs?.getString(storageKey);
    if (raw != null) {
      try {
        loaded = ModerationState.fromJson(jsonDecode(raw));
      } catch (_) {}
    }
    currentModeration = loaded;
    return loaded;
  }

  void _set(ModerationState next) {
    currentModeration = next;
    state = next;
    _prefs?.setString(storageKey, jsonEncode(next.toJson()));
  }

  void block(String pubkey, {String name = ''}) {
    final key = pubkey.toLowerCase();
    if (!_hex64.hasMatch(key)) return;
    _set(
      ModerationState(
        blocked: {...state.blocked, key: name},
        hiddenMessages: state.hiddenMessages,
      ),
    );
  }

  void unblock(String pubkey) {
    final next = {...state.blocked}..remove(pubkey.toLowerCase());
    _set(ModerationState(blocked: next, hiddenMessages: state.hiddenMessages));
  }

  void hideMessage(String eventId) {
    if (eventId.isEmpty) return;
    _set(
      ModerationState(
        blocked: state.blocked,
        hiddenMessages: {...state.hiddenMessages, eventId},
      ),
    );
  }
}

final moderationProvider =
    NotifierProvider<ModerationNotifier, ModerationState>(
      ModerationNotifier.new,
    );
