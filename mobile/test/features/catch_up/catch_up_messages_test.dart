import 'package:buzz/features/catch_up/catch_up_messages.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

NostrEvent _event(
  String id,
  int kind,
  int at, {
  String pubkey = 'agent',
  String content = '',
  String? target,
}) => NostrEvent(
  id: id,
  pubkey: pubkey,
  createdAt: at,
  kind: kind,
  tags: [
    ['h', 'channel'],
    ['e', 'root', '', 'root'],
    if (target != null) ['e', target],
  ],
  content: content,
  sig: '',
);

void main() {
  test('a thread shows each message once, with its latest edit', () {
    // A progress card is posted, then edited as the job runs. Edits,
    // reactions and deletions are not rows; a deleted reply is gone; an edit
    // by someone else does not change the card.
    final rows = foldCatchUpMessages([
      _event('reply', EventKind.streamMessage, 5, content: 'Still waiting'),
      _event('card', EventKind.streamMessage, 1, content: 'Working 0 steps'),
      _event(
        'edit-2',
        EventKind.streamMessageEdit,
        4,
        content: "Couldn't finish 63 steps",
        target: 'card',
      ),
      _event(
        'edit-1',
        EventKind.streamMessageEdit,
        2,
        content: 'Working 10 steps',
        target: 'card',
      ),
      _event(
        'edit-x',
        EventKind.streamMessageEdit,
        9,
        pubkey: 'someone',
        content: 'hijack',
        target: 'card',
      ),
      _event('like', EventKind.reaction, 3, content: '+', target: 'card'),
      _event('oops', EventKind.streamMessage, 6, content: 'typo'),
      _event('del', EventKind.deletion, 7, target: 'oops'),
      _event('post', EventKind.forumComment, 8, content: 'forum reply'),
    ]);
    expect(rows.map((row) => (row.id, row.content)), [
      ('card', "Couldn't finish 63 steps"),
      ('reply', 'Still waiting'),
      ('post', 'forum reply'),
    ]);
  });
}
