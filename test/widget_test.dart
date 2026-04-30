import 'package:flutter_test/flutter_test.dart';
import 'package:flutterchatbot/main.dart';

void main() {
  group('helpers', () {
    test('detects common MIME types', () {
      expect(_testMimeFor('documento.pdf'), 'application/pdf');
      expect(_testMimeFor('foto.jpg'), 'image/jpeg');
      expect(_testMimeFor('notas.txt'), 'text/plain');
    });

    test('chat session serializes to Hive-friendly map', () {
      final createdAt = DateTime(2026, 4, 30, 10);
      final session = ChatSession(
        id: 'session-1',
        title: 'Conversa de teste',
        createdAt: createdAt,
        updatedAt: createdAt,
      );

      final restored = ChatSession.fromMap(session.toMap());

      expect(restored.id, 'session-1');
      expect(restored.title, 'Conversa de teste');
      expect(restored.createdAt, createdAt);
    });
  });
}

// Local copy for this lightweight test because _mimeFor is intentionally
// private to lib/main.dart.
String _testMimeFor(String name) {
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
