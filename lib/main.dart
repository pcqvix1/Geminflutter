import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart' hide Formats;
import 'package:uuid/uuid.dart';

const _defaultModel = String.fromEnvironment(
  'GEMINI_MODEL',
  defaultValue: 'gemma-4-31b-it',
);
const _compiledApiKey = String.fromEnvironment('GEMINI_API_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  final store = LocalStore(
    sessions: await Hive.openBox('chat_sessions'),
    messages: await Hive.openBox('chat_messages'),
    settings: await Hive.openBox('settings'),
    cache: await Hive.openBox('response_cache'),
  );
  runApp(
    ChangeNotifierProvider(
      create: (_) => ChatController(store, GeminiService())..load(),
      child: const GeminiChatApp(),
    ),
  );
}

class GeminiChatApp extends StatelessWidget {
  const GeminiChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final light = ColorScheme.fromSeed(
      seedColor: const Color(0xFF16697A),
      brightness: Brightness.light,
    );
    final dark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4FB3BF),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Gemini Chat',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: light,
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: dark,
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const ChatShell(),
    );
  }
}

// Models stay serializable as plain maps so Hive works on Android, Windows and
// Web/IndexedDB without generated adapters or platform-specific code.
enum MessageRole { user, model, error }

enum AttachmentKind { document, image, text }

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static ChatSession fromMap(Map data) => ChatSession(
    id: data['id'] as String,
    title: data['title'] as String,
    createdAt: DateTime.parse(data['createdAt'] as String),
    updatedAt: DateTime.parse(data['updatedAt'] as String),
  );
}

class ChatAttachment {
  ChatAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.bytes,
    required this.kind,
  });

  final String id;
  final String name;
  final String mimeType;
  final Uint8List bytes;
  final AttachmentKind kind;

  int get size => bytes.length;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'bytes': base64Encode(bytes),
    'kind': kind.name,
  };

  static ChatAttachment fromMap(Map data) => ChatAttachment(
    id: data['id'] as String,
    name: data['name'] as String,
    mimeType: data['mimeType'] as String,
    bytes: base64Decode(data['bytes'] as String),
    kind: AttachmentKind.values.byName(data['kind'] as String),
  );
}

const _streamUiFrame = Duration(milliseconds: 80);

