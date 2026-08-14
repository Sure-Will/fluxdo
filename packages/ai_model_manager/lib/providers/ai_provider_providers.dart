import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/ai_provider.dart';
import '../services/ai_chat_storage_service.dart';
import '../services/ai_provider_service.dart';
import '../utils/model_capabilities.dart';

/// 需要主应用在 ProviderScope.overrides 中注入
final aiSharedPreferencesProvider = Provider<SharedPreferences>((_) {
  throw UnimplementedError(
      'aiSharedPreferencesProvider 必须在 ProviderScope.overrides 中注入');
});

/// 可选的 HttpClientAdapter 工厂，由主应用在 ProviderScope.overrides 中注入
/// 用于让 AI 请求复用应用的网络配置（代理等）
final aiDioAdapterFactoryProvider =
    Provider<HttpClientAdapter Function()?>((_) => null);

/// 是否跟随应用网络配置
final aiUseAppNetworkProvider = StateProvider<bool>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getBool('ai_use_app_network') ?? false;
});

/// 是否启用图像生成的渐进式预览（partial frames）。
/// 仅 OpenAI 已验证 organization 的账号支持；未验证账号开启会导致
/// 服务端返回 200 但不发任何事件、最终报「未收到 AI 回复」。
/// 默认关闭，用户在 settings 主动启用。
final aiPartialImagesProvider = StateProvider<bool>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getBool('ai_partial_images') ?? false;
});

/// AI 聊天存储服务
final aiChatStorageServiceProvider = Provider<AiChatStorageService>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return AiChatStorageService(prefs);
});

/// 思考配置
final aiThinkingConfigProvider = StateProvider<ThinkingConfig>((ref) {
  final storage = ref.watch(aiChatStorageServiceProvider);
  return storage.getThinkingConfig();
});

/// 供应商列表状态管理
final aiProviderListProvider =
    StateNotifierProvider<AiProviderListNotifier, List<AiProvider>>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return AiProviderListNotifier(prefs);
});

/// API 服务
final aiProviderApiServiceProvider = Provider((ref) {
  final useAppNetwork = ref.watch(aiUseAppNetworkProvider);
  final adapterFactory = ref.watch(aiDioAdapterFactoryProvider);
  return AiProviderApiService(
    adapterFactory: useAppNetwork ? adapterFactory : null,
  );
});

// 默认模型按模式分别记忆。旧 'ai_default_model' key 保留作为 fallback：
// 新增分模式 key 后，未配置对应 mode 默认时仍会用旧 key 读出来兜底。
const String _kDefaultModelKey = 'ai_default_model';
const String _kDefaultTextModelKey = 'ai_default_text_model';
const String _kDefaultImageModelKey = 'ai_default_image_model';

/// 通用默认模型 key（向后兼容；新代码优先用分模式 provider）
final defaultAiModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_kDefaultModelKey);
});

/// 文本默认模型 key
final defaultTextAiModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_kDefaultTextModelKey);
});

/// 图像默认模型 key
final defaultImageAiModelKeyProvider = StateProvider<String?>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return prefs.getString(_kDefaultImageModelKey);
});

/// 设置默认模型
///
/// [isImageMode]：true 写入图像默认 key，false 写入文本默认 key，
/// null 仅写入通用 key（向后兼容旧调用）。
///
/// 旧通用 key 只跟随文本默认模型。图像默认模型不能写入通用 key，
/// 否则 AI 助手首次打开会被误判为生图模式。
Future<void> setDefaultAiModel(
  WidgetRef ref,
  String providerId,
  String modelId, {
  bool? isImageMode,
}) async {
  final prefs = ref.read(aiSharedPreferencesProvider);
  final key = '$providerId:$modelId';
  if (isImageMode == true) {
    await prefs.setString(_kDefaultImageModelKey, key);
    ref.read(defaultImageAiModelKeyProvider.notifier).state = key;
    if (prefs.getString(_kDefaultModelKey) == key) {
      await prefs.remove(_kDefaultModelKey);
      ref.read(defaultAiModelKeyProvider.notifier).state = null;
    }
  } else if (isImageMode == false) {
    await prefs.setString(_kDefaultModelKey, key);
    ref.read(defaultAiModelKeyProvider.notifier).state = key;
    await prefs.setString(_kDefaultTextModelKey, key);
    ref.read(defaultTextAiModelKeyProvider.notifier).state = key;
  } else {
    await prefs.setString(_kDefaultModelKey, key);
    ref.read(defaultAiModelKeyProvider.notifier).state = key;
  }
}

