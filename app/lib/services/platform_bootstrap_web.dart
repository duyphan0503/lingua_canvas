import 'api_service.dart';
import 'storage/local_database_web.dart';
import 'platform_capabilities.dart';
import 'storage/local_store.dart';

Future<void> initializePlatformStorage(LocalStore store) async {
  await store.initialize();
  const configured = String.fromEnvironment('API_BASE_URL');
  final remembered = store is LocalDatabase
      ? await store.getActiveBackend()
      : '';
  final base = resolveApiBaseUrl(
    isWeb: true,
    pageUri: Uri.base,
    configured: configured.isNotEmpty ? configured : remembered,
  );
  await store.withProfileLock(() => store.selectBackend(base));
  ApiService.defaultBaseUrl = base;
}
