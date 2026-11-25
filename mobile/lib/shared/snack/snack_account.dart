import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:nostr/nostr.dart' as nostr;

import '../community/community.dart';
import '../http/app_http_client.dart';
import '../storage/secure_storage.dart';

/// The Snack account server, used for every /api call and the Google start
/// page. Set per build with `--dart-define=SNACK_SERVER_URL=https://...`;
/// Google sign-in on iOS also needs that host in
/// `BuzzBrowserAuthBridge.snackHosts` (email sign-in works with any host).
final Uri snackOrigin = Uri.parse(
  const String.fromEnvironment(
    'SNACK_SERVER_URL',
    defaultValue: 'https://wesnack.app',
  ).replaceFirst(RegExp(r'/+$'), ''),
);

/// URL scheme the Snack server redirects to after Google sign-in.
const snackCallbackScheme = 'wesnack';

/// A failure whose [message] is safe to show as is.
class SnackAccountException implements Exception {
  const SnackAccountException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One community recorded on the Snack account: an https origin whose relay
/// is the wss:// of the same host.
class SnackCommunity {
  const SnackCommunity({required this.url, this.name = '', this.icon = ''});

  /// Returns null for anything but a plain https origin.
  static SnackCommunity? tryParse(Object? json) {
    if (json is! Map) return null;
    final origin = _httpsOrigin(json['url']);
    if (origin == null) return null;
    final name = json['name'];
    final icon = json['icon'];
    return SnackCommunity(
      url: origin,
      name: name is String ? name.trim() : '',
      icon: icon is String ? icon : '',
    );
  }

  final String url;
  final String name;
  final String icon;

  /// The community's relay: the same host over wss.
  String get relayUrl => url.replaceFirst('https://', 'wss://');

  String get displayName =>
      name.isNotEmpty ? name : Community.nameFromUrl(relayUrl);
}

/// Where an account with no communities yet is sent, with its invite code.
class SnackDefaultCommunity {
  const SnackDefaultCommunity({required this.community, required this.code});
  final SnackCommunity community;
  final String code;
}

/// `GET /api/me`: the signed-in account, its key included.
class SnackMe {
  const SnackMe({
    required this.email,
    required this.name,
    required this.pubkey,
    required this.secretKeyHex,
    required this.communities,
    this.defaultCommunity,
  });

  factory SnackMe.fromJson(Object? json) {
    if (json is! Map) {
      throw const SnackAccountException('Snack sent an unreadable reply.');
    }
    final secret = json['secretKey'];
    if (secret is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(secret)) {
      throw const SnackAccountException('Snack sent an unreadable account.');
    }
    final communities = <SnackCommunity>[];
    final seen = <String>{};
    final list = json['communities'];
    if (list is List) {
      for (final entry in list) {
        final community = SnackCommunity.tryParse(entry);
        if (community != null && seen.add(community.url)) {
          communities.add(community);
        }
      }
    }
    SnackDefaultCommunity? fallback;
    final rawDefault = json['defaultCommunity'];
    if (rawDefault is Map && rawDefault['code'] is String) {
      final community = SnackCommunity.tryParse({
        'url': rawDefault['community'],
      });
      final code = (rawDefault['code'] as String).trim();
      if (community != null && code.isNotEmpty) {
        fallback = SnackDefaultCommunity(community: community, code: code);
      }
    }
    String text(Object? value) => value is String ? value : '';
    return SnackMe(
      email: text(json['email']),
      name: text(json['name']),
      pubkey: text(json['pubkey']),
      secretKeyHex: secret.toLowerCase(),
      communities: communities,
      defaultCommunity: fallback,
    );
  }

  final String email;
  final String name;
  final String pubkey;
  final String secretKeyHex;
  final List<SnackCommunity> communities;
  final SnackDefaultCommunity? defaultCommunity;

  /// The account key as NIP-19 nsec, the form [Community] stores.
  String get nsec => snackNsecFromHex(secretKeyHex);

  /// The account's hex public key, derived from its secret key.
  String get publicKey => nostr.Keys(secretKeyHex).public;