/// 清除默认模型
///
/// [isImageMode]：true 清图像默认；false 清文本默认；null 清通用 + 同时
/// 清空两个分模式 key（一键回到无默认状态）。
Future<void> clearDefaultAiModel(
  WidgetRef ref, {
  bool? isImageMode,
}) async {
  final prefs = ref.read(aiSharedPreferencesProvider);
  if (isImageMode == true) {
    final imageKey = prefs.getString(_kDefaultImageModelKey);
    await prefs.remove(_kDefaultImageModelKey);
    ref.read(defaultImageAiModelKeyProvider.notifier).state = null;
    if (imageKey != null && prefs.getString(_kDefaultModelKey) == imageKey) {
      await prefs.remove(_kDefaultModelKey);
      ref.read(defaultAiModelKeyProvider.notifier).state = null;
    }
    return;
  }
  if (isImageMode == false) {
    final textKey = prefs.getString(_kDefaultTextModelKey);
    await prefs.remove(_kDefaultTextModelKey);
    ref.read(defaultTextAiModelKeyProvider.notifier).state = null;
    if (textKey != null && prefs.getString(_kDefaultModelKey) == textKey) {
      await prefs.remove(_kDefaultModelKey);
      ref.read(defaultAiModelKeyProvider.notifier).state = null;
    }
    return;
  }
  await prefs.remove(_kDefaultModelKey);
  await prefs.remove(_kDefaultTextModelKey);
  await prefs.remove(_kDefaultImageModelKey);
  ref.read(defaultAiModelKeyProvider.notifier).state = null;
  ref.read(defaultTextAiModelKeyProvider.notifier).state = null;
  ref.read(defaultImageAiModelKeyProvider.notifier).state = null;
}

/// 供应商列表 Notifier
class AiProviderListNotifier extends StateNotifier<List<AiProvider>> {
  static const String _storageKey = 'ai_providers';
  static const String _kApiKeyPrefix = 'ai_apikey_';
  static const String _kStagedApiKeyPrefix = 'ai_apikey_staged_';
  static const String _kLegacyKeychainPrefix = 'ai_provider_key_';
  static const String _kLegacyFallbackPrefix =
      '__secure_fallback__ai_provider_key_';
  static const String _kPendingSecretTransactions =
      'ai_provider_secret_transactions_v1';
  static const String _kMacOsKeychainService =
      'com.surewill.fluxdo.ai-secrets.v1';
  static const _uuid = Uuid();
  static final Set<String> _blockedProviderIds = <String>{};

  static const FlutterSecureStorage _apiKeyStorage = FlutterSecureStorage(
    mOptions: MacOsOptions(
      accountName: _kMacOsKeychainService,
      usesDataProtectionKeychain: false,
    ),
  );

  /// 老 Keychain 数据只在非 macOS 平台迁移。macOS 的旧 adhoc ACL 会弹
  /// 授权框，因此稳定签名版使用全新 service，完全不查询旧 service。
  static const FlutterSecureStorage _legacyKeychain = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static bool get _canAccessLegacyKeychain =>
      kIsWeb || defaultTargetPlatform != TargetPlatform.macOS;

  final SharedPreferences _prefs;
  Future<void> _journalTail = Future<void>.value();
  Future<void> _mutationTail = Future<void>.value();
  late final Future<void> _secretRecovery;

  AiProviderListNotifier(this._prefs) : super([]) {
    _blockedProviderIds.addAll(_readSecretJournal().keys);
    _load();
    _secretRecovery = _recoverPendingSecretTransactions();
    unawaited(_secretRecovery);
  }

  void _load() {
    final raw = _prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      state = list
          .map((e) => AiProvider.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // 数据损坏时忽略
    }
  }

  Future<void> _save() async {
    final json = state.map((p) => p.toJson()).toList();
    final encoded = jsonEncode(json);
    final saved = await _prefs.setString(_storageKey, encoded);
    if (!saved || _prefs.getString(_storageKey) != encoded) {
      throw StateError('AI provider metadata persistence failed');
    }
  }

