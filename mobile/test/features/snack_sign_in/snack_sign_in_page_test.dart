import 'dart:convert';

import 'package:buzz/features/snack_sign_in/snack_sign_in_page.dart';
import 'package:buzz/shared/auth/auth.dart';
import 'package:buzz/shared/hosted/known_community_sync_provider.dart';
import 'package:buzz/shared/snack/snack_account.dart';
import 'package:buzz/shared/snack/snack_sign_in.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nostr/nostr.dart' as nostr;

import '../../shared/community/community_storage_test.dart';

const _hex = '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';

class _Server {
  _Server(this.me);
  Map<String, Object?> me;
  final recorded = <Object?>[];
  final codes = <String>[];

  Future<http.Response> handle(http.Request request) async {
    switch (request.url.path) {
      case '/api/auth/email/start':
        return http.Response('{"sent":true}', 200);
      case '/api/auth/email/verify':
        final code = (jsonDecode(request.body) as Map)['code'] as String;
        codes.add(code);
        if (code != '123456') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({'error': 'That code didn’t work. Check it.'}),
            ),
            400,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{"signedIn":true}',
          200,
          headers: {'set-cookie': 'snack_session=u.1.sig; Path=/; HttpOnly'},
        );
      case '/api/me':
        if (request.headers['cookie'] != 'snack_session=u.1.sig') {
          return http.Response('{"error":"signed_out"}', 401);
        }
        return http.Response(jsonEncode(me), 200);
      case '/api/communities':
        recorded.add(jsonDecode(request.body));
        return http.Response('{"communities":[]}', 200);
    }
    return http.Response('', 404);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<(ProviderContainer, CommunityStorage)> pump(
    WidgetTester tester,
    _Server server, {
    required SnackInviteClaimer claimer,
  }) async {
    final storage = CommunityStorage(secure: FakeSecureStorage());
    final container = ProviderContainer(
      overrides: [
        knownCommunitySyncProvider.overrideWithValue(null),
        communityStorageProvider.overrideWithValue(storage),
        snackAccountProvider.overrideWithValue(
          SnackAccount(
            origin: Uri.parse('https://snack.example.org'),
            client: () => MockClient(server.handle),
          ),
        ),
        snackInviteClaimerProvider.overrideWithValue(claimer),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SnackSignInPage(onOtherWays: () {}),
        ),
      ),
    );
    return (container, storage);
  }

  Future<void> signInWithCode(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('snack-sign-in-email')),
      'pat@example.org',
    );
    await tester.tap(find.byKey(const Key('snack-sign-in-send-code')));
    await tester.pumpAndSettle();
    expect(find.text('Check your email'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('snack-sign-in-code')),
      '123456',
    );
    await tester.tap(find.byKey(const Key('snack-sign-in-verify')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'new account: email code, default community joined with the account key',
    (tester) async {
      final server = _Server({
        'email': 'pat@example.org',
        'secretKey': _hex,
        'communities': [],
        'defaultCommunity': {
          'community': 'https://welcome.example.org',
          'code': 'welcome-code',
        },
      });
      final claims = <(String, String, String)>[];
      var failClaim = true;
      final (container, storage) = await pump(
        tester,
        server,
        claimer: (community, code, nsec) async {
          claims.add((community.url, code, nsec));
          if (failClaim) {
            failClaim = false;
            throw const SnackAccountException('Couldn’t reach welcome.');
          }
        },
      );

      // A typo is caught before anything is sent.
      await tester.enterText(find.byType(TextField), 'not-an-email');
      await tester.tap(find.text('Send code'));
      await tester.pump();
      expect(find.text('Enter your email address.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'pat@example.org');
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      // A wrong code shows the server's plain words and keeps the step.
      await tester.enterText(find.byType(TextField), '000000');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('That code didn’t work. Check it.'), findsOneWidget);
      expect(find.text('Check your email'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      // The join failed once: signed in, so retry without a new code.
      expect(find.text('Couldn’t reach welcome.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(server.codes, ['000000', '123456']);
      final nsec = nostr.Keys(_hex).nsec;
      expect(claims.last, (
        'https://welcome.example.org',
        'welcome-code',
        nsec,
      ));
      expect(server.recorded, [
        {'url': 'https://welcome.example.org', 'name': '', 'icon': ''},
      ]);
      final saved = await storage.loadAll();
      expect(saved.single.relayUrl, 'wss://welcome.example.org');
      expect(saved.single.nsec, nsec);
      final auth = container.read(authProvider).value;
      expect(auth?.status, AuthStatus.authenticated);
      expect(auth?.community?.relayUrl, 'wss://welcome.example.org');
    },
  );

  testWidgets('returning account: every community saved, first one opened', (
    tester,
  ) async {
    final server = _Server({
      'email': 'pat@example.org',
      'secretKey': _hex,
      'communities': [
        {'url': 'https://team.example.org', 'name': 'Team', 'icon': ''},
        {'url': 'https://side.example.org', 'name': 'Side', 'icon': ''},
      ],
      'defaultCommunity': {
        'community': 'https://welcome.example.org',
        'code': 'welcome-code',
      },
    });
    final (container, storage) = await pump(
      tester,
      server,
      claimer: (_, _, _) async => fail('a member is never sent the default'),
    );
    // An earlier attempt saved one community before failing.
    final partial = Community.create(
      name: 'Side',
      relayUrl: 'wss://side.example.org',
      nsec: nostr.Keys(_hex).nsec,
    );
    await storage.save(partial);
    await signInWithCode(tester);

    final saved = await storage.loadAll();
    expect(saved.map((c) => (c.name, c.relayUrl)), [
      ('Side', 'wss://side.example.org'),
      ('Team', 'wss://team.example.org'),
    ]);
    expect(saved.first.id, partial.id);
    final auth = container.read(authProvider).value;
    expect(auth?.status, AuthStatus.authenticated);
    expect(auth?.community?.name, 'Team');
    expect(server.recorded, isEmpty);
  });

  testWidgets('Use a different account drops what a failed attempt saved', (
    tester,
  ) async {
    final server = _Server({
      'email': 'pat@example.org',
      'secretKey': _hex,
      'communities': [],
      'defaultCommunity': {
        'community': 'https://welcome.example.org',
        'code': 'welcome-code',
      },
    });
    final (container, storage) = await pump(
      tester,
      server,
      claimer: (_, _, _) async =>
          throw const SnackAccountException('Couldn’t reach welcome.'),
    );
    // Something an earlier attempt of this account saved.
    await storage.save(
      Community.create(
        name: 'Side',
        relayUrl: 'wss://side.example.org',
        nsec: nostr.Keys(_hex).nsec,
      ),
    );
    await signInWithCode(tester);
    expect(find.text('Couldn’t reach welcome.'), findsOneWidget);
    expect(await container.read(snackAccountProvider).hasSession, isTrue);

    await tester.tap(find.byKey(const Key('snack-sign-in-different-account')));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Snack'), findsOneWidget);
    expect(await storage.loadAll(), isEmpty);
    expect(await container.read(communityListProvider.future), isEmpty);
    expect(await container.read(snackAccountProvider).hasSession, isFalse);
  });
}