class ChatMessage extends ChangeNotifier {
  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.text,
    required this.createdAt,
    this.thoughtText = '',
    this.attachments = const [],
    this.isStreaming = false,
  });

  final String id;
  final String sessionId;
  final MessageRole role;
  String text;
  String thoughtText;
  final DateTime createdAt;
  final List<ChatAttachment> attachments;
  bool isStreaming;
  Timer? _streamNotifyTimer;
  bool _hasPendingStreamNotify = false;

  Map<String, dynamic> toMap() => {
    'id': id,
    'sessionId': sessionId,
    'role': role.name,
    'text': text,
    'thoughtText': thoughtText,
    'createdAt': createdAt.toIso8601String(),
    'attachments': attachments.map((a) => a.toMap()).toList(),
  };

  static ChatMessage fromMap(Map data) => ChatMessage(
    id: data['id'] as String,
    sessionId: data['sessionId'] as String,
    role: MessageRole.values.byName(data['role'] as String),
    text: data['text'] as String,
    thoughtText: (data['thoughtText'] as String?) ?? '',
    createdAt: DateTime.parse(data['createdAt'] as String),
    attachments: ((data['attachments'] as List?) ?? const [])
        .map((a) => ChatAttachment.fromMap(Map<String, dynamic>.from(a)))
        .toList(),
  );

  void appendStreamChunk(GeminiStreamChunk chunk) {
    if (chunk.isThought) {
      thoughtText += chunk.text;
    } else {
      text += chunk.text;
    }
    _notifyStreamFrame();
  }

  void finishStreaming() {
    _streamNotifyTimer?.cancel();
    _streamNotifyTimer = null;
    _hasPendingStreamNotify = false;
    isStreaming = false;
    notifyListeners();
  }

  void _notifyStreamFrame() {
    if (_streamNotifyTimer?.isActive ?? false) {
      _hasPendingStreamNotify = true;
      return;
    }
    notifyListeners();
    _streamNotifyTimer = Timer(_streamUiFrame, () {
      if (!_hasPendingStreamNotify) return;
      _hasPendingStreamNotify = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _streamNotifyTimer?.cancel();
    super.dispose();
  }
}

class GeminiStreamChunk {
  const GeminiStreamChunk({required this.text, required this.isThought});

  final String text;
  final bool isThought;
}

class LocalStore {
  LocalStore({
    required this.sessions,
    required this.messages,
    required this.settings,
    required this.cache,
  });

  final Box sessions;
  final Box messages;
  final Box settings;
  final Box cache;

  List<ChatSession> loadSessions() {
    final items = sessions.values
        .map((v) => ChatSession.fromMap(Map<String, dynamic>.from(v as Map)))
        .toList();
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return items;
  }

  List<ChatMessage> loadMessages(String sessionId) {
    final items = messages.values
        .map((v) => ChatMessage.fromMap(Map<String, dynamic>.from(v as Map)))
        .where((m) => m.sessionId == sessionId)
        .toList();
    items.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return items;
  }

  Future<void> saveSession(ChatSession session) =>
      sessions.put(session.id, session.toMap());

  Future<void> saveMessage(ChatMessage message) =>
      messages.put(message.id, message.toMap());

  Future<void> deleteSession(String sessionId) async {
    await sessions.delete(sessionId);
    final ids = messages.values
        .map((v) => ChatMessage.fromMap(Map<String, dynamic>.from(v as Map)))
        .where((m) => m.sessionId == sessionId)
        .map((m) => m.id)
        .toList();
    await messages.deleteAll(ids);
  }
}

class GeminiService {
  final _client = http.Client();

  Stream<GeminiStreamChunk> streamAnswer({
    required String apiKey,
    required String model,
    required List<ChatMessage> context,
  }) async* {
    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$model:streamGenerateContent',
      {'alt': 'sse'},
    );
    final request = http.Request('POST', uri)
      ..headers.addAll({
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      })
      ..body = jsonEncode({
        'systemInstruction': {
          'parts': [
            {
              'text':
                  'Voce e um assistente claro, util e cuidadoso. Responda em portugues quando o usuario escrever em portugues.',
            },
          ],
        },
        'contents': context
            .where(
              (m) => m.role == MessageRole.user || m.role == MessageRole.model,
            )
            .map(_contentFromMessage)
            .toList(),
        'generationConfig': {
          'temperature': 0.7,
          'topP': 0.95,
          'maxOutputTokens': 8192,
          if (_supportsThinkingSummaries(model))
            'thinkingConfig': {'includeThoughts': true},
        },
      });

    final response = await _client
        .send(request)
        .timeout(
          const Duration(seconds: 45),
          onTimeout: () => throw TimeoutException('Tempo limite excedido.'),
        );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw GeminiException.fromStatus(response.statusCode, body);
    }

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final decoded = jsonDecode(data) as Map<String, dynamic>;
      final parts = decoded['candidates']?[0]?['content']?['parts'] as List?;
      if (parts == null) continue;
      for (final part in parts) {
        final partMap = part as Map;
        final text = partMap['text'];
        if (text is String && text.isNotEmpty) {
          yield GeminiStreamChunk(
            text: text,
            isThought: partMap['thought'] == true,
          );
        }
      }
    }
  }

  bool _supportsThinkingSummaries(String model) {
    final normalized = model.toLowerCase();
    return normalized.contains('gemini-2.5') ||
        normalized.contains('gemini-3') ||
        normalized.contains('thinking');
  }

  Map<String, dynamic> _contentFromMessage(ChatMessage message) => {
    'role': message.role == MessageRole.model ? 'model' : 'user',
    'parts': [
      if (message.text.trim().isNotEmpty) {'text': message.text.trim()},
      for (final attachment in message.attachments)
        if (attachment.kind == AttachmentKind.text)
          {
            'text':
                'Arquivo ${attachment.name}:\n${utf8.decode(attachment.bytes, allowMalformed: true)}',
          }
        else
          {
            'inline_data': {
              'mime_type': attachment.mimeType,
              'data': base64Encode(attachment.bytes),
            },
          },
    ],
  };
}

