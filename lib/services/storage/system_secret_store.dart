import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_store.dart';

/// 基于系统 Keychain / Keystore / Credential Store 的统一敏感数据存储。
///
/// macOS 使用稳定自签身份和独立 Keychain service。旧 adhoc 构建写入的
/// 默认 service 不会被访问，避免触发旧 ACL 授权框；过渡期写入
/// SharedPreferences 的明文值会在首次读取时验证迁入 Keychain 后删除。
///
/// 默认严格失败，不写入明文 SharedPreferences。确实允许可用性降级的数据
/// 可在 [SecretKey] 上声明 [SecretFallbackPolicy.memoryOnly]，降级内容只在
/// 当前进程存活。
class SystemSecretStore implements SecretStore {
  SystemSecretStore({
    FlutterSecureStorage? secureStorage,
    SharedPreferences? localPreferences,
    bool? migrateLocalPreferences,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(
               accountName: _macOsKeychainService,
               usesDataProtectionKeychain: false,
             ),
           ),
       _localPreferences = localPreferences,
       _migrateLocalPreferences =
           migrateLocalPreferences ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);

  static final SystemSecretStore instance = SystemSecretStore();
  static const _macOsKeychainService = 'com.surewill.fluxdo.secrets.v1';
  static const _localStoragePrefix = '__local_secret__';

  final FlutterSecureStorage _secureStorage;
  final SharedPreferences? _localPreferences;
  final bool _migrateLocalPreferences;
  final Map<String, String> _memoryFallback = {};

  @override
  Future<String?> read(SecretKey key) async {
    try {
      final value = await _secureStorage.read(key: key.storageKey);
      if (value != null) {
        _memoryFallback.remove(key.storageKey);
        await _removeLocalValue(key.storageKey);
        return value;
      }
      final localValue = await _migrateLocalValue(key);
      if (localValue != null) return localValue;
      final migrated = await _migrateLegacyValue(key);
      return migrated ?? _memoryFallback[key.storageKey];
    } catch (error) {
      return _handleReadFailure(key, error);
    }
  }

  @override
  Future<void> write(SecretKey key, String value) async {
    try {
      await _secureStorage.write(key: key.storageKey, value: value);
      await _removeLocalValue(key.storageKey);
      _memoryFallback.remove(key.storageKey);
    } catch (error) {
      if (key.fallbackPolicy == SecretFallbackPolicy.memoryOnly) {
        _logMemoryFallback('write', key, error);
        _memoryFallback[key.storageKey] = value;
        return;
      }
      throw _exception('write', key, error);
    }
  }

  @override
  Future<void> delete(SecretKey key) async {
    _memoryFallback.remove(key.storageKey);
    try {
      await _removeLocalValue(key.storageKey);
      for (final legacyKey in key.legacyKeys) {
        await _removeLocalValue(legacyKey);
      }
      await _secureStorage.delete(key: key.storageKey);
      for (final legacyKey in key.legacyKeys) {
        await _secureStorage.delete(key: legacyKey);
      }
    } catch (error) {
      // 删除不能沿用 memoryOnly 的“可用性优先”语义。系统安全存储若未删掉，
      // 必须把失败传给注销/清理调用方，否则旧凭据会在后续 read 时重新出现。
      throw _exception('delete', key, error);
    }
  }

  @override
  Future<void> deleteScope(SecretScope scope) async {
    _memoryFallback.removeWhere(
      (key, _) => key.startsWith(scope.storagePrefix),
    );
    try {
      await _removeLocalScope(scope.storagePrefix);
      final values = await _secureStorage.readAll();
      for (final key in values.keys.toList(growable: false)) {
        if (key.startsWith(scope.storagePrefix)) {
          await _secureStorage.delete(key: key);
        }
      }
    } catch (error) {
      throw SecretStoreException(
        operation: 'deleteScope',
        key: scope.storagePrefix,
        cause: error,
      );
    }
  }

  @override
  Future<SecretStoreAvailability> checkAvailability() async {
    try {
      await _secureStorage.read(key: 'fluxdo:system:device:availability_probe');
      return SecretStoreAvailability.available;
    } catch (_) {
      return SecretStoreAvailability.unavailable;
    }
  }

  Future<SharedPreferences> get _preferences async =>
      _localPreferences ?? SharedPreferences.getInstance();

  String _localStorageKey(String key) => '$_localStoragePrefix$key';

  Future<String?> _migrateLocalValue(SecretKey key) async {
    if (!_migrateLocalPreferences) return null;
    final preferences = await _preferences;
    final localKey = _localStorageKey(key.storageKey);
    final value = preferences.getString(localKey);
    if (value == null) return null;

    await _secureStorage.write(key: key.storageKey, value: value);
    final verified = await _secureStorage.read(key: key.storageKey);
    if (verified != value) {
      throw StateError('Keychain migration verification failed');
    }
    await _removePreferenceValueVerified(preferences, localKey);
    return verified;
  }

  Future<void> _removeLocalValue(String storageKey) async {
    if (!_migrateLocalPreferences) return;
    final preferences = await _preferences;
    await _removePreferenceValueVerified(
      preferences,
      _localStorageKey(storageKey),
    );
  }

  Future<void> _removeLocalScope(String storagePrefix) async {
    if (!_migrateLocalPreferences) return;
    final preferences = await _preferences;
    final prefix = _localStorageKey(storagePrefix);
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith(prefix))
        .toList(growable: false);
    for (final key in keys) {
      await _removePreferenceValueVerified(preferences, key);
    }
  }

  Future<void> _removePreferenceValueVerified(
    SharedPreferences preferences,
    String key,
  ) async {
    await preferences.remove(key);
    if (preferences.containsKey(key)) {
      throw StateError('SharedPreferences secret cleanup failed: $key');
    }
  }

  Future<String?> _migrateLegacyValue(SecretKey key) async {
    for (final legacyKey in key.legacyKeys) {
      final value = await _secureStorage.read(key: legacyKey);
      if (value == null) continue;
      try {
        await _secureStorage.write(key: key.storageKey, value: value);
        await _secureStorage.delete(key: legacyKey);
      } catch (error) {
        if (key.fallbackPolicy != SecretFallbackPolicy.memoryOnly) rethrow;
        // 迁移写入失败时继续使用旧值，且不删除旧 Key，避免升级丢数据。
        _logMemoryFallback('migrate', key, error);
      }
      return value;
    }
    return null;
  }

  String? _handleReadFailure(SecretKey key, Object error) {
    if (key.fallbackPolicy == SecretFallbackPolicy.memoryOnly) {
      _logMemoryFallback('read', key, error);
      return _memoryFallback[key.storageKey];
    }
    throw _exception('read', key, error);
  }

  SecretStoreException _exception(
    String operation,
    SecretKey key,
    Object error,
  ) => SecretStoreException(
    operation: operation,
    key: key.storageKey,
    cause: error,
  );

  void _logMemoryFallback(String operation, SecretKey key, Object error) {
    debugPrint(
      '[SystemSecretStore] $operation(${key.storageKey}) failed; '
      'using memory-only fallback: $error',
    );
  }
}