  /// 添加供应商，返回新供应商 id
  Future<String> addProvider({
    required String name,
    required AiProviderType type,
    required String baseUrl,
    required String apiKey,
    List<AiModel> models = const [],
  }) =>
      _withMutationLock(() async {
        await _secretRecovery;
        final id = _uuid.v4();
        final provider = AiProvider(
          id: id,
          name: name,
          type: type,
          baseUrl: baseUrl,
          models: _inferAll(models),
          pinned: false,
        );
        await _beginSecretTransaction(id, expectedProvider: provider);
        try {
          await _stageApiKey(id, apiKey);
        } catch (error, stackTrace) {
          await _discardStagedApiKey(id);
          await _finishSecretTransaction(id);
          Error.throwWithStackTrace(error, stackTrace);
        }
        final previousState = state;
        state = [...state, provider];
        try {
          await _save();
        } catch (_) {
          state = previousState;
          await _discardStagedApiKey(id);
          await _finishSecretTransaction(id);
          rethrow;
        }
        await _commitStagedApiKey(id, deleteSecret: apiKey.trim().isEmpty);
        await _finishSecretTransaction(id);
        return id;
      });

  /// 更新供应商
  Future<void> updateProvider({
    required String id,
    String? name,
    AiProviderType? type,
    String? baseUrl,
    String? apiKey,
    List<AiModel>? models,
  }) =>
      _withMutationLock(() async {
        await _secretRecovery;
        _ensureProviderSecretReady(id);
        if (!state.any((provider) => provider.id == id)) return;
        final previousState = state;
        final nextState = state.map((p) {
          if (p.id != id) return p;
          return p.copyWith(
            name: name,
            type: type,
            baseUrl: baseUrl,
            models: models,
          );
        }).toList();
        final expectedProvider =
            nextState.firstWhere((provider) => provider.id == id);
        if (apiKey != null) {
          await _beginSecretTransaction(
            id,
            expectedProvider: expectedProvider,
            deleteSecret: apiKey.trim().isEmpty,
          );
          try {
            await _stageApiKey(id, apiKey);
          } catch (error, stackTrace) {
            await _discardStagedApiKey(id);
            await _finishSecretTransaction(id);
            Error.throwWithStackTrace(error, stackTrace);
          }
        }
        state = nextState;
        try {
          await _save();
        } catch (_) {
          state = previousState;
          if (apiKey != null) {
            await _discardStagedApiKey(id);
            await _finishSecretTransaction(id);
          }
          rethrow;
        }
        if (apiKey != null) {
          await _commitStagedApiKey(id, deleteSecret: apiKey.trim().isEmpty);
          await _finishSecretTransaction(id);
        }
      });

  /// 删除供应商
  Future<void> removeProvider(String id) => _withMutationLock(() async {
        await _secretRecovery;
        _ensureProviderSecretReady(id);
        if (!state.any((provider) => provider.id == id)) return;
        await _beginSecretTransaction(id);
        final previousState = state;
        state = state.where((p) => p.id != id).toList();
        try {
          await _save();
        } catch (_) {
          state = previousState;
          await _finishSecretTransaction(id);
          rethrow;
        }
        await _deleteApiKey(id);
        await _finishSecretTransaction(id);
      });

  /// 批量删除供应商，并同步清理 API Key。
  Future<void> removeProviders(Iterable<String> ids) =>
      _withMutationLock(() async {
        await _secretRecovery;
        final existingIds = state.map((provider) => provider.id).toSet();
        final idSet = ids.toSet().intersection(existingIds);
        if (idSet.isEmpty) return;
        for (final id in idSet) {
          _ensureProviderSecretReady(id);
        }
        for (final id in idSet) {
          await _beginSecretTransaction(id);
        }
        final previousState = state;
        state = state.where((p) => !idSet.contains(p.id)).toList();
        try {
          await _save();
        } catch (_) {
          state = previousState;
          for (final id in idSet) {
            await _finishSecretTransaction(id);
          }
          rethrow;
        }
        final failures = <Object>[];
        for (final id in idSet) {
          try {
            await _deleteApiKey(id);
            await _finishSecretTransaction(id);
          } catch (error) {
            failures.add(error);
          }
        }
        if (failures.isNotEmpty) {
          throw StateError(
            'Failed to delete ${failures.length} AI provider secret(s); '
            'cleanup has been queued',
          );
        }
      });