class GeminiException implements Exception {
  GeminiException(this.message);
  final String message;

  factory GeminiException.fromStatus(int status, String body) {
    if (status == 401 || status == 403) {
      return GeminiException('Chave Gemini invalida ou sem permissao.');
    }
    if (status == 429) {
      return GeminiException(
        'Limite de requisicoes atingido. Tente novamente em instantes.',
      );
    }
    if (status >= 500) {
      return GeminiException(
        'O Gemini esta indisponivel agora. Tente novamente.',
      );
    }
    try {
      final data = jsonDecode(body);
      final message = data['error']?['message'];
      if (message is String) return GeminiException(message);
    } catch (_) {}
    return GeminiException('Falha ao chamar Gemini ($status).');
  }

  @override
  String toString() => message;
}

class ChatController extends ChangeNotifier {
  ChatController(this.store, this.gemini);

  final LocalStore store;
  final GeminiService gemini;
  final _uuid = const Uuid();

  List<ChatSession> sessions = [];
  List<ChatMessage> messages = [];
  final Map<String, String> _sessionSearchIndex = {};
  String? activeSessionId;
  String query = '';
  bool isSending = false;
  bool isDragging = false;

  String get apiKey =>
      (store.settings.get('apiKey') as String?) ?? _compiledApiKey;
  String get model => (store.settings.get('model') as String?) ?? _defaultModel;
  bool get hasApiKey => apiKey.trim().isNotEmpty;
  ChatSession? get activeSession =>
      sessions.where((s) => s.id == activeSessionId).firstOrNull;

  List<ChatSession> get filteredSessions {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return sessions;
    return sessions.where((s) {
      final indexed = _sessionSearchIndex[s.id] ?? s.title.toLowerCase();
      return indexed.contains(q);
    }).toList();
  }

  Future<void> load() async {
    sessions = store.loadSessions();
    _rebuildSearchIndex();
    if (sessions.isEmpty) {
      await newSession();
      return;
    }
    await selectSession(sessions.first.id);
  }

  Future<void> setApiConfig(String key, String selectedModel) async {
    await store.settings.put('apiKey', key.trim());
    await store.settings.put(
      'model',
      selectedModel.trim().isEmpty ? _defaultModel : selectedModel.trim(),
    );
    notifyListeners();
  }

