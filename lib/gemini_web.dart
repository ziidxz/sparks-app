import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A self-contained, unofficial Gemini web client.
///
/// Talks to gemini.google.com exactly like the browser does, so the app can
/// stream answers with no API key and no backend server. Works in guest mode
/// (no login) and, if cookies are supplied, in signed-in mode.
///
/// Protocol reverse-engineered from HanaokaYuzu/Gemini-API (MIT).
const String kGeminiBase = 'https://gemini.google.com';
const String _ua =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

const List<dynamic> kDefaultMetadata = ['', '', '', null, null, null, null, null, null, ''];

final RegExp _artifactsRe = RegExp(r'https?://googleusercontent\.com/(?:\w+/)+\d+\n*');
final RegExp _wsRe = RegExp(r'\s');

dynamic _getNested(dynamic data, List<dynamic> path, [dynamic def]) {
  dynamic cur = data;
  for (final key in path) {
    if (cur is List && key is int) {
      if (key >= -cur.length && key < cur.length) {
        cur = cur[key];
      } else {
        return def;
      }
    } else if (cur is Map && cur.containsKey(key)) {
      cur = cur[key];
    } else {
      return def;
    }
  }
  return cur ?? def;
}

class _FrameParser {
  String _buf = '';
  int? _expected;
  int _start = 0;
  int _scannedChars = 0;
  int _scannedUnits = 0;
  bool _prefixChecked = false;

  void _stripPrefix() {
    if (_prefixChecked) return;
    const p = ")]}'";
    if (_buf.length < p.length && p.startsWith(_buf)) return;
    if (_buf.startsWith(p)) _buf = _buf.substring(p.length).replaceFirst(RegExp(r'^\s+'), '');
    _prefixChecked = true;
  }

  bool _readLength() {
    int pos = 0;
    while (pos < _buf.length && _wsRe.hasMatch(_buf[pos])) {
      pos++;
    }
    if (pos > 0) _buf = _buf.substring(pos);
    if (_buf.isEmpty) return false;
    final m = RegExp(r'^(\d+)\n').firstMatch(_buf);
    if (m == null) return false;
    _expected = int.parse(m.group(1)!);
    _start = m.group(1)!.length;
    _scannedChars = 0;
    _scannedUnits = 0;
    return true;
  }

  void _scan() {
    final expected = _expected;
    if (expected == null) return;
    int idx = _start + _scannedChars;
    final limit = _buf.length;
    while (_scannedUnits < expected && idx < limit) {
      final u = _buf.codeUnitAt(idx) > 0xffff ? 2 : 1;
      if (_scannedUnits + u > expected) break;
      _scannedUnits += u;
      _scannedChars++;
      idx++;
    }
  }

  List<dynamic> feed(String content) {
    if (content.isNotEmpty) _buf += content;
    _stripPrefix();
    final out = <dynamic>[];
    while ((_expected != null || _readLength()) && _expected != null) {
      _scan();
      if (_scannedUnits < _expected!) break;
      final end = _start + _scannedChars;
      final chunk = _buf.substring(_start, end);
      _buf = _buf.substring(end);
      _expected = null;
      _start = 0;
      _scannedChars = 0;
      _scannedUnits = 0;
      if (chunk.trim().isEmpty) continue;
      dynamic parsed;
      try {
        parsed = jsonDecode(chunk);
      } catch (_) {
        continue;
      }
      if (parsed is List) {
        out.addAll(parsed);
      } else {
        out.add(parsed);
      }
    }
    return out;
  }

  List<dynamic> flush() => feed('');
}

class GeminiWeb {
  GeminiWeb({Map<String, String>? cookies}) : _cookies = {...?cookies} {
    _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  }

  final Map<String, String> _cookies;
  late final HttpClient _http;

  String _at = '';
  String? _bl;
  String? _fsid;
  String _lang = 'en';
  List<dynamic> _metadata = kDefaultMetadata;
  int _reqid = 10000 + DateTime.now().microsecondsSinceEpoch % 80000;
  bool _running = false;

  bool get isAuthenticated => _cookies.containsKey('__Secure-1PSID');
  Map<String, String> get cookies => Map.unmodifiable(_cookies);

  void addCookies(Map<String, String> extra) {
    _cookies.addAll(extra);
    _running = false;
  }

  String _cookieHeader() => _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _absorb(HttpClientResponse res) {
    res.headers.forEach((name, values) {
      if (name.toLowerCase() != 'set-cookie') return;
      for (final sc in values) {
        final pair = sc.split(';').first.trim();
        final i = pair.indexOf('=');
        if (i > 0) _cookies[pair.substring(0, i).trim()] = pair.substring(i + 1).trim();
      }
    });
  }

