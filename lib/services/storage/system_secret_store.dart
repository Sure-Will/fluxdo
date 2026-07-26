import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secret_store.dart';

/// 基于系统 Keychain / Keystore / Credential Store 的统一敏感数据存储。
///
/// macOS 例外：adhoc 签名每次构建都会改变代码身份，导致系统钥匙串反复
/// 请求授权。macOS 因此改用应用自己的 SharedPreferences，不读取、迁移或
/// 删除 Keychain 中的旧凭证。该平台的凭证会持久化，但不再由钥匙串加密。
///
/// 默认严格失败，不写入明文 SharedPreferences。确实允许可用性降级的数据
/// 可在 [SecretKey] 上声明 [SecretFallbackPolicy.memoryOnly]，降级内容只在
/// 当前进程存活。
class SystemSecretStore implements SecretStore {
  SystemSecretStore({
    FlutterSecureStorage? secureStorage,
    SharedPreferences? localPreferences,
    bool? useSystemStorage,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       _localPreferences = localPreferences,
       _useSystemStorage =
           useSystemStorage ??
           (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS);

  static final SystemSecretStore instance = SystemSecretStore();
  static const _localStoragePrefix = '__local_secret__';

  final FlutterSecureStorage _secureStorage;
  final SharedPreferences? _localPreferences;
  final bool _useSystemStorage;
  final Map<String, String> _memoryFallback = {};

  @override
  Future<String?> read(SecretKey key) async {
    if (!_useSystemStorage) {
      final preferences = await _preferences;
      return preferences.getString(_localStorageKey(key.storageKey));
    }
    try {
      final value = await _secureStorage.read(key: key.storageKey);
      if (value != null) {
        _memoryFallback.remove(key.storageKey);
        return value;
      }
      final migrated = await _migrateLegacyValue(key);
      return migrated ?? _memoryFallback[key.storageKey];
    } catch (error) {
      return _handleReadFailure(key, error);
    }
  }

  @override
  Future<void> write(SecretKey key, String value) async {
    if (!_useSystemStorage) {
      final preferences = await _preferences;
      await preferences.setString(_localStorageKey(key.storageKey), value);
      return;
    }
    try {
      await _secureStorage.write(key: key.storageKey, value: value);
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
    if (!_useSystemStorage) {
      final preferences = await _preferences;
      await preferences.remove(_localStorageKey(key.storageKey));
      for (final legacyKey in key.legacyKeys) {
        await preferences.remove(_localStorageKey(legacyKey));
      }
      return;
    }
    try {
      await _secureStorage.delete(key: key.storageKey);
      for (final legacyKey in key.legacyKeys) {
        await _secureStorage.delete(key: legacyKey);
      }
    } catch (error) {
      if (key.fallbackPolicy == SecretFallbackPolicy.memoryOnly) {
        _logMemoryFallback('delete', key, error);
        return;
      }
      throw _exception('delete', key, error);
    }
  }

  @override
  Future<void> deleteScope(SecretScope scope) async {
    _memoryFallback.removeWhere(
      (key, _) => key.startsWith(scope.storagePrefix),
    );
    if (!_useSystemStorage) {
      final preferences = await _preferences;
      final prefix = _localStorageKey(scope.storagePrefix);
      final keys = preferences
          .getKeys()
          .where((key) => key.startsWith(prefix))
          .toList(growable: false);
      await Future.wait(keys.map(preferences.remove));
      return;
    }
    try {
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
    if (!_useSystemStorage) {
      await _preferences;
      return SecretStoreAvailability.available;
    }
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