  Future<void> newSession() async {
    final session = ChatSession(
      id: _uuid.v4(),
      title: 'Nova conversa',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await store.saveSession(session);
    sessions = store.loadSessions();
    _sessionSearchIndex[session.id] = session.title.toLowerCase();
    activeSessionId = session.id;
    messages = [];
    notifyListeners();
  }

  Future<void> selectSession(String id) async {
    activeSessionId = id;
    messages = store.loadMessages(id);
    _indexActiveSession();
    notifyListeners();
  }

  Future<void> removeSession(String id) async {
    await store.deleteSession(id);
    sessions = store.loadSessions();
    _sessionSearchIndex.remove(id);
    if (activeSessionId == id) {
      if (sessions.isEmpty) {
        await newSession();
      } else {
        await selectSession(sessions.first.id);
      }
    } else {
      notifyListeners();
    }
  }

  void setQuery(String value) {
    query = value;
    notifyListeners();
  }

  Future<void> send(String text, List<ChatAttachment> attachments) async {
    final session = activeSession;
    if (session == null || isSending) return;
    final cleanText = text.trim();
    if (cleanText.isEmpty && attachments.isEmpty) return;
    if (!hasApiKey) {
      _appendError(
        session.id,
        'Configure sua chave da API Gemini antes de enviar.',
      );
      return;
    }

    final userMessage = ChatMessage(
      id: _uuid.v4(),
      sessionId: session.id,
      role: MessageRole.user,
      text: cleanText,
      createdAt: DateTime.now(),
      attachments: attachments,
    );
    messages.add(userMessage);
    await store.saveMessage(userMessage);

    if (session.title == 'Nova conversa') {
      session.title = _titleFrom(cleanText, attachments);
    }
    session.updatedAt = DateTime.now();
    await store.saveSession(session);
    sessions = store.loadSessions();
    _indexSession(session, messages);

    final cacheKey = _cacheKey(messages);
    final cached = store.cache.get(cacheKey) as String?;
    if (cached != null) {
      final cachedMessage = ChatMessage(
        id: _uuid.v4(),
        sessionId: session.id,
        role: MessageRole.model,
        text: cached,
        createdAt: DateTime.now(),
      );
      messages.add(cachedMessage);
      await store.saveMessage(cachedMessage);
      _indexSession(session, messages);
      notifyListeners();
      return;
    }

    final answer = ChatMessage(
      id: _uuid.v4(),
      sessionId: session.id,
      role: MessageRole.model,
      text: '',
      createdAt: DateTime.now(),
      isStreaming: true,
    );
    messages.add(answer);
    isSending = true;
    notifyListeners();

    try {
      await for (final chunk in gemini.streamAnswer(
        apiKey: apiKey,
        model: model,
        context: messages.take(messages.length - 1).toList(),
      )) {
        answer.appendStreamChunk(chunk);
      }
      answer.finishStreaming();
      await store.saveMessage(answer);
      await store.cache.put(cacheKey, answer.text);
      _indexSession(session, messages);
    } on TimeoutException {
      messages.remove(answer);
      answer.dispose();
      _appendError(
        session.id,
        'A requisicao demorou demais. Verifique sua rede e tente novamente.',
      );
    } catch (e) {
      messages.remove(answer);
      answer.dispose();
      _appendError(
        session.id,
        e is GeminiException ? e.message : 'Falha de rede: $e',
      );
    } finally {
      isSending = false;
      notifyListeners();
    }
  }

  void setDragging(bool value) {
    isDragging = value;
    notifyListeners();
  }

  Future<void> exportActive({required bool asPdf}) async {
    final session = activeSession;
    if (session == null) return;
    final date = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
    final safeTitle = session.title.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_');
    if (asPdf) {
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          build: (_) => [
            pw.Text(
              session.title,
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 16),
            for (final message in messages) ...[
              pw.Text(
                _roleLabel(message.role),
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              pw.Text(message.text.isEmpty ? '[Anexos]' : message.text),
              pw.SizedBox(height: 10),
            ],
          ],
        ),
      );
      await FilePicker.saveFile(
        fileName: '${safeTitle}_$date.pdf',
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        bytes: await doc.save(),
      );
    } else {
      final content = messages
          .map(
            (m) =>
                '[${DateFormat('dd/MM/yyyy HH:mm').format(m.createdAt)}] ${_roleLabel(m.role)}\n${m.text}\n',
          )
          .join('\n');
      await FilePicker.saveFile(
        fileName: '${safeTitle}_$date.txt',
        type: FileType.custom,
        allowedExtensions: ['txt'],
        bytes: Uint8List.fromList(utf8.encode(content)),
      );
    }
  }

  Future<void> _appendError(String sessionId, String text) async {
    final error = ChatMessage(
      id: _uuid.v4(),
      sessionId: sessionId,
      role: MessageRole.error,
      text: text,
      createdAt: DateTime.now(),
    );
    messages.add(error);
    await store.saveMessage(error);
    notifyListeners();
  }

  String _titleFrom(String text, List<ChatAttachment> attachments) {
    final source = text.isNotEmpty
        ? text
        : attachments.map((a) => a.name).join(', ');
    return source.length <= 42 ? source : '${source.substring(0, 42)}...';
  }

  String _cacheKey(List<ChatMessage> context) {
    final last = context.last;
    final raw =
        '${last.text}|${last.attachments.map((a) => '${a.name}:${a.size}').join('|')}';
    return base64Url.encode(utf8.encode(raw));
  }

  void _rebuildSearchIndex() {
    _sessionSearchIndex
      ..clear()
      ..addEntries(
        sessions.map((session) {
          final sessionMessages = store.loadMessages(session.id);
          return MapEntry(session.id, _searchTextFor(session, sessionMessages));
        }),
      );
  }

  void _indexActiveSession() {
    final session = activeSession;
    if (session == null) return;
    _indexSession(session, messages);
  }

  void _indexSession(ChatSession session, List<ChatMessage> sessionMessages) {
    _sessionSearchIndex[session.id] = _searchTextFor(session, sessionMessages);
  }

