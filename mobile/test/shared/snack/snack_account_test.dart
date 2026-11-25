import 'dart:convert';

import 'package:buzz/shared/snack/snack_account.dart';
import 'package:buzz/shared/snack/snack_sign_in.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nostr/nostr.dart' as nostr;

// NIP-19's published example key pair.
const _hex = '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';
const _nsec = 'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'PKCE challenge matches RFC 7636 and fresh verifiers are long enough',
    () {
      expect(
        SnackPkce.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
      final pkce = SnackPkce.generate();
      expect(pkce.verifier.length, greaterThanOrEqualTo(43));
      expect(pkce.challenge, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(SnackPkce.generate().verifier, isNot(pkce.verifier));
    },
  );

  test('hex account key becomes the NIP-19 nsec', () {
    expect(snackNsecFromHex(_hex), _nsec);
    expect(snackNsecFromHex(_hex.toUpperCase()), _nsec);
    for (final bad in ['', 'zz', _hex.substring(2), '${_hex}00']) {
      expect(() => snackNsecFromHex(bad), throwsFormatException, reason: bad);
    }
  });

  test('/api/me parses into saved communities on the account key', () {
    final me = SnackMe.fromJson({
      'email': 'pat@example.org',
      'name': 'Pat',
      'pubkey': 'ignored',
      'secretKey': _hex,
      'communities': [
        {'url': 'https://Team.Example.org', 'name': 'Team', 'icon': ''},
        {'url': 'https://team.example.org', 'name': 'Duplicate'},
        {'url': 'http://insecure.example.org', 'name': 'Insecure'},
        {'url': 'https://user@spoof.example.org', 'name': 'Userinfo'},
        {'url': 'https://unnamed.example.org:8443'},
        'garbage',
      ],
      'defaultCommunity': null,
    });
    expect(me.communities.map((c) => c.url), [
      'https://team.example.org',
      'https://unnamed.example.org:8443',
    ]);
    expect(me.defaultCommunity, isNull);
    expect(me.nsec, _nsec);

    final team = me.toCommunity(me.communities.first);
    expect(team.name, 'Team');
    expect(team.relayUrl, 'wss://team.example.org');
    expect(team.nsec, _nsec);
    expect(team.pubkey, nostr.Keys(_hex).public);
    final unnamed = me.toCommunity(me.communities.last);
    expect(unnamed.name, 'unnamed');
    expect(unnamed.relayUrl, 'wss://unnamed.example.org:8443');

    final fresh = SnackMe.fromJson({
      'secretKey': _hex,
      'communities': [],
      'defaultCommunity': {
        'community': 'https://welcome.example.org/',
        'code': ' abc ',
      },
    });
    expect(
      fresh.defaultCommunity?.community.url,
      'https://welcome.example.org',
    );
    expect(fresh.defaultCommunity?.code, 'abc');

    for (final bad in [
      null,
      <String, Object?>{},
      {'secretKey': 'nothex'},
    ]) {
      expect(
        () => SnackMe.fromJson(bad),
        throwsA(isA<SnackAccountException>()),
      );
    }
  });

  test('session cookie is read from Set-Cookie headers', () {
    for (final (header, expected) in [
      ('snack_session=u1.99.sig; Path=/; HttpOnly', 'u1.99.sig'),
      ('snack_oauth=; Path=/, snack_session=a.b.c; Path=/', 'a.b.c'),
      ('snack_oauth=x; Path=/', null),
      ('snack_session=; Max-Age=0', null),
      (null, null),
    ]) {
      expect(
        SnackAccount.sessionFromSetCookie(header),
        expected,
        reason: header,
      );
    }
  });

  test(
    'Google hand-off redeems the code with the verifier, no redirect',
    () async {
      final pkce = SnackPkce.generate();
      final requests = <http.BaseRequest>[];
      Uri? opened;
      final account = SnackAccount(
        origin: Uri.parse('https://snack.example.org'),
        browser: (url) async {
          opened = url;
          return 'wesnack://signin?code=one-time&next=%2F';
        },
        client: () => MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/api/auth/app/finish') {
            return http.Response(
              '',
              302,
              headers: {
                'location': '/',
                'set-cookie': 'snack_session=s.1.sig; Path=/; HttpOnly',
              },
            );
          }
          expect(request.headers['cookie'], 'snack_session=s.1.sig');
          return http.Response(jsonEncode({'secretKey': _hex}), 200);
        }),
      );

      expect(await account.signInWithGoogle(pkce: pkce), isTrue);
      expect(opened?.path, '/api/auth/google/start');
      expect(opened?.queryParameters['app'], pkce.challenge);
      final finish = requests.single as http.Request;
      expect(finish.followRedirects, isFalse);
      expect(finish.url.queryParameters, {
        'code': 'one-time',
        'verifier': pkce.verifier,
      });
      expect(await account.hasSession, isTrue);
      expect((await account.me()).secretKeyHex, _hex);

      // Sign-out forgets the session here and revokes it on the server.
      await account.signOut();
      expect(await account.hasSession, isFalse);
      await pumpEventQueue();
      expect(requests.last.url.path, '/api/auth/signout');
      expect(requests.last.headers['cookie'], 'snack_session=s.1.sig');

      final cancelled = SnackAccount(
        browser: (_) async => throw PlatformException(code: 'cancelled'),
        client: () => MockClient((_) async => fail('no request expected')),
      );
      expect(await cancelled.signInWithGoogle(), isFalse);

      final wrongScheme = SnackAccount(
        browser: (_) async => 'other://signin?code=x',
        client: () => MockClient((_) async => fail('no request expected')),
      );
      await expectLater(
        wrongScheme.signInWithGoogle(),
        throwsA(isA<SnackAccountException>()),
      );
    },
  );

  test('default-community claim is NIP-98 signed by the account key', () async {
    late http.Request claim;
    await claimSnackInvite(
      const SnackCommunity(url: 'https://welcome.example.org'),
      'invite-code',
      _nsec,
      client: () => MockClient((request) async {
        claim = request;
        return http.Response('{"status":"already_member"}', 200);
      }),
    );
    expect(
      claim.url.toString(),
      'https://welcome.example.org/api/invites/claim',
    );
    expect(jsonDecode(claim.body), {'code': 'invite-code'});
    final auth = claim.headers['authorization']!;
    expect(auth, startsWith('Nostr '));
    final event =
        jsonDecode(utf8.decode(base64.decode(auth.substring(6))))
            as Map<String, dynamic>;
    expect(event['kind'], 27235);
    expect(event['pubkey'], nostr.Keys(_hex).public);
    expect(event['tags'], anyElement(equals(['u', claim.url.toString()])));

    await expectLater(
      claimSnackInvite(
        const SnackCommunity(url: 'https://welcome.example.org'),
        'old',
        _nsec,
        client: () => MockClient(
          (_) async => http.Response('{"error":"invite_expired"}', 403),
        ),
      ),
      throwsA(
        isA<SnackAccountException>().having(
          (e) => e.message,
          'message',
          contains('invite link'),
        ),
      ),
    );
  });

  group('signed-in web hand-off', () {
    final origin = Uri.parse('https://snack.example.org');
    final board = Uri.parse(
      'https://snack.example.org/?community=https%3A%2F%2Fr.example&channel=c1&panel=board',
    );

    test(
      'wraps a web page in a one-time link minted with the session',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'snack_session_v1': 'u1.99.sig',
        });
        final requests = <http.Request>[];
        final account = SnackAccount(
          origin: origin,
          client: () => MockClient((request) async {
            requests.add(request);
            return http.Response(
              jsonEncode({
                'url':
                    'https://snack.example.org/api/auth/handoff?code=one.2.sig',
                'expiresIn': 60,
              }),
              200,
            );
          }),
        );
        final url = await account.signedInWebUrl(board);
        expect(requests.single.method, 'POST');
        expect(requests.single.url.path, '/api/auth/handoff');
        expect(requests.single.headers['Cookie'], 'snack_session=u1.99.sig');
        expect(url.origin, origin.origin);
        expect(url.path, '/api/auth/handoff');
        expect(url.queryParameters['code'], 'one.2.sig');
        expect(
          url.queryParameters['next'],
          '/?community=https%3A%2F%2Fr.example&channel=c1&panel=board',
        );
        // The session itself never goes into the link.
        expect(url.toString(), isNot(contains('u1.99.sig')));
      },
    );

    test('leaves the page alone when it cannot hand off', () async {
      final noRequest = MockClient((_) async => fail('no request expected'));
      // Signed out.
      expect(
        await SnackAccount(
          origin: origin,
          client: () => noRequest,
        ).signedInWebUrl(board),
        board,
      );
      FlutterSecureStorage.setMockInitialValues({
        'snack_session_v1': 'u1.99.sig',
      });
      // Another site, or a community subdomain the session cookie can't reach.
      final other = Uri.parse('https://team.snack.example.org/?channel=c1');
      expect(
        await SnackAccount(
          origin: origin,
          client: () => noRequest,
        ).signedInWebUrl(other),
        other,
      );
      // Server refuses, or hands back a link to somewhere else.
      for (final reply in [
        http.Response('{"error":"signed_out"}', 401),
        http.Response('{"url":"https://evil.example/x"}', 200),
        http.Response('not json', 200),
      ]) {
        final account = SnackAccount(
          origin: origin,
          client: () => MockClient((_) async => reply),
        );
        expect(await account.signedInWebUrl(board), board);
      }
    });
  });

  test(
    'owned agents merge Snack-run and connected lists, keeping valid rows',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'snack_session_v1': 'u1.99.sig',
      });
      final kiss = 'e9' * 32;
      final helper = 'ab' * 32;
      final paths = <String>[];
      final account = SnackAccount(
        origin: Uri.parse('https://snack.example.org'),
        client: () => MockClient((request) async {
          paths.add(request.url.path);
          expect(request.headers['Cookie'], 'snack_session=u1.99.sig');
          if (request.url.path == '/api/agents/hosted') {
            return http.Response('{"error":"down"}', 500);
          }
          return http.Response(
            jsonEncode({
              'agents': [
                {'pubkey': kiss, 'name': ' Kiss ', 'community': 'https://r'},
                {'pubkey': helper, 'name': 'Helper'},
                {'pubkey': 'not-a-key', 'name': 'Bad'},
                {'pubkey': 'cd' * 32, 'name': ''},
              ],
            }),
            200,
          );
        }),
      );
      expect(await account.ownedAgents(), {kiss: 'Kiss', helper: 'Helper'});
      expect(paths.toSet(), {'/api/agents/hosted', '/api/agents'});
    },
  );

  test('a 401 from an agent list never signs the person out', () async {
    FlutterSecureStorage.setMockInitialValues({
      'snack_session_v1': 'u1.99.sig',
    });
    final account = SnackAccount(
      origin: Uri.parse('https://snack.example.org'),
      client: () => MockClient((_) async => http.Response('{}', 401)),
    );
    expect(await account.ownedAgents(), isEmpty);
    expect(await account.hasSession, isTrue);
  });

  test('owned agents are empty and ask nothing when signed out', () async {
    final account = SnackAccount(
      origin: Uri.parse('https://snack.example.org'),
      client: () => MockClient((_) async => fail('no request expected')),
    );
    expect(await account.ownedAgents(), isEmpty);
  });

  test('new accounts are named by their Snack name, else their email', () {
    expect(snackAccountDisplayName(' Ada ', 'ada@example.org'), 'Ada');
    expect(snackAccountDisplayName('', 'ada.l@example.org'), 'ada.l');
    expect(snackAccountDisplayName('', ''), '');
    expect(snackAccountDisplayName('', '@example.org'), '');
  });
}
