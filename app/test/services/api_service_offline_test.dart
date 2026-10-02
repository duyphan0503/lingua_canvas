import 'package:app/services/api_service.dart';
import 'package:app/services/fsrs_engine.dart';
import 'package:app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late LocalDatabase database;
  setUp(() async {
    database = LocalDatabase.instance;
    await database.initCustom(customPath: inMemoryDatabasePath);
  });
  tearDown(() async => database.close());

  test('review is durable locally before any network sync', () async {
    final service = ApiService(localDb: database);
    await service.submitReview(itemId: 'ja_kata_bug', rating: FSRSRating.good);

    expect((await database.getCard('ja_kata_bug'))?.reps, 1);
    expect((await database.getPendingMutations()).single.payload['rating'], 3);
    expect(await service.getCompletedCount(), 1);
  });

  test('lessons fetched offline are cached for the next launch', () async {
    final service = ApiService(localDb: database);
    final lessons = await service.getLessons();
    expect(lessons, isNotEmpty);
    expect((await database.getLessons()).length, lessons.length);
  });
}