  /// 更新模型列表
  Future<void> updateModels(String id, List<AiModel> models) =>
      _withMutationLock(() async {
        await _secretRecovery;
        _ensureProviderSecretReady(id);
        state = state.map((p) {
          if (p.id != id) return p;
          return p.copyWith(models: _inferAll(models));
        }).toList();
        await _save();
      });

  /// 切换置顶状态。
  ///
  /// - 未置顶 -> 插到置顶区最前
  /// - 已置顶 -> 取消置顶并移到普通区最后
  Future<void> togglePin(String id) => _withMutationLock(() async {
        await _secretRecovery;
        _ensureProviderSecretReady(id);
        final index = state.indexWhere((p) => p.id == id);
        if (index == -1) return;
        final provider = state[index];
        final next = [...state]..removeAt(index);
        if (provider.pinned) {
          next.add(provider.copyWith(pinned: false));
        } else {
          next.insert(0, provider.copyWith(pinned: true));
        }
        state = next;
        await _save();
      });

  /// 仅重排序置顶区内部顺序。
  Future<void> reorderPinned(int oldIndex, int newIndex) =>
      _withMutationLock(() async {
        await _secretRecovery;
        _ensureAllProviderSecretsReady();
        await _reorderByPinned(true, oldIndex, newIndex);
      });

  /// 仅重排普通区内部顺序。
  Future<void> reorderUnpinned(int oldIndex, int newIndex) =>
      _withMutationLock(() async {
        await _secretRecovery;
        _ensureAllProviderSecretsReady();
        await _reorderByPinned(false, oldIndex, newIndex);
      });

  Future<void> _reorderByPinned(bool pinned, int oldIndex, int newIndex) async {
    final pinnedItems =
        state.where((provider) => provider.pinned == pinned).toList();
    if (pinnedItems.isEmpty) return;
    if (oldIndex < 0 ||
        oldIndex >= pinnedItems.length ||
        newIndex < 0 ||
        newIndex >= pinnedItems.length) {
      return;
    }
    final moved = pinnedItems.removeAt(oldIndex);
    pinnedItems.insert(newIndex, moved);
    final otherItems =
        state.where((provider) => provider.pinned != pinned).toList();
    state = pinned
        ? [...pinnedItems, ...otherItems]
        : [...otherItems, ...pinnedItems];
    await _save();
  }

  /// 对一组模型批量补齐能力字段。已显式存在的能力会被保留，
  /// 仅在缺失时根据模型 ID 添加默认值。
  List<AiModel> _inferAll(List<AiModel> models) {
    return models.map(ModelCapabilities.infer).toList(growable: false);
  }

  /// 获取 API Key。
  ///
  /// 优先读独立安全存储；过渡期 SharedPreferences 明文或历史 fallback
  /// 只作为一次性迁移源，写入安全存储并读回验证后立即删除。
  static Future<String?> getApiKey(String providerId) async {
    if (_blockedProviderIds.contains(providerId)) return null;
    final storageKey = '$_kApiKeyPrefix$providerId';
    final secure = await _apiKeyStorage.read(key: storageKey);
    if (_blockedProviderIds.contains(providerId)) return null;
    if (secure != null && secure.trim().isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await _removePreferenceKey(prefs, storageKey);
      await _removePreferenceKey(
        prefs,
        '$_kLegacyFallbackPrefix$providerId',
      );
      return secure.trim();
    }
    final prefs = await SharedPreferences.getInstance();
    final migrated = await _migrateLegacyApiKey(providerId, prefs);
    return _blockedProviderIds.contains(providerId) ? null : migrated;
  }