  String _searchTextFor(
    ChatSession session,
    List<ChatMessage> sessionMessages,
  ) {
    final buffer = StringBuffer(session.title.toLowerCase());
    for (final message in sessionMessages) {
      if (message.text.isNotEmpty) {
        buffer
          ..write('\n')
          ..write(message.text.toLowerCase());
      }
    }
    return buffer.toString();
  }
}

extension FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

String _roleLabel(MessageRole role) => switch (role) {
  MessageRole.user => 'Voce',
  MessageRole.model => 'Gemini',
  MessageRole.error => 'Erro',
};

String _mimeFor(String name) {
  final ext = name.split('.').last.toLowerCase();
  return switch (ext) {
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'doc' => 'application/msword',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    _ => 'application/octet-stream',
  };
}

AttachmentKind _kindFor(String mime) {
  if (mime.startsWith('image/')) return AttachmentKind.image;
  if (mime == 'text/plain') return AttachmentKind.text;
  return AttachmentKind.document;
}

class ChatShell extends StatefulWidget {
  const ChatShell({super.key});

  @override
  State<ChatShell> createState() => _ChatShellState();
}

class _ChatShellState extends State<ChatShell> {
  @override
  Widget build(BuildContext context) {
    final isDragging = context.select<ChatController, bool>(
      (controller) => controller.isDragging,
    );
    final controller = context.read<ChatController>();
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 900;
        final main = DropRegion(
          formats: Formats.standardFormats,
          onDropEnter: (_) => controller.setDragging(true),
          onDropLeave: (_) => controller.setDragging(false),
          onDropOver: (_) => DropOperation.copy,
          onPerformDrop: (event) async {
            controller.setDragging(false);
            final attachments = await _attachmentsFromDrop(event);
            if (!context.mounted || attachments.isEmpty) return;
            await showDialog<void>(
              context: context,
              builder: (_) => _DroppedFilesDialog(attachments: attachments),
            );
          },
          child: Stack(
            children: [
              Row(
                children: [
                  if (desktop)
                    const SizedBox(width: 320, child: SessionSidebar()),
                  const Expanded(child: ChatPanel()),
                ],
              ),
              if (isDragging) const _DropOverlay(),
            ],
          ),
        );
        return Scaffold(
          drawer: desktop ? null : const Drawer(child: SessionSidebar()),
          body: SafeArea(child: main),
        );
      },
    );
  }

  Future<List<ChatAttachment>> _attachmentsFromDrop(
    PerformDropEvent event,
  ) async {
    final attachments = <ChatAttachment>[];
    final fileFormats = <FileFormat>[
      Formats.pdf,
      Formats.docx,
      Formats.doc,
      Formats.plainTextFile,
      Formats.png,
      Formats.jpeg,
      Formats.webp,
    ];
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null) continue;
      for (final format in fileFormats) {
        if (!reader.canProvide(format)) continue;
        final completer = Completer<void>();
        reader.getFile(
          format,
          (file) async {
            final name =
                file.fileName ?? await reader.getSuggestedName() ?? 'arquivo';
            final bytes = await file.readAll();
            final mime = _mimeFor(name);
            attachments.add(
              ChatAttachment(
                id: const Uuid().v4(),
                name: name,
                mimeType: mime,
                bytes: bytes,
                kind: _kindFor(mime),
              ),
            );
            completer.complete();
          },
          onError: (error) {
            if (!completer.isCompleted) completer.complete();
          },
        );
        await completer.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () {},
        );
        break;
      }
    }
    return attachments;
  }
}

class SessionSidebar extends StatefulWidget {
  const SessionSidebar({super.key});

  @override
  State<SessionSidebar> createState() => _SessionSidebarState();
}

