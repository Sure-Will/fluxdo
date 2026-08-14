import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/storage/secret_store.dart';
import 'package:fluxdo/services/storage/system_secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('系统安全存储支持读写和删除', () async {
    final store = SystemSecretStore(migrateLocalPreferences: false);
    const key = SecretKey(namespace: 'test', name: 'secret');

    await store.write(key, 'value');
    expect(await store.read(key), 'value');

    await store.delete(key);
    expect(await store.read(key), isNull);
  });

  test('读取时自动迁移旧 SecureStorage Key', () async {
    FlutterSecureStorage.setMockInitialValues({'legacy_key': 'legacy-value'});
    final store = SystemSecretStore(migrateLocalPreferences: false);
    const key = SecretKey(
      namespace: 'test',
      name: 'secret',
      legacyKeys: ['legacy_key'],
    );

    expect(await store.read(key), 'legacy-value');

    const storage = FlutterSecureStorage();
    expect(await storage.read(key: key.storageKey), 'legacy-value');
    expect(await storage.read(key: 'legacy_key'), isNull);
  });

  test('作用域清理不会影响其它账号', () async {
    final store = SystemSecretStore(migrateLocalPreferences: false);
    const alice = SecretKey(
      namespace: 'auth',
      name: 'token',
      accountId: 'alice',
    );
    const bob = SecretKey(namespace: 'auth', name: 'token', accountId: 'bob');
    await store.write(alice, 'a');
    await store.write(bob, 'b');

    await store.deleteScope(
      const SecretScope(namespace: 'auth', accountId: 'alice'),
    );

    expect(await store.read(alice), isNull);
    expect(await store.read(bob), 'b');
  });

  test('macOS 明文值验证迁入新 Keychain 后删除', () async {
    final preferences = await SharedPreferences.getInstance();
    const key = SecretKey(namespace: 'test', name: 'secret');
    await preferences.setString(
      '__local_secret__${key.storageKey}',
      'local-value',
    );
    final store = SystemSecretStore(
      localPreferences: preferences,
      migrateLocalPreferences: true,
    );

    expect(await store.read(key), 'local-value');
    expect(
      preferences.containsKey('__local_secret__${key.storageKey}'),
      isFalse,
    );

    final recreated = SystemSecretStore(
      localPreferences: preferences,
      migrateLocalPreferences: true,
    );
    expect(await recreated.read(key), 'local-value');
  });

  test('memoryOnly 凭据删除失败也必须向调用方报错', () async {
    final store = SystemSecretStore(
      secureStorage: const _DeleteFailingSecureStorage(),
      migrateLocalPreferences: false,
    );
    const key = SecretKey.raw('legacy-token');

    await expectLater(store.delete(key), throwsA(isA<SecretStoreException>()));
  });
}

class _DeleteFailingSecureStorage extends FlutterSecureStorage {
  const _DeleteFailingSecureStorage();

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('simulated Keychain delete failure');
  }
}
