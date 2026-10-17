# sparks

a simple gemini chat app for android, made with flutter.

no server, no api key, no terminal. just open the app, pick sign in or guest, and chat.

## how it works

on the first run u pick:

- **sign in with google** - opens gemini web, u log in once, and the app keeps your session cookies so u dont have to log in again
- **continue as guest** - uses gemini web without logging in. lower limits but it just works

after that u get a normal chat screen with streaming replies, clear chat, and sign out / switch account.

## build it yourself

u need flutter installed.

```
flutter pub get
flutter build apk --debug
```

the apk shows up in `build/app/outputs/flutter-apk/`.

## notes

- guest mode has lower limits. sign in if u want more.
- this is just a wrapper around gemini web. nothing fancy.

if this helped u, star it.