  /// 一次性迁移：优先读取当前明文，再看可安全访问的旧 Keychain 与历史
  /// fallback。新 Keychain 读回一致后才删除迁移源。
  static Future<String?> _migrateLegacyApiKey(
    String providerId,
    SharedPreferences prefs,
  ) async {
    final storageKey = '$_kApiKeyPrefix$providerId';
    String? value = prefs.getString(storageKey)?.trim();
    if (value?.isEmpty == true) value = null;
    if (value == null && _canAccessLegacyKeychain) {
      try {
        final fromKeychain = await _legacyKeychain.read(
          key: '$_kLegacyKeychainPrefix$providerId',
        );
        if (fromKeychain != null && fromKeychain.trim().isNotEmpty) {
          value = fromKeychain.trim();
        }
      } catch (_) {
        // Keychain 读失败(自签失效 / Linux 无 keyring)→ 看 prefs fallback
      }
    }
    if (value == null) {
      final fromFallback = prefs.getString(
        '$_kLegacyFallbackPrefix$providerId',
      );
      if (fromFallback != null && fromFallback.trim().isNotEmpty) {
        value = fromFallback.trim();
      }
    }
    if (value == null) return null;

    await _apiKeyStorage.write(key: storageKey, value: value);
    final verified = await _apiKeyStorage.read(key: storageKey);
    if (verified != value) {
      throw StateError('AI API Key migration verification failed');
    }
    await _removePreferenceKey(prefs, storageKey);
    await _removePreferenceKey(prefs, '$_kLegacyFallbackPrefix$providerId');
    if (_canAccessLegacyKeychain) {
      try {
        await _legacyKeychain.delete(key: '$_kLegacyKeychainPrefix$providerId');
      } catch (_) {
        // 删失败无所谓,新位置已经存了,下次不会再走迁移分支
      }
    }
    return value;
  }

  /// 保存 API Key 到平台安全存储；不允许静默降级为明文。
  static Future<void> _saveApiKey(String providerId, String apiKey) async {
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) {
      // 拒绝写入空 key;调用方应该走 _deleteApiKey 清除而不是写空串。
      await _deleteApiKey(providerId);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final storageKey = '$_kApiKeyPrefix$providerId';
    await _apiKeyStorage.write(key: storageKey, value: trimmed);
    await _removePreferenceKey(prefs, storageKey);
    await _removePreferenceKey(prefs, '$_kLegacyFallbackPrefix$providerId');
    if (_canAccessLegacyKeychain) {
      try {
        await _legacyKeychain.delete(key: '$_kLegacyKeychainPrefix$providerId');
      } catch (_) {}
    }
  }

  static Future<void> _deleteApiKey(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    final storageKey = '$_kApiKeyPrefix$providerId';
    await _removePreferenceKey(prefs, storageKey);
    await _removePreferenceKey(prefs, '$_kLegacyFallbackPrefix$providerId');
    if (_canAccessLegacyKeychain) {
      try {
        await _legacyKeychain.delete(key: '$_kLegacyKeychainPrefix$providerId');
      } catch (_) {}
    }
    await _apiKeyStorage.delete(key: storageKey);
  }

  static Future<void> _stageApiKey(String providerId, String apiKey) async {
    final stagedKey = '$_kStagedApiKeyPrefix$providerId';
    final value = apiKey.trim();
    if (value.isEmpty) {
      await _apiKeyStorage.delete(key: stagedKey);
      return;
    }
    await _apiKeyStorage.write(key: stagedKey, value: value);
    if (await _apiKeyStorage.read(key: stagedKey) != value) {
      throw StateError('AI API Key staging verification failed');
    }
  }

  static Future<void> _discardStagedApiKey(String providerId) async {
    final stagedKey = '$_kStagedApiKeyPrefix$providerId';
    await _apiKeyStorage.delete(key: stagedKey);
    if (await _apiKeyStorage.read(key: stagedKey) != null) {
      throw StateError('AI API Key staging cleanup failed');
    }
  }

  static Future<void> _commitStagedApiKey(
    String providerId, {
    required bool deleteSecret,
  }) async {
    if (deleteSecret) {
      await _deleteApiKey(providerId);
      await _discardStagedApiKey(providerId);
      return;
    }
    final stagedKey = '$_kStagedApiKeyPrefix$providerId';
    final staged = await _apiKeyStorage.read(key: stagedKey);
    if (staged == null || staged.trim().isEmpty) {
      // 已写入正式槽后、清理临时槽前崩溃时，临时槽可能已经不存在。
      final committed = await _apiKeyStorage.read(
        key: '$_kApiKeyPrefix$providerId',
      );
      if (committed == null || committed.trim().isEmpty) {
        throw StateError('AI API Key staging value is missing');
      }
      return;
    }
    await _saveApiKey(providerId, staged);
    final committed = await _apiKeyStorage.read(
      key: '$_kApiKeyPrefix$providerId',
    );
    if (committed != staged) {
      throw StateError('AI API Key commit verification failed');
    }
    await _discardStagedApiKey(providerId);
  }

