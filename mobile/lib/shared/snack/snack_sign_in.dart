import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/auth.dart';
import '../http/app_http_client.dart';
import '../relay/relay_session.dart' show buildNip98AuthHeader;
import 'snack_account.dart';

/// Where the Snack sign-in screen is.
enum SnackSignInStep { email, code, joining }

class SnackSignInState {
  const SnackSignInState({
    this.step = SnackSignInStep.email,
    this.email = '',
    this.busy = false,
    this.error,
  });

  final SnackSignInStep step;
  final String email;
  final bool busy;

  /// Plain words, safe to show.
  final String? error;

  SnackSignInState copyWith({
    SnackSignInStep? step,
    String? email,
    bool? busy,
    String? error,
  }) => SnackSignInState(
    step: step ?? this.step,
    email: email ?? this.email,
    busy: busy ?? this.busy,
    error: error,
  );
}

/// Claims a relay invite as the Snack account key (`POST /api/invites/claim`,
/// NIP-98 signed), so the account joins with the same identity it has on the
/// web.
typedef SnackInviteClaimer =
    Future<void> Function(SnackCommunity community, String code, String nsec);

final snackInviteClaimerProvider = Provider<SnackInviteClaimer>(
  (ref) => claimSnackInvite,
);

Future<void> claimSnackInvite(
  SnackCommunity community,
  String code,
  String nsec, {
  http.Client Function()? client,
}) async {
  final url = '${community.url}/api/invites/claim';
  final body = jsonEncode({'code': code});
  final http = (client ?? newAppHttpClient)();
  try {
    final response = await http
        .post(
          Uri.parse(url),
          headers: {
            'Authorization': buildNip98AuthHeader(
              method: 'POST',
              url: url,
              bodyBytes: utf8.encode(body),
              nsec: nsec,
            ),
            'Content-Type': 'application/json',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (text.contains('invite_expired') ||
        text.contains('invite_exhausted') ||
        text.contains('invite_invalid')) {
      throw const SnackAccountException(
        'Snack’s welcome invite isn’t working right now. '
        'Ask a teammate for an invite link.',
      );
    }
    if (text.contains('invite_restricted')) {
      throw SnackAccountException(
        'Your account can’t join ${community.displayName} right now. '
        'Ask a community admin.',
      );
    }
    if (text.contains('join_policy_required')) {
      throw SnackAccountException(
        '${community.displayName} asks new members to accept its rules first. '
        'Open Snack on the web to join, then sign in here again.',
      );
    }
    throw SnackAccountException(
      'Couldn’t join ${community.displayName}. Try again in a moment.',
    );
  } on SnackAccountException {
    rethrow;
  } catch (_) {
    throw SnackAccountException(
      'Couldn’t reach ${community.displayName}. Check your connection.',
    );
  } finally {
    http.close();
  }
}

/// Email-code and Google sign-in to Snack, then saves every community on the
/// account (or joins the default one) signed in with the account key.
class SnackSignInNotifier extends Notifier<SnackSignInState> {
  @override
  SnackSignInState build() => const SnackSignInState();

  SnackAccount get _account => ref.read(snackAccountProvider);

  Future<void> sendCode(String email) async {
    final trimmed = email.trim();
    if (state.busy) return;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(trimmed)) {
      state = state.copyWith(
        email: trimmed,
        error: 'Enter your email address.',
      );
      return;
    }
    state = state.copyWith(email: trimmed, busy: true);
    try {
      await _account.startEmail(trimmed);
      state = state.copyWith(step: SnackSignInStep.code, busy: false);
    } on SnackAccountException catch (error) {
      state = state.copyWith(busy: false, error: error.message);
    }
  }

  Future<void> verifyCode(String code) async {
    if (state.busy) return;
    final digits = code.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 6) {
      state = state.copyWith(error: 'Enter the 6-digit code.');
      return;
    }
    state = state.copyWith(busy: true);
    try {
      await _account.verifyEmail(state.email, digits);
    } on SnackAccountException catch (error) {
      state = state.copyWith(busy: false, error: error.message);
      return;
    }
    await _land();
  }

  Future<void> signInWithGoogle() async {
    if (state.busy) return;
    state = state.copyWith(busy: true);
    try {
      if (!await _account.signInWithGoogle()) {
        state = state.copyWith(busy: false);
        return;
      }
    } on SnackAccountException catch (error) {
      state = state.copyWith(busy: false, error: error.message);
      return;
    }
    await _land();
  }

  /// Back to the email step, e.g. to fix a typo or use another account.
  Future<void> useDifferentEmail() async {
    if (state.busy) return;
    final joining = state.step == SnackSignInStep.joining;
    state = SnackSignInState(email: state.email);
    if (!joining) return;
    await _account.signOut();
    // Signed out means nothing usable is saved: drop what a failed attempt
    // saved, so another account never inherits this one's communities.
    final storage = ref.read(communityStorageProvider);
    for (final community in await storage.loadAll()) {
      await storage.remove(community.id);
    }
    ref.invalidate(communityListProvider);
  }

  /// Signed in, but opening the communities failed: try that part again.
  Future<void> retry() async {
    if (state.busy || state.step != SnackSignInStep.joining) return;
    await _land();
  }

  Future<void> _land() async {
    state = state.copyWith(step: SnackSignInStep.joining, busy: true);
    try {
      final me = await _account.me();
      final targets = [...me.communities];
      final fallback = me.defaultCommunity;
      if (targets.isEmpty && fallback != null) {
        await ref.read(snackInviteClaimerProvider)(
          fallback.community,
          fallback.code,
          me.nsec,
        );
        targets.add(fallback.community);
        try {
          await _account.recordCommunity(fallback.community);
        } on SnackAccountException {
          // The next sign-in claims the default invite again, which the relay
          // answers with already_member.
        }
      }
      if (targets.isEmpty) {
        throw const SnackAccountException(
          'Your Snack account isn’t in a community yet. '
          'Ask a teammate for an invite link, then tap Other ways to join.',
        );
      }
      // A retry after a partial save updates what it saved, never duplicates.
      final saved = await ref.read(communityStorageProvider).loadAll();
      Community prepare(SnackCommunity target) {
        final fresh = me.toCommunity(target);
        final existing = saved
            .where((c) => c.relayUrl == fresh.relayUrl)
            .firstOrNull;
        return existing?.copyWith(
              name: fresh.name,
              pubkey: fresh.pubkey,
              nsec: fresh.nsec,
            ) ??
            fresh;
      }

      final auth = ref.read(authProvider.notifier);
      // Others first and inactive, so the switch to the first happens once.
      for (final community in targets.skip(1)) {
        await auth.authenticateWithCommunity(
          prepare(community),
          activate: false,
        );
      }
      await auth.authenticateWithCommunity(prepare(targets.first));
      if (ref.mounted) state = state.copyWith(busy: false);
    } on SnackSignedOut catch (error) {
      if (ref.mounted) {
        state = SnackSignInState(email: state.email, error: error.message);
      }
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(
        busy: false,
        error: error is SnackAccountException
            ? error.message
            : 'Couldn’t open your communities. Try again.',
      );
    }
  }
}

final snackSignInProvider =
    NotifierProvider.autoDispose<SnackSignInNotifier, SnackSignInState>(
      SnackSignInNotifier.new,
    );
