import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gemini_web.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SparksApp());
}

const Color kBg = Color(0xFF10131A);
const Color kCard = Color(0xFF1B2029);
const Color kAccent = Color(0xFF9BE15D);
const Color kText = Color(0xFFE8EAED);
const Color kMuted = Color(0xFF6B7280);
const String kChromeUA =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

class SparksApp extends StatelessWidget {
  const SparksApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'Sparks',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: base.colorScheme.copyWith(
          primary: kAccent,
          secondary: const Color(0xFF6EE7B7),
        ),
      ),
      home: const RootGate(),
    );
  }
}

/// Loads the saved mode (guest / account) and routes to setup or chat.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  bool _loading = true;
  String? _mode; // null = first run
  Map<String, String>? _cookies;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString('mode');
    Map<String, String>? cookies;
    final cj = prefs.getString('cookies');
    if (cj != null && cj.isNotEmpty) {
      try {
        cookies = (jsonDecode(cj) as Map).map((k, v) => MapEntry('$k', '$v'));
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _cookies = cookies;
      _loading = false;
    });
  }

  Future<void> _setMode(String mode, {Map<String, String>? cookies}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mode', mode);
    if (cookies != null && cookies.isNotEmpty) {
      await prefs.setString('cookies', jsonEncode(cookies));
    } else {
      await prefs.remove('cookies');
    }
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _cookies = cookies;
    });
  }

  Future<void> _signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _mode = null;
      _cookies = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_mode == null) {
      return SetupScreen(
        onGuest: () => _setMode('guest'),
        onSignedIn: (cookies) => _setMode('account', cookies: cookies),
      );
    }
    return ChatScreen(
      cookies: _mode == 'account' ? _cookies : null,
      onSignOut: _signOut,
    );
  }
}

/// First-run chooser: guest or signed-in Gemini account.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, required this.onGuest, required this.onSignedIn});

  final VoidCallback onGuest;
  final ValueChanged<Map<String, String>> onSignedIn;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 2),
              const Icon(Icons.auto_awesome, color: kAccent, size: 64),
              const SizedBox(height: 18),
              const Text(
                'Sparks',
                textAlign: TextAlign.center,
                style: TextStyle(color: kText, fontSize: 30, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              const Text(
                'Chat powered by Gemini.\nChoose how you want to get started.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kMuted, fontSize: 15, height: 1.4),
              ),
              const Spacer(flex: 2),
              _Option(
                icon: Icons.person_outline,
                title: 'Sign in with Google',
                subtitle: 'Use your Google AI / Gemini account',
                filled: true,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LoginScreen(onSignedIn: onSignedIn),
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              _Option(
                icon: Icons.public,
                title: 'Continue as guest',
                subtitle: 'No sign in needed',
                filled: false,
                onTap: onGuest,
              ),
              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.filled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? kBg : kText;
    return Material(
      color: filled ? kAccent : kCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              Icon(icon, color: fg, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: filled ? kBg.withValues(alpha: 0.75) : kMuted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: fg),
            ],
          ),
        ),
      ),
    );
  }
}

