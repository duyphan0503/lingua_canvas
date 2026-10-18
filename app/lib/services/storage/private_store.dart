import '../../models/lesson_item.dart';
import '../../models/profile_backup.dart';
import 'profile_backup_engine.dart';
import '../../models/private_lesson_state.dart';
import 'private_profile.dart';

mixin PrivateStore {
  Future<T> editPrivateProfile<T>(T Function(Map<String, dynamic>) change);
  Future<Map<String, dynamic>> readPrivateProfile();
  Future<Map<String, dynamic>> readGuestProfile();
  Future<ProfileBackup> exportProfileBackup() async =>
      ProfileBackupEngine.export(await readPrivateProfile());
  Future<ProfileBackup> exportGuestBackup({Set<String>? lessonIds}) async =>
      ProfileBackupEngine.export(
        await readGuestProfile(),
        lessonIds: lessonIds,
      );
  Future<ProfileMergePreview> previewProfileBackup(ProfileBackup backup) async {
    final p = await readPrivateProfile();
    return ProfileBackupEngine.preview(p, backup, p['_binding'] as String);
  }

  Future<void> mergeProfileBackup(ProfileMergePreview preview) async {
    if (ProfileBackupEngine.fingerprint(preview.backup.toJson()) !=
        preview.backupRevision) {
      throw const StaleProfileMergeException();
    }
    final current = await readPrivateProfile();
    if (current['_binding'] != preview.binding) {
      throw const StaleProfileMergeException();
    }
    await editPrivateProfile((p) {
      if (ProfileBackupEngine.fingerprint(preview.backup.toJson()) !=
              preview.backupRevision ||
          p['_binding'] != preview.binding ||
          ProfileBackupEngine.revision(p) != preview.contentRevision) {
        throw const StaleProfileMergeException();
      }
      ProfileBackupEngine.merge(p, preview.backup);
    });
  }

  Future<List<PrivateLessonState>> getPrivateLessons({
    bool includeDeleted = false,
  }) async {
    final p = await readPrivateProfile();
    return PrivateProfile.table(p, 'private_lessons').values
        .map((v) => PrivateLessonState.fromJson(v as Map<String, dynamic>))
        .where((s) => includeDeleted || !s.deleted)
        .toList();
  }

  Future<PrivateLessonState?> getPrivateLesson(String id) async {
    final raw = PrivateProfile.table(
      await readPrivateProfile(),
      'private_lessons',
    )[id];
    return raw == null
        ? null
        : PrivateLessonState.fromJson(raw as Map<String, dynamic>);
  }

  Future<PrivateLessonState> savePrivateLesson(LessonItem lesson) =>
      editPrivateProfile((p) => PrivateProfile.save(p, lesson));
  Future<void> deletePrivateLesson(String id) => _setDeleted(id, true);
  Future<void> restorePrivateLesson(String id) => _setDeleted(id, false);
  Future<void> _setDeleted(String id, bool deleted) => editPrivateProfile((p) {
    final raw = PrivateProfile.table(p, 'private_lessons')[id];
    if (raw == null) throw StateError('Không tìm thấy từ cá nhân.');
    PrivateProfile.save(
      p,
      PrivateLessonState.fromJson(raw as Map<String, dynamic>).lesson,
      deleted: deleted,
    );
  });
  Future<void> resolvePrivateLessonConflict(
    String id, {
    required bool keepLocal,
  }) => editPrivateProfile((p) => PrivateProfile.resolve(p, id, keepLocal));
  Future<void> applyPrivateLessonSync({
    List<PrivateLessonAck> acks = const [],
    List<PrivateLessonSyncConflict> conflicts = const [],
    List<PrivateLessonWireState> deltas = const [],
    List<String> progressImportAcks = const [],
  }) => editPrivateProfile(
    (p) => PrivateProfile.sync(
      p,
      acks: acks,
      conflicts: conflicts,
      deltas: deltas,
      progressImportAcks: progressImportAcks,
    ),
  );
}
