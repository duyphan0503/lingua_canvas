import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/web_capability_card.dart';
import 'package:app/screens/settings_screen.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/storage/browser_local_store.dart';
import 'package:app/services/speech_practice_service.dart';
import 'package:app/services/tts_service.dart';
import '../helpers/memory_snapshot_persistence.dart';

class WebSettingsApi extends ApiService {
  WebSettingsApi(BrowserLocalStore store)
    : super(localDb: store, baseUrl: 'http://test/api/v1');
  @override
  Future<bool> checkBackendHealth() async => true;
}

void main() {
  testWidgets(
    'capabilities identify durable storage and honest speech/ink fallback',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WebCapabilityCard(
              speechService: SpeechPracticeService(
                engine: MockSpeechPracticeEngine(available: false),
              ),
              ttsService: TtsService(engine: MockTTSEngine(isAvailable: false)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('IndexedDB'), findsWidgets);
      expect(find.textContaining('hình học'), findsWidgets);
      expect(find.textContaining('Nhập phiên âm'), findsWidgets);
      expect(find.textContaining('Chưa có giọng'), findsWidgets);
    },
  );
  testWidgets(
    'web reset clears current progress and preserves another account',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = BrowserLocalStore(
        persistence: MemorySnapshotPersistence(),
        initialBackend: 'http://test/api/v1',
      );
      await store.initialize();
      final api = WebSettingsApi(store);
      final alice = {
        'user_id': 'usr_a',
        'username': 'alice',
        'sync_token': 'lct_a',
        'server_url': 'http://test/api/v1',
        'devices': [],
      };
      final bob = {
        ...alice,
        'user_id': 'usr_b',
        'username': 'bob',
        'sync_token': 'lct_b',
      };
      await api.syncCoordinator.changeAccount(bob);
      await api.submitReview(itemId: 'bob', rating: FSRSRating.good);
      await api.syncCoordinator.changeAccount(alice);
      await api.submitReview(itemId: 'alice', rating: FSRSRating.good);
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(apiService: api, isWeb: true)),
      );
      await tester.pumpAndSettle();
      final reset = find.text('Đặt lại hồ sơ hiện tại');
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác nhận Xóa'));
      await tester.pumpAndSettle();
      expect(await store.getAllCards(), isEmpty);
      expect((await store.getAccount())!['user_id'], 'usr_a');
      await api.syncCoordinator.changeAccount(bob);
      expect((await store.getAllCards()).single.itemId, 'bob');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
