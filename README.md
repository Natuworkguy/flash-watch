# Flash for Apple Watch

Your Flash, on your wrist. Talk to your chats, your sparks and their
team chats, by voice or Scribble, from an Apple Watch.

It talks to [Flash](https://github.com/Natuworkguy/Flash) running on
your own computer. Nothing goes anywhere else.

## What it does

- **Chats.** Start a new chat by speaking, pick up any earlier one, and
  read the whole conversation, with Flash's steps folded into a line.
- **Approvals.** When Flash asks before it does something, Allow or Deny
  it from your wrist. A turn that is going the wrong way can be stopped.
- **Sparks.** See what each spark is doing and which ones need you.
  Approve or deny what a spark waits on, run it now, pause it, or start
  a chat with it.
- **Team chats.** Read and write in your teams' chats. Reply to a
  message, react to it, and see every earlier version of a message a
  spark edited.
- **Read aloud.** Any reply, read out in Flash's own voice when your
  computer has one, or the watch's. New replies can be read out as they
  arrive.
- **A tap on the wrist** when Flash finishes a reply or a spark posts in
  the chat you have open.

## Set it up

You need Flash on your computer, and a Mac with Xcode 16 or later to put
the app on your watch.

1. **Add the Watch panel to Flash.** In Flash, run:

   ```
   /extension install github@Natuworkguy/flash-watch
   ```

   A **Watch** row appears in the sidebar of Flash's web page.

2. **Let the watch reach Flash.** Start Flash's web page on your network
   (`flash --web --lan`, or `/web lan`), or turn on its public link in
   Settings to reach it from anywhere.

3. **Put the app on your watch.** Put your team in `watch/Local.xcconfig`
   (a free Apple ID works, signed in under Xcode, Settings, Accounts):

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   FLASH_BUNDLE_ID = com.yourname.flash
   ```

   Then, with your watch on its charger and unlocked:

   ```sh
   scripts/watch.sh install
   ```

4. **Pair.** Open **Watch** in Flash's sidebar. It shows an address and a
   six digit code. Open Flash on the watch and type both. The code works
   once, for five minutes.

To try it in the simulator instead: `scripts/watch.sh sim`.

## How it works

The watch signs in to Flash like another browser would, with a key of its
own. The code is how it gets that key: it ends when it is used, after five
minutes, or after five wrong tries. Each paired watch is listed under
**Watch** in Flash, where it can be signed out. Unpairing on the watch
forgets the key there.

On your Wi-Fi the watch talks to Flash over plain HTTP, like a phone on
the same network does. Use the public link for HTTPS.

## Layout

```
flash-extension.json   the Flash extension: the Watch panel
extension/watch.html   the panel: the code, the address, paired watches
watch/                 the watchOS app (made into a project by XcodeGen)
scripts/watch.sh       build, run in the simulator, install, screenshots
```

## License

MIT
