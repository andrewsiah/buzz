import 'dart:convert';

import 'package:buzz/features/channels/timeline_message.dart';
import 'package:buzz/shared/moderation/moderation.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/snack/snack_account.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _alice = 'a' * 64;
final _bob = 'b' * 64;

NostrEvent _msg(String id, String pubkey) => NostrEvent(
  id: id,
  pubkey: pubkey,
  createdAt: 1000,
  kind: EventKind.streamMessage,
  tags: const [
    ['h', 'ch1'],
  ],
  content: 'hello from $id',
  sig: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('blocking and reporting hide messages and survive a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    ProviderContainer open() => ProviderContainer(
      overrides: [savedPrefsProvider.overrideWithValue(prefs)],
    );
    final events = [_msg('m1', _alice), _msg('m2', _bob), _msg('m3', _bob)];

    var container = open();
    final moderation = container.read(moderationProvider.notifier);
    expect(formatTimeline(events).map((m) => m.id), ['m1', 'm2', 'm3']);

    // Reporting one message hides only it; blocking hides all of theirs.
    moderation.hideMessage('m1');
    expect(formatTimeline(events).map((m) => m.id), ['m2', 'm3']);
    moderation.block(_bob.toUpperCase(), name: 'Bob');
    expect(formatTimeline(events), isEmpty);
    expect(container.read(moderationProvider).blocked, {_bob: 'Bob'});
    container.dispose();

    // A fresh start reads the saved state back.
    currentModeration = ModerationState.empty;
    container = open();
    expect(container.read(moderationProvider).isBlocked(_bob), isTrue);
    expect(formatTimeline(events), isEmpty);

    // Unblocking brings their messages back; the reported one stays hidden.
    container.read(moderationProvider.notifier).unblock(_bob);
    expect(formatTimeline(events).map((m) => m.id), ['m2', 'm3']);
    expect(
      formatTimeline(
        events,
        moderationState: ModerationState.empty,
      ).map((m) => m.id),
      ['m1', 'm2', 'm3'],
    );
    container.dispose();
    currentModeration = ModerationState.empty;
  });

  test('delete account and report call Snack with the session', () async {
    FlutterSecureStorage.setMockInitialValues({
      'snack_session_v1': 's.1.sig',
      'snack_account_pubkey_v1': _alice,
    });
    final requests = <http.Request>[];
    final account = SnackAccount(
      origin: Uri.parse('https://snack.example.org'),
      client: () => MockClient((request) async {
        requests.add(request);
        return http.Response('{"ok":true}', 200);
      }),
    );

    await account.report(
      kind: 'message',
      community: 'https://team.example.org',
      author: _bob.toUpperCase(),
      reason: 'spam',
      eventId: 'e' * 64,
      content: 'x' * 3000,
      blocked: true,
    );
    final report = requests.single;
    expect(report.url.path, '/api/reports');
    expect(report.headers['cookie'], 'snack_session=s.1.sig');
    final body = jsonDecode(report.body) as Map;
    expect(body['author'], _bob);
    expect(body['eventId'], 'e' * 64);
    expect((body['content'] as String).length, 2000);
    expect(body['blocked'], isTrue);
    expect(await account.hasSession, isTrue);

    await account.deleteAccount();
    expect(requests.last.url.path, '/api/account/delete');
    expect(jsonDecode(requests.last.body), {'confirm': 'delete'});
    expect(await account.hasSession, isFalse);
    expect(await account.accountPubkey(), isNull);

    // Signed out: nothing is sent.
    await expectLater(account.deleteAccount(), throwsA(isA<SnackSignedOut>()));
    expect(requests, hasLength(2));
  });
}