class _SessionSidebarState extends State<SessionSidebar> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatController>();
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border(right: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, color: colors.primary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Gemini Chat',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: 'Nova conversa',
                  onPressed: controller.newSession,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Buscar historico',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: controller.setQuery,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _SmoothWheelScroll(
              controller: _scrollController,
              child: ListView.builder(
                controller: _scrollController,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: controller.filteredSessions.length,
                itemBuilder: (context, index) {
                  final session = controller.filteredSessions[index];
                  final selected = session.id == controller.activeSessionId;
                  return ListTile(
                    selected: selected,
                    title: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      DateFormat('dd/MM HH:mm').format(session.updatedAt),
                    ),
                    leading: const Icon(Icons.chat_bubble_outline),
                    trailing: IconButton(
                      tooltip: 'Excluir',
                      onPressed: () => controller.removeSession(session.id),
                      icon: const Icon(Icons.delete_outline),
                    ),
                    onTap: () {
                      Navigator.maybePop(context);
                      controller.selectSession(session.id);
                    },
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.tonalIcon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const ApiConfigDialog(),
              ),
              icon: const Icon(Icons.key),
              label: Text(
                controller.hasApiKey ? 'API configurada' : 'Configurar API',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChatPanel extends StatefulWidget {
  const ChatPanel({super.key});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _attachments = <ChatAttachment>[];
  int _lastMessageCount = 0;

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatController>();
    final messageCount = controller.messages.length;
    if (messageCount != _lastMessageCount) {
      _lastMessageCount = messageCount;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(controller.activeSession?.title ?? 'Gemini Chat'),
        leading: MediaQuery.sizeOf(context).width < 900
            ? Builder(
                builder: (context) => IconButton(
                  tooltip: 'Historico',
                  onPressed: () => Scaffold.of(context).openDrawer(),
                  icon: const Icon(Icons.menu),
                ),
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'Exportar TXT',
            onPressed: () => controller.exportActive(asPdf: false),
            icon: const Icon(Icons.text_snippet_outlined),
          ),
          IconButton(
            tooltip: 'Exportar PDF',
            onPressed: () => controller.exportActive(asPdf: true),
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
          IconButton(
            tooltip: 'Configuracoes da API',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const ApiConfigDialog(),
            ),
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!controller.hasApiKey)
            MaterialBanner(
              content: const Text(
                'Informe GEMINI_API_KEY por --dart-define ou configure a chave no app.',
              ),
              actions: [
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const ApiConfigDialog(),
                  ),
                  child: const Text('Configurar'),
                ),
              ],
            ),
          Expanded(
            child: controller.messages.isEmpty
                ? const _EmptyState()
                : _SmoothWheelScroll(
                    controller: _scrollController,
                    child: ListView.builder(
                      controller: _scrollController,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      itemCount: controller.messages.length,
                      addAutomaticKeepAlives: false,
                      itemBuilder: (context, index) => MessageBubble(
                        key: ValueKey(controller.messages[index].id),
                        message: controller.messages[index],
                      ),
                    ),
                  ),
          ),
          if (controller.isSending) const _TypingIndicator(),
          _Composer(
            textController: _textController,
            attachments: _attachments,
            onPick: _pickFiles,
            onRemove: (a) => setState(() => _attachments.remove(a)),
            onSend: () async {
              final text = _textController.text;
              final files = List<ChatAttachment>.from(_attachments);
              _textController.clear();
              setState(_attachments.clear);
              await context.read<ChatController>().send(text, files);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.custom,
      allowedExtensions: [
        'pdf',
        'txt',
        'doc',
        'docx',
        'png',
        'jpg',
        'jpeg',
        'webp',
      ],
    );
    if (result == null) return;
    setState(() {
      _attachments.addAll(
        result.files.where((f) => f.bytes != null).map((file) {
          final mime = _mimeFor(file.name);
          return ChatAttachment(
            id: const Uuid().v4(),
            name: file.name,
            mimeType: mime,
            bytes: file.bytes!,
            kind: _kindFor(mime),
          );
        }),
      );
    });
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }
}

class _SmoothWheelScroll extends StatefulWidget {
  const _SmoothWheelScroll({
    required this.controller,
    required this.child,
    this.duration = const Duration(milliseconds: 190),
    this.curve = Curves.easeOutCubic,
  });

  final ScrollController controller;
  final Widget child;
  final Duration duration;
  final Curve curve;

  @override
  State<_SmoothWheelScroll> createState() => _SmoothWheelScrollState();
}

class _SmoothWheelScrollState extends State<_SmoothWheelScroll> {
  Timer? _targetResetTimer;
  double? _targetPixels;

  @override
  void dispose() {
    _targetResetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _handlePointerSignal,
      child: widget.child,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !widget.controller.hasClients) return;

    final position = widget.controller.position;
    final delta = event.scrollDelta.dy;
    if (delta == 0 || position.maxScrollExtent <= position.minScrollExtent) {
      return;
    }

    final basePixels = _targetPixels ?? position.pixels;
    final targetPixels = math
        .min(
          math.max(basePixels + delta, position.minScrollExtent),
          position.maxScrollExtent,
        )
        .toDouble();

    if (targetPixels == position.pixels) return;

    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _targetPixels = targetPixels;
      unawaited(
        widget.controller.animateTo(
          targetPixels,
          duration: widget.duration,
          curve: widget.curve,
        ),
      );
      _targetResetTimer?.cancel();
      _targetResetTimer = Timer(
        widget.duration + const Duration(milliseconds: 90),
        () {
          _targetPixels = null;
        },
      );
    });
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: message,
      builder: (context, _) => _MessageBubbleBody(message: message),
    );
  }
}