  /// The saved community for [community], signed in as this account.
  Community toCommunity(SnackCommunity community) {
    final keys = nostr.Keys(secretKeyHex);
    return Community.create(
      name: community.displayName,
      relayUrl: community.relayUrl,
      pubkey: keys.public,
      nsec: keys.nsec,
    );
  }
}

/// NIP-19 nsec for a 32-byte hex secret key.
String snackNsecFromHex(String hex) {
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) {
    throw const FormatException('Not a 32-byte hex key');
  }
  return nostr.Keys(hex.toLowerCase()).nsec;
}

/// PKCE-style proof for the Google sign-in hand-off.
class SnackPkce {
  SnackPkce._(this.verifier) : challenge = challengeFor(verifier);

  /// A fresh 64-character verifier (the server needs at least 43).
  factory SnackPkce.generate([Random? random]) {
    final source = random ?? Random.secure();
    final bytes = List<int>.generate(48, (_) => source.nextInt(256));
    return SnackPkce._(base64Url.encode(bytes).replaceAll('=', ''));
  }

  final String verifier;
  final String challenge;

  /// base64url(sha256(verifier)) without padding: 43 characters.
  static String challengeFor(String verifier) => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
}

/// Opens [url] in a system browser session and returns the callback URL.
typedef SnackBrowser = Future<String?> Function(Uri url);

const _browserChannel = MethodChannel('buzz/browser_auth');

Future<String?> _openSystemBrowser(Uri url) =>
    _browserChannel.invokeMethod<String>('start', {'url': url.toString()});

/// Whether this platform can do the Google hand-off (iOS only for now: the
/// Android browser bridge only returns to the app's own scheme).
bool get snackGoogleSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// The name a new Snack account shows as: its Snack [name], else the part of
/// its [email] before the @. Empty when neither has one.
String snackAccountDisplayName(String name, String email) {
  final trimmed = name.trim();
  if (trimmed.isNotEmpty) return trimmed;
  final at = email.indexOf('@');
  return at > 0 ? email.substring(0, at).trim() : '';
}

/// Talks to the Snack account server. Keeps the session cookie in the
/// device-only keychain; never logs it or the account key.
class SnackAccount {
  SnackAccount({
    http.Client Function()? client,
    FlutterSecureStorage? storage,
    SnackBrowser? browser,
    Uri? origin,
  }) : _client = client ?? newAppHttpClient,
       _storage = storage ?? accountSecureStorage,
       _browser = browser ?? _openSystemBrowser,
       origin = origin ?? snackOrigin;

  static const _sessionKey = 'snack_session_v1';
  static const _pubkeyKey = 'snack_account_pubkey_v1';
  static const _timeout = Duration(seconds: 30);

  final http.Client Function() _client;
  final FlutterSecureStorage _storage;
  final SnackBrowser _browser;
  final Uri origin;

  Uri _url(String path, [Map<String, String>? query]) =>
      origin.replace(path: path, queryParameters: query);

  Future<bool> get hasSession async =>
      (await _storage.read(key: _sessionKey))?.isNotEmpty ?? false;

  /// Remembers which identity is the Snack account's, so sign-out never
  /// keeps it as a saved key and in-app joins can reuse it.
  Future<void> rememberAccount(String pubkey) =>
      _storage.write(key: _pubkeyKey, value: pubkey.toLowerCase());