  Future<void> _beginSecretTransaction(
    String providerId, {
    AiProvider? expectedProvider,
    bool deleteSecret = false,
  }) =>
      _withJournalLock(() async {
        final journal = _readSecretJournal();
        journal[providerId] = {
          'op': expectedProvider == null ? 'remove' : 'upsert',
          if (expectedProvider != null) 'expected': expectedProvider.toJson(),
          if (expectedProvider != null) 'deleteSecret': deleteSecret,
        };
        await _persistSecretJournal(journal);
        _blockedProviderIds.add(providerId);
      });

  Future<void> _finishSecretTransaction(String providerId) =>
      _withJournalLock(() async {
        final journal = _readSecretJournal()..remove(providerId);
        await _persistSecretJournal(journal);
        _blockedProviderIds.remove(providerId);
      });

  Future<void> _recoverPendingSecretTransactions() async {
    final journal = await _withJournalLock(_readSecretJournal);
    for (final entry in journal.entries) {
      final providerId = entry.key;
      final record = entry.value;
      final current =
          state.where((provider) => provider.id == providerId).firstOrNull;
      if (record['op'] == 'upsert') {
        final expected = record['expected'];
        final committed = current != null &&
            expected is Map<String, dynamic> &&
            jsonEncode(current.toJson()) == jsonEncode(expected);
        if (committed) {
          try {
            await _commitStagedApiKey(
              providerId,
              deleteSecret: record['deleteSecret'] == true,
            );
          } catch (error) {
            debugPrint('[AiProvider] 恢复已提交的 API Key 失败 $providerId: $error');
            continue;
          }
          await _finishSecretTransaction(providerId);
          continue;
        }
        // 元数据尚未提交：正式 Key 从未被覆盖，丢弃 staging 后保留旧配置。
        try {
          await _discardStagedApiKey(providerId);
          await _finishSecretTransaction(providerId);
        } catch (error) {
          debugPrint('[AiProvider] 回滚未提交的 API Key 失败 $providerId: $error');
        }
        continue;
      } else if (current != null) {
        // remove 的元数据提交尚未发生，Key 仍属于有效 provider。
        await _finishSecretTransaction(providerId);
        continue;
      }
      try {
        await _deleteApiKey(providerId);
        await _discardStagedApiKey(providerId);
        await _finishSecretTransaction(providerId);
      } catch (error) {
        debugPrint('[AiProvider] 恢复未完成的密钥事务失败 $providerId: $error');
      }
    }
  }

  Map<String, Map<String, dynamic>> _readSecretJournal() {
    final raw = _prefs.getString(_kPendingSecretTransactions);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return decoded.map(
      (key, value) => MapEntry(
        key.toString(),
        (value as Map).cast<String, dynamic>(),
      ),
    );
  }

  Future<void> _persistSecretJournal(
    Map<String, Map<String, dynamic>> journal,
  ) async {
    if (journal.isEmpty) {
      await _prefs.remove(_kPendingSecretTransactions);
      if (_prefs.containsKey(_kPendingSecretTransactions)) {
        throw StateError('AI secret transaction journal removal failed');
      }
      return;
    }
    final encoded = jsonEncode(journal);
    final saved = await _prefs.setString(_kPendingSecretTransactions, encoded);
    if (!saved || _prefs.getString(_kPendingSecretTransactions) != encoded) {
      throw StateError('AI secret transaction journal persistence failed');
    }
  }

  Future<T> _withJournalLock<T>(FutureOr<T> Function() action) async {
    final previous = _journalTail;
    final release = Completer<void>();
    _journalTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<T> _withMutationLock<T>(FutureOr<T> Function() action) async {
    final previous = _mutationTail;
    final release = Completer<void>();
    _mutationTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  void _ensureProviderSecretReady(String providerId) {
    if (_blockedProviderIds.contains(providerId)) {
      throw StateError(
        'AI provider secret transaction is still pending: $providerId',
      );
    }
  }

  void _ensureAllProviderSecretsReady() {
    final pending = state
        .map((provider) => provider.id)
        .where(_blockedProviderIds.contains)
        .toList(growable: false);
    if (pending.isNotEmpty) {
      throw StateError(
        'AI provider secret transactions are still pending: '
        '${pending.join(', ')}',
      );
    }
  }

  static Future<void> _removePreferenceKey(
    SharedPreferences prefs,
    String key,
  ) async {
    await prefs.remove(key);
    if (prefs.containsKey(key)) {
      throw StateError('SharedPreferences API Key cleanup failed: $key');
    }
  }
}