class _MessageBubbleBody extends StatelessWidget {
  const _MessageBubbleBody({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isUser = message.role == MessageRole.user;
    final isError = message.role == MessageRole.error;
    final bg = isError
        ? colors.errorContainer
        : isUser
        ? colors.primaryContainer
        : colors.surfaceContainerHighest;
    final fg = isError
        ? colors.onErrorContainer
        : isUser
        ? colors.onPrimaryContainer
        : colors.onSurface;
    return RepaintBoundary(
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: DefaultTextStyle(
              style: TextStyle(color: fg, height: 1.35),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isUser ? Icons.person_outline : Icons.auto_awesome,
                        size: 16,
                        color: fg,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _roleLabel(message.role),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (message.isStreaming) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ],
                    ],
                  ),
                  if (message.thoughtText.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _ThinkingBlock(
                      text: message.thoughtText,
                      foreground: fg,
                      isStreaming: message.isStreaming,
                      styleSheet: _bubbleMarkdownStyleSheet(context, fg),
                    ),
                  ],
                  if (message.text.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _MessageText(
                      text: message.text,
                      isStreaming: message.isStreaming,
                      foreground: fg,
                      styleSheet: _bubbleMarkdownStyleSheet(context, fg),
                    ),
                  ],
                  if (message.attachments.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: message.attachments
                          .map((a) => _AttachmentChip(attachment: a))
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _bubbleMarkdownStyleSheet(
    BuildContext context,
    Color foreground,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body =
        theme.textTheme.bodyMedium?.copyWith(color: foreground, height: 1.35) ??
        TextStyle(color: foreground, height: 1.35);
    final titleStyle =
        theme.textTheme.titleMedium?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ) ??
        body.copyWith(fontWeight: FontWeight.w700, height: 1.25);

    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      a: body.copyWith(
        color: colors.primary,
        decoration: TextDecoration.underline,
        decorationColor: colors.primary,
      ),
      p: body,
      blockquote: body,
      code: body.copyWith(
        backgroundColor: colors.surface.withValues(alpha: 0.35),
        fontFamily: 'monospace',
      ),
      codeblockDecoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(6),
      ),
      h1: titleStyle.copyWith(fontSize: 22),
      h2: titleStyle.copyWith(fontSize: 20),
      h3: titleStyle.copyWith(fontSize: 18),
      h4: titleStyle,
      h5: titleStyle,
      h6: titleStyle,
      listBullet: body,
      tableBody: body,
      tableHead: body.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _MessageText extends StatelessWidget {
  const _MessageText({
    required this.text,
    required this.isStreaming,
    required this.foreground,
    required this.styleSheet,
  });

  final String text;
  final bool isStreaming;
  final Color foreground;
  final MarkdownStyleSheet styleSheet;

  @override
  Widget build(BuildContext context) {
    if (isStreaming) {
      return SelectableText(
        text,
        style: TextStyle(color: foreground, height: 1.35),
      );
    }
    return MarkdownBody(data: text, selectable: true, styleSheet: styleSheet);
  }
}

class _ThinkingBlock extends StatelessWidget {
  const _ThinkingBlock({
    required this.text,
    required this.foreground,
    required this.isStreaming,
    required this.styleSheet,
  });

  final String text;
  final Color foreground;
  final bool isStreaming;
  final MarkdownStyleSheet styleSheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.28),
        border: Border.all(color: foreground.withValues(alpha: 0.18)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          iconColor: foreground,
          collapsedIconColor: foreground,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          collapsedShape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          title: Row(
            children: [
              Icon(Icons.lightbulb_outline, size: 18, color: foreground),
              const SizedBox(width: 8),
              Text(
                'Raciocinio',
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (isStreaming) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: foreground,
                  ),
                ),
              ],
            ],
          ),
          children: [
            MarkdownBody(data: text, selectable: true, styleSheet: styleSheet),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.textController,
    required this.attachments,
    required this.onPick,
    required this.onRemove,
    required this.onSend,
  });

  final TextEditingController textController;
  final List<ChatAttachment> attachments;
  final VoidCallback onPick;
  final ValueChanged<ChatAttachment> onRemove;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (attachments.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: attachments
                      .map(
                        (a) => InputChip(
                          avatar: Icon(_iconFor(a), size: 18),
                          label: Text(a.name, overflow: TextOverflow.ellipsis),
                          onDeleted: () => onRemove(a),
                        ),
                      )
                      .toList(),
                ),
              ),
            if (attachments.isNotEmpty) const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton.filledTonal(
                  tooltip: 'Anexar arquivos',
                  onPressed: onPick,
                  icon: const Icon(Icons.attach_file),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: textController,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      hintText: 'Envie uma mensagem para o Gemini',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onSend,
                  style: FilledButton.styleFrom(
                    fixedSize: const Size(52, 52),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment});
  final ChatAttachment attachment;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(_iconFor(attachment), size: 18),
      label: Text(
        '${attachment.name} (${(attachment.size / 1024).toStringAsFixed(1)} KB)',
      ),
    );
  }
}

