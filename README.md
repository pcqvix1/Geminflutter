# Flutterchatbot

Aplicativo Flutter multiplataforma para conversar diretamente com a API Gemini, sem backend e sem login.

## Plataformas

- Android
- Windows Desktop
- Flutter Web

## Configuracao da API Gemini

Opção recomendada para desenvolvimento:

```bash
flutter run -d chrome --dart-define=GEMINI_API_KEY=SUA_CHAVE
flutter run -d windows --dart-define=GEMINI_API_KEY=SUA_CHAVE
```

Modelo padrao: `gemini-2.5-flash`.

Para escolher outro modelo:

```bash
flutter run -d chrome --dart-define=GEMINI_API_KEY=SUA_CHAVE --dart-define=GEMINI_MODEL=gemini-2.5-flash
```

Tambem e possivel configurar a chave e o modelo dentro do app pelo botao de ajustes. Esses dados ficam apenas no armazenamento local do dispositivo/navegador.

## Rodar

Web:

```bash
flutter run -d chrome
```

Windows:

```bash
flutter run -d windows
```

Android:

```bash
flutter run -d android
```

## Recursos implementados

- Chat com streaming via endpoint REST `streamGenerateContent`.
- Suporte a texto, imagens e documentos anexados.
- PDF e imagens sao enviados como `inline_data`; TXT e enviado como texto; DOC/DOCX sao anexados com MIME apropriado e tratados pelo Gemini quando o modelo/API aceitar.
- Historico local com Hive: filesystem no desktop/mobile e IndexedDB no Web.
- Multiplas conversas, busca no historico e leitura offline do historico.
- Cache local simples para respostas do mesmo prompt/anexos.
- Layout responsivo: chat tradicional no mobile e sidebar + chat em desktop/web.
- Tema claro/escuro automatico.
- Upload por seletor de arquivos e drag & drop em Web/Desktop.
- Exportacao da conversa ativa em TXT ou PDF.
- Tratamento de chave ausente, timeout, limite de requisicoes e falhas de rede.

## Arquitetura

Para atender ao limite de ate 4 arquivos, a arquitetura esta concentrada em `lib/main.dart`, separada por classes:

- Models: `ChatSession`, `ChatMessage`, `ChatAttachment`.
- Persistencia: `LocalStore`.
- Servico Gemini: `GeminiService`.
- Estado/MVVM: `ChatController`.
- UI: widgets de shell, sidebar, chat, composer, dialogs e mensagens.

Referencias oficiais usadas: [Gemini API](https://ai.google.dev/gemini-api/docs) e [Gemini API reference](https://ai.google.dev/docs/gemini_api_overview/).