  /// The signed-in account's hex public key, or null when signed out.
  /// An unreadable keychain counts as signed out.
  Future<String?> accountPubkey() async {
    try {
      if (!await hasSession) return null;
      final pubkey = await _storage.read(key: _pubkeyKey);
      if (pubkey != null && pubkey.isNotEmpty) return pubkey;
      // Signed in before this key was remembered: ask the server once.
      final fetched = (await me()).pubkey;
      if (fetched.isEmpty) return null;
      await rememberAccount(fetched);
      return fetched.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  /// Whether [community] is signed in as the Snack account.
  static bool isAccountCommunity(Community community, String? accountPubkey) {
    if (accountPubkey == null) return false;
    var pubkey = community.pubkey;
    final nsec = community.nsec;
    if (pubkey == null && nsec != null && nsec.isNotEmpty) {
      try {
        pubkey = nostr.Keys(nostr.Nip19.decode(payload: nsec).data).public;
      } catch (_) {
        return false;
      }
    }
    return pubkey?.toLowerCase() == accountPubkey;
  }

  /// The Snack account key (nsec) when signed in and a saved community holds
  /// it; null otherwise.
  Future<String?> accountNsecAmong(List<Community> communities) async {
    final pubkey = await accountPubkey();
    for (final community in communities) {
      final nsec = community.nsec;
      if (nsec != null &&
          nsec.isNotEmpty &&
          isAccountCommunity(community, pubkey)) {
        return nsec;
      }
    }
    return null;
  }

  /// Emails a 6-digit code to [email].
  Future<void> startEmail(String email) async {
    await _send('POST', '/api/auth/email/start', body: {'email': email.trim()});
  }

  /// Exchanges the emailed code for a session.
  Future<void> verifyEmail(String email, String code) async {
    final response = await _send(
      'POST',
      '/api/auth/email/verify',
      body: {'email': email.trim(), 'code': code.trim()},
    );
    await _keepSession(response);
  }

  /// Google in the system browser, then redeems the one-time code with the
  /// verifier only this app holds. Returns false when the person cancelled.
  Future<bool> signInWithGoogle({SnackPkce? pkce}) async {
    final proof = pkce ?? SnackPkce.generate();
    String? callback;
    try {
      callback = await _browser(
        _url('/api/auth/google/start', {'app': proof.challenge}),
      );
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') return false;
      throw const SnackAccountException(
        'Couldn’t open Google sign-in. Try email instead.',
      );
    }
    if (callback == null) return false;
    final uri = Uri.tryParse(callback);
    final code = uri?.queryParameters['code'];
    if (uri == null ||
        uri.scheme != snackCallbackScheme ||
        code == null ||
        code.isEmpty) {
      throw const SnackAccountException(
        'Google sign-in didn’t finish. Try again.',
      );
    }
    final response = await _send(
      'GET',
      '/api/auth/app/finish',
      query: {'code': code, 'verifier': proof.verifier},
      allowRedirect: true,
    );
    if (!await _keepSession(response, required: false)) {
      throw const SnackAccountException(
        'Google sign-in didn’t finish. Try again.',
      );
    }
    return true;
  }

  /// The signed-in account. Throws [SnackSignedOut] without a valid session.
  Future<SnackMe> me() async {
    final response = await _send('GET', '/api/me', authenticated: true);
    return SnackMe.fromJson(_decode(response));
  }

  /// The agents Snack Cloud lists for this account (the ones Snack runs and
  /// the ones connected), as pubkey to name. Discovery only: callers verify
  /// ownership on the relay before offering one. Empty when signed out; a
  /// list that fails to load is skipped.
  Future<Map<String, String>> ownedAgents() async {
    if (!await hasSession) return const {};
    Future<Object?> read(String path) async {
      try {
        // Discovery must never sign the person out: a 401 here skips the list.
        return _decode(
          await _send(
            'GET',
            path,
            authenticated: true,
            keepSessionOn401: true,
            timeout: const Duration(seconds: 6),
          ),
        );
      } catch (_) {
        return null;
      }
    }

    final agents = <String, String>{};
    final replies = await Future.wait([
      read('/api/agents/hosted'),
      read('/api/agents'),
    ]);
    for (final json in replies) {
      final list = json is Map ? json['agents'] : null;
      if (list is! List) continue;
      for (final entry in list.take(500)) {
        if (entry is! Map) continue;
        final pubkey = entry['pubkey'];
        final name = entry['name'];
        if (pubkey is String &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(pubkey) &&
            name is String &&
            name.trim().isNotEmpty) {
          agents.putIfAbsent(pubkey, () => name.trim());
        }
      }
    }
    return agents;
  }

  /// [target] on Snack's web app, wrapped in a one-time sign-in link so the
  /// in-app browser opens it already signed in as this account. Returns
  /// [target] unchanged when it isn't on this account server's origin, when
  /// signed out, or when the server can't mint a link in time: the web then
  /// asks the person to sign in, as before. The account key never goes into
  /// a URL; the link is single-use and lives about a minute.
  Future<Uri> signedInWebUrl(
    Uri target, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!_sameOrigin(target, origin)) return target;
    try {
      if (!await hasSession) return target;
      final response = await _send(
        'POST',
        '/api/auth/handoff',
        authenticated: true,
      ).timeout(timeout);
      final body = _decode(response);
      final url = body is Map ? body['url'] : null;
      final link = url is String ? Uri.tryParse(url) : null;
      if (link == null || !_sameOrigin(link, origin)) return target;
      final next = Uri(
        path: target.path.isEmpty ? '/' : target.path,
        query: target.hasQuery ? target.query : null,
        fragment: target.hasFragment ? target.fragment : null,
      ).toString();
      return link.replace(
        queryParameters: {...link.queryParameters, 'next': next},
      );
    } catch (_) {
      return target;
    }
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  /// Records a joined community on the account, for the next sign-in.
  Future<void> recordCommunity(SnackCommunity community) async {
    await _send(
      'POST',
      '/api/communities',
      body: {
        'url': community.url,
        'name': community.name,
        'icon': community.icon,
      },
      authenticated: true,
    );
  }

  /// Forgets the session here, then ends it on the server in the background
  /// (best effort: an unreachable server's copy simply expires).
  Future<void> signOut() async {
    final session = await _storage.read(key: _sessionKey);
    await _storage.delete(key: _sessionKey);
    await _storage.delete(key: _pubkeyKey);
    if (session == null || session.isEmpty) return;
    final client = _client();
    unawaited(
      client
          .post(
            _url('/api/auth/signout'),
            headers: {'Cookie': 'snack_session=$session'},
          )
          .timeout(_timeout)
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(client.close),
    );
  }

  Future<bool> _keepSession(
    http.Response response, {
    bool required = true,
  }) async {
    final session = sessionFromSetCookie(response.headers['set-cookie']);
    if (session == null) {
      if (!required) return false;
      throw const SnackAccountException('Sign-in didn’t finish. Try again.');
    }
    await _storage.write(key: _sessionKey, value: session);
    return true;
  }

  /// The `snack_session` value from a (possibly comma-joined) Set-Cookie.
  @visibleForTesting
  static String? sessionFromSetCookie(String? header) {
    if (header == null) return null;
    final match = RegExp(
      r'(?:^|[,;]\s*)snack_session=([^;,\s]+)',
    ).firstMatch(header);
    final value = match?.group(1);
    return value == null || value.isEmpty ? null : value;
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
    bool authenticated = false,
    bool allowRedirect = false,
    bool keepSessionOn401 = false,
    Duration timeout = _timeout,
  }) async {
    final request = http.Request(method, _url(path, query))
      ..followRedirects = false;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (authenticated) {
      final session = await _storage.read(key: _sessionKey);
      if (session == null || session.isEmpty) throw const SnackSignedOut();
      request.headers['Cookie'] = 'snack_session=$session';
    }
    final client = _client();
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await client.send(request).timeout(timeout),
      ).timeout(timeout);
    } catch (_) {
      throw const SnackAccountException(
        'Couldn’t reach Snack. Check your connection and try again.',
      );
    } finally {
      client.close();
    }
    final status = response.statusCode;
    if (status >= 200 && status < 300) return response;
    if (allowRedirect && status >= 300 && status < 400) return response;
    if (status == 401) {
      if (authenticated && !keepSessionOn401) {
        await _storage.delete(key: _sessionKey);
      }
      throw const SnackSignedOut();
    }
    final error = _errorText(response);
    throw SnackAccountException(
      error ?? 'Something went wrong. Try again in a moment.',
    );
  }

  static Object? _decode(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw const SnackAccountException('Snack sent an unreadable reply.');
    }
  }

  static String? _errorText(http.Response response) {
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      final error = json is Map ? json['error'] : null;
      if (error is String && error.trim().isNotEmpty && error.length < 200) {
        return error.trim();
      }
    } catch (_) {}
    return null;
  }
}

/// The session is missing or expired: sign in again.
class SnackSignedOut extends SnackAccountException {
  const SnackSignedOut() : super('Please sign in again.');
}

String? _httpsOrigin(Object? value) {
  if (value is! String || value.length > 300) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.hasPort
      ? 'https://${uri.host.toLowerCase()}:${uri.port}'
      : 'https://${uri.host.toLowerCase()}';
}

/// The app's Snack account client.
final snackAccountProvider = Provider<SnackAccount>((ref) => SnackAccount());
