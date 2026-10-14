import 'dart:convert';
import 'dart:io';

import 'package:app/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dialogue maps canonical server fields and sends difficulty', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestDone = server.first.then((request) async {
      expect(request.uri.path, '/api/v1/ai/dialogue');
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      expect(body['difficulty_level'], 'advanced');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'lines': [
            {
              'speaker': 'A',
              'text': 'Hello',
              'translation': 'Xin chào',
              'phonetic_or_romaji': 'hello',
            },
          ],
          'vocabulary': [
            {'word': 'Hello', 'meaning_vi': 'Xin chào'},
          ],
        }),
      );
      await request.response.close();
    });
    final api = ApiService(baseUrl: 'http://127.0.0.1:${server.port}/api/v1');
    final result = await api.generateDialogue(
      targetLanguage: 'en',
      topic: 'Greeting',
      level: 'advanced',
    );
    await requestDone;
    expect(result['turns'].single['translation_vi'], 'Xin chào');
    expect(result['turns'].single['romaji_or_phonetic'], 'hello');
    expect(result['key_vocabulary'].single['word'], 'Hello');
  });

  test('roleplay sends selected profession and user level', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requestDone = server.first.then((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      expect(body['profession'], 'hospitality');
      expect(body['user_level'], 'advanced');
      request.response.write(jsonEncode({'reply': 'Welcome'}));
      await request.response.close();
    });
    final api = ApiService(baseUrl: 'http://127.0.0.1:${server.port}/api/v1');
    final response = await api.sendRoleplayMessage(
      targetLanguage: 'en',
      topic: 'Greeting',
      message: 'Hi',
      profession: 'HOSPITALITY',
      userLevel: 'ADVANCED',
    );
    await requestDone;
    expect(response['reply'], 'Welcome');
  });

  test('invalid server address preserves existing API and sync endpoint', () {
    final api = ApiService(baseUrl: 'http://127.0.0.1:8080/api/v1');
    final original = api.syncCoordinator;
    expect(() => api.setBaseUrl('not a URL'), throwsFormatException);
    expect(api.baseUrl, 'http://127.0.0.1:8080/api/v1');
    expect(api.syncCoordinator, same(original));
    api.setBaseUrl(' https://example.com/api/v1/ ');
    expect(api.baseUrl, 'https://example.com/api/v1');
    expect(api.syncCoordinator.baseUrl, api.baseUrl);
  });
}