/// In-app Google sign-in. Reads the Gemini session cookies once signed in.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSignedIn});

  final ValueChanged<Map<String, String>> onSignedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  double _progress = 0;
  bool _checking = false;

  Future<Map<String, String>> _readCookies() async {
    final out = <String, String>{};
    for (final url in ['https://gemini.google.com', 'https://accounts.google.com']) {
      try {
        final list = await CookieManager.instance().getCookies(url: WebUri(url));
        for (final c in list) {
          if (c.value != null && c.value!.isNotEmpty) out[c.name] = c.value!;
        }
      } catch (_) {}
    }
    return out;
  }

  Future<void> _finish() async {
    setState(() => _checking = true);
    final cookies = await _readCookies();
    if (!mounted) return;
    setState(() => _checking = false);
    if (!cookies.containsKey('__Secure-1PSID')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not signed in yet. Finish signing in, then tap Continue.')),
      );
      return;
    }
    Navigator.of(context).pop();
    widget.onSignedIn(cookies);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text('Sign in'),
      ),
      body: Column(
        children: [
          if (_progress < 1)
            LinearProgressIndicator(value: _progress == 0 ? null : _progress, color: kAccent),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri('https://gemini.google.com/app')),
              initialSettings: InAppWebViewSettings(
                userAgent: kChromeUA,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                transparentBackground: false,
                supportMultipleWindows: true,
              ),
              onProgressChanged: (controller, progress) {
                if (mounted) setState(() => _progress = progress / 100);
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              color: const Color(0xFF161B22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Sign in with your Google account, then tap “I’ve signed in”.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _checking ? null : _finish,
                      style: FilledButton.styleFrom(
                        backgroundColor: kAccent,
                        foregroundColor: kBg,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _checking
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: kBg),
                            )
                          : const Text('I’ve signed in'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class Msg {
  Msg({required this.role, required this.text, this.streaming = false});
  final String role; // 'user' | 'assistant'
  String text;
  bool streaming;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.cookies, required this.onSignOut});

  final Map<String, String>? cookies;
  final Future<void> Function() onSignOut;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Msg> _messages = <Msg>[];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late GeminiWeb _gemini;
  bool _busy = false;

  bool get _signedIn => widget.cookies != null && widget.cookies!.containsKey('__Secure-1PSID');

  @override
  void initState() {
    super.initState();
    _gemini = GeminiWeb(cookies: widget.cookies);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _gemini.close();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _messages.add(Msg(role: 'user', text: text));
      _messages.add(Msg(role: 'assistant', text: '', streaming: true));
      _busy = true;
    });
    _toBottom();

    final assistant = _messages.last;
    try {
      await for (final delta in _gemini.generate(text)) {
        if (!mounted) break;
        setState(() => assistant.text += delta);
        _toBottom();
      }
      if (assistant.text.isEmpty) assistant.text = '(empty reply)';
    } catch (e) {
      final hint = _signedIn ? '' : '\n\nTip: sign in from the menu for higher limits.';
      assistant.text = assistant.text.isEmpty
          ? "Couldn't reach Gemini.\n\n$e$hint"
          : assistant.text;
    } finally {
      if (mounted) {
        setState(() {
          assistant.streaming = false;
          _busy = false;
        });
        _toBottom();
      }
    }
  }

  void _clearChat() {
    setState(() => _messages.clear());
    _gemini.close();
    _gemini = GeminiWeb(cookies: widget.cookies);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        titleSpacing: 12,
        title: Row(
          children: [
            const CircleAvatar(
              backgroundColor: kAccent,
              child: Icon(Icons.auto_awesome, color: kBg, size: 20),
            ),
            const SizedBox(width: 10),
            const Text('Sparks'),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _signedIn ? 'account' : 'guest',
                style: const TextStyle(color: kMuted, fontSize: 11),
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) async {
              if (v == 'clear') _clearChat();
              if (v == 'switch') await widget.onSignOut();
            },
            itemBuilder: (c) => const [
              PopupMenuItem(value: 'clear', child: Text('Clear chat')),
              PopupMenuItem(value: 'switch', child: Text('Sign out / switch account')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const _EmptyState()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    itemCount: _messages.length,
                    itemBuilder: (c, i) => _bubble(_messages[i]),
                  ),
          ),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _bubble(Msg m) {
    final isUser = m.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF2A3A20) : kCard,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: (m.streaming && m.text.isEmpty)
            ? const _TypingDots()
            : SelectableText(
                m.text,
                style: const TextStyle(color: kText, fontSize: 15, height: 1.35),
              ),
      ),
    );
  }

  Widget _inputBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        color: kBg,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: const TextStyle(color: kText),
                decoration: InputDecoration(
                  hintText: 'Message Sparks...',
                  hintStyle: const TextStyle(color: kMuted),
                  filled: true,
                  fillColor: kCard,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: kAccent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _busy ? null : _send,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    _busy ? Icons.hourglass_top : Icons.send,
                    color: kBg,
                    size: 22,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, color: kAccent, size: 44),
            SizedBox(height: 14),
            Text(
              'Hi, I’m Sparks.\nAsk me anything to get started.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kMuted, fontSize: 15, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (c, _) {
        final n = (_c.value * 3).floor() % 3 + 1;
        return Text('.' * n, style: const TextStyle(color: kAccent, fontSize: 20));
      },
    );
  }
}
