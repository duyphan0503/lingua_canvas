import 'package:app/services/storage/credential_vault.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final testCredentialVault = InMemoryCredentialVault();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await LocalDatabase.instance.initCustom(
      credentialVault: testCredentialVault,
      customPath: inMemoryDatabasePath,
    );
    await LocalDatabase.instance.clearAll();
  });
  tearDown(() => LocalDatabase.instance.close());

  test(
    'retention reflects elapsed time and empty history has no fake score',
    () async {
      final api = ApiService(localDb: LocalDatabase.instance);
      expect((await api.getFSRSStats())['estimated_retention'], 0);
      final now = DateTime.now().toUtc();
      await LocalDatabase.instance.saveCard(
        FSRSCard(
          itemId: 'old-card',
          state: FSRSState.review,
          stability: 1,
          difficulty: 5,
          reps: 1,
          lapses: 0,
          lastReview: now.subtract(const Duration(days: 100)),
          nextReview: now.subtract(const Duration(days: 99)),
        ),
      );
      final stats = await api.getFSRSStats();
      expect(stats['estimated_retention'], 22);
      expect(stats['due_today'], 1);
    },
  );
}