IconData _iconFor(ChatAttachment attachment) => switch (attachment.kind) {
  AttachmentKind.image => Icons.image_outlined,
  AttachmentKind.text => Icons.notes_outlined,
  AttachmentKind.document => Icons.description_outlined,
};

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('Gemini esta digitando...'),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined, size: 58, color: colors.primary),
              const SizedBox(height: 16),
              Text(
                'Comece uma conversa',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Envie texto, imagens ou documentos. O historico fica salvo localmente e pode ser lido offline.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ApiConfigDialog extends StatefulWidget {
  const ApiConfigDialog({super.key});

  @override
  State<ApiConfigDialog> createState() => _ApiConfigDialogState();
}

class _ApiConfigDialogState extends State<ApiConfigDialog> {
  late final _key = TextEditingController(
    text: context.read<ChatController>().apiKey,
  );
  late final _model = TextEditingController(
    text: context.read<ChatController>().model,
  );

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('API Gemini'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _key,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Chave da API',
                helperText:
                    'Salva apenas no dispositivo/IndexedDB deste navegador.',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              decoration: const InputDecoration(
                labelText: 'Modelo',
                helperText: 'Padrao: gemini-2.5-flash',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () async {
            await context.read<ChatController>().setApiConfig(
              _key.text,
              _model.text,
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: ColoredBox(
        color: colors.primary.withValues(alpha: 0.12),
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.primary, width: 2),
            ),
            child: const Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.file_upload_outlined, size: 48),
                  SizedBox(height: 12),
                  Text(
                    'Solte arquivos para anexar',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DroppedFilesDialog extends StatelessWidget {
  const _DroppedFilesDialog({required this.attachments});
  final List<ChatAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final prompt = TextEditingController(text: 'Analise os arquivos anexados.');
    return AlertDialog(
      title: const Text('Enviar arquivos?'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: attachments
                  .map((a) => _AttachmentChip(attachment: a))
                  .toList(),
            ),
            const SizedBox(height: 14),
            TextField(controller: prompt, minLines: 1, maxLines: 4),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () async {
            final controller = context.read<ChatController>();
            Navigator.pop(context);
            await controller.send(prompt.text, attachments);
          },
          child: const Text('Enviar'),
        ),
      ],
    );
  }
}