  String? _extract(String html, String key) =>
      RegExp('"$key"\\s*:\\s*"(.*?)"').firstMatch(html)?.group(1);

  Future<void> init() async {
    final req = await _http.getUrl(Uri.parse('https://gemini.google.com/app'));
    req.headers.set('user-agent', _ua);
    req.headers.set('accept-language', 'en-US,en;q=0.9');
    req.headers.set('accept', 'text/html,*/*');
    if (_cookies.isNotEmpty) req.headers.set('cookie', _cookieHeader());
    final res = await req.close();
    _absorb(res);
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw Exception('init status ${res.statusCode}');
    _bl = _extract(body, 'cfb2h');
    _fsid = _extract(body, 'FdrFJe');
    _lang = _extract(body, 'TuX5cc') ?? 'en';
    _at = _extract(body, 'SNlM0e') ?? '';
    _running = true;
  }

  String _newUuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    return ('${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
            '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}')
        .toUpperCase();
  }

  Stream<String> generate(String prompt) async* {
    if (!_running) await init();

    final reqid = _reqid;
    _reqid += 100000;

    final inner = List<dynamic>.filled(81, null);
    inner[0] = [prompt, 0, null, null, null, null, 0];
    inner[1] = [_lang];
    inner[2] = _metadata;
    inner[6] = [1];
    inner[7] = 1;
    inner[10] = 1;
    inner[11] = 0;
    inner[17] = [[0]];
    inner[18] = 0;
    inner[27] = 1;
    inner[30] = [4];
    inner[41] = [1];
    inner[53] = 0;
    inner[61] = [];
    inner[68] = 1;
    inner[79] = 1;
    inner[80] = 1;
    final uuid = _newUuid();
    inner[59] = uuid;

    final params = <String, String>{'hl': _lang, '_reqid': '$reqid', 'rt': 'c'};
    if (_bl != null) params['bl'] = _bl!;
    if (_fsid != null) params['f.sid'] = _fsid!;
    final uri = Uri.parse(
      'https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate',
    ).replace(queryParameters: params);

    final body = 'at=${Uri.encodeQueryComponent(_at)}'
        '&f.req=${Uri.encodeQueryComponent(jsonEncode([null, jsonEncode(inner)]))}';

    final req = await _http.postUrl(uri);
    req.headers.set('content-type', 'application/x-www-form-urlencoded;charset=utf-8');
    req.headers.set('origin', 'https://gemini.google.com');
    req.headers.set('referer', 'https://gemini.google.com/');
    req.headers.set('x-same-domain', '1');
    req.headers.set('user-agent', _ua);
    req.headers.set('x-goog-ext-525005358-jspb', '["$uuid",1]');
    if (_cookies.isNotEmpty) req.headers.set('cookie', _cookieHeader());
    final bodyBytes = utf8.encode(body);
    req.headers.contentLength = bodyBytes.length;
    req.add(bodyBytes);

    final res = await req.close();
    _absorb(res);
    if (res.statusCode != 200) throw Exception('generate status ${res.statusCode}');

    final parser = _FrameParser();
    String lastText = '';

    List<String> handle(List<dynamic> parts) {
      final out = <String>[];
      for (final part in parts) {
        if (part is! List || part.length < 3) continue;
        final raw = part[2];
        if (raw is! String || raw.isEmpty) continue;
        dynamic obj;
        try {
          obj = jsonDecode(raw);
        } catch (_) {
          continue;
        }
        final meta = _getNested(obj, [1]);
        if (meta is List) _metadata = meta;
        final cands = _getNested(obj, [4]);
        if (cands is! List) continue;
        for (final cand in cands) {
          final t = _getNested(cand, [1, 0], '');
          if (t is! String) continue;
          final clean = t.replaceAll(_artifactsRe, '');
          final head = lastText.length <= 10 ? lastText : lastText.substring(0, 10);
          if (clean.length > lastText.length || !clean.startsWith(head)) {
            out.add(clean.startsWith(lastText) ? clean.substring(lastText.length) : clean);
            lastText = clean;
          }
        }
      }
      return out;
    }

    await for (final text in res.transform(utf8.decoder)) {
      for (final d in handle(parser.feed(text))) {
        yield d;
      }
    }
    for (final d in handle(parser.flush())) {
      yield d;
    }
  }

  void close() => _http.close(force: true);
}
