import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('明文 API Key 首次读取后迁入安全存储并删除原值', () async {
    const providerId = 'migrate-provider';
    const storageKey = 'ai_apikey_$providerId';
    SharedPreferences.setMockInitialValues({storageKey: 'secret-value'});

    expect(
      await AiProviderListNotifier.getApiKey(providerId),
      'secret-value',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(storageKey), isFalse);
    const secureStorage = FlutterSecureStorage();
    expect(await secureStorage.read(key: storageKey), 'secret-value');
  });

  test('新增供应商只把 API Key 写入安全存储', () async {
    final prefs = await SharedPreferences.getInstance();
    final notifier = AiProviderListNotifier(prefs);

    final providerId = await notifier.addProvider(
      name: 'Test',
      type: AiProviderType.openai,
      baseUrl: 'https://example.com',
      apiKey: 'new-secret',
    );
    final storageKey = 'ai_apikey_$providerId';

    expect(prefs.containsKey(storageKey), isFalse);
    expect(await AiProviderListNotifier.getApiKey(providerId), 'new-secret');
  });

  test('启动时恢复预写日志并清理孤立 API Key', () async {
    const providerId = 'orphan-provider';
    const storageKey = 'ai_apikey_$providerId';
    const secureStorage = FlutterSecureStorage();
    await secureStorage.write(key: storageKey, value: 'orphan-secret');
    SharedPreferences.setMockInitialValues({
      'ai_provider_secret_transactions_v1': jsonEncode({
        providerId: {'op': 'remove'},
      }),
    });
    final prefs = await SharedPreferences.getInstance();

    AiProviderListNotifier(prefs);
    for (var attempt = 0; attempt < 10; attempt++) {
      if (await secureStorage.read(key: storageKey) == null) break;
      await Future<void>.delayed(Duration.zero);
    }

    expect(await secureStorage.read(key: storageKey), isNull);
    expect(prefs.containsKey('ai_provider_secret_transactions_v1'), isFalse);
  });

  test('已提交的 upsert 日志只清日志，不删除有效 API Key', () async {
    const providerId = 'committed-provider';
    const storageKey = 'ai_apikey_$providerId';
    final provider = AiProvider(
      id: providerId,
      name: 'Committed',
      type: AiProviderType.openai,
      baseUrl: 'https://example.com',
    );
    const secureStorage = FlutterSecureStorage();
    await secureStorage.write(key: storageKey, value: 'valid-secret');
    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode([provider.toJson()]),
      'ai_provider_secret_transactions_v1': jsonEncode({
        providerId: {'op': 'upsert', 'expected': provider.toJson()},
      }),
    });
    final prefs = await SharedPreferences.getInstance();

    AiProviderListNotifier(prefs);
    for (var attempt = 0; attempt < 10; attempt++) {
      if (!prefs.containsKey('ai_provider_secret_transactions_v1')) break;
      await Future<void>.delayed(Duration.zero);
    }

    expect(await secureStorage.read(key: storageKey), 'valid-secret');
    expect(prefs.containsKey('ai_provider_secret_transactions_v1'), isFalse);
  });

  test('未提交的 update 日志丢弃 staging 并保留旧元数据和旧 Key', () async {
    const providerId = 'interrupted-update';
    const storageKey = 'ai_apikey_$providerId';
    final oldProvider = AiProvider(
      id: providerId,
      name: 'Old',
      type: AiProviderType.openai,
      baseUrl: 'https://old.example.com',
    );
    final expectedProvider = AiProvider(
      id: providerId,
      name: 'New',
      type: AiProviderType.openai,
      baseUrl: 'https://new.example.com',
    );
    const secureStorage = FlutterSecureStorage();
    await secureStorage.write(key: storageKey, value: 'old-secret');
    await secureStorage.write(
      key: 'ai_apikey_staged_$providerId',
      value: 'new-secret',
    );
    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode([oldProvider.toJson()]),
      'ai_provider_secret_transactions_v1': jsonEncode({
        providerId: {'op': 'upsert', 'expected': expectedProvider.toJson()},
      }),
    });
    final prefs = await SharedPreferences.getInstance();

    AiProviderListNotifier(prefs);
    for (var attempt = 0; attempt < 10; attempt++) {
      if (!prefs.containsKey('ai_provider_secret_transactions_v1')) break;
      await Future<void>.delayed(Duration.zero);
    }

    expect(await secureStorage.read(key: storageKey), 'old-secret');
    expect(
      await secureStorage.read(key: 'ai_apikey_staged_$providerId'),
      isNull,
    );
    final providers = jsonDecode(prefs.getString('ai_providers')!) as List;
    expect(providers, hasLength(1));
    expect((providers.single as Map)['name'], 'Old');
    expect(prefs.containsKey('ai_provider_secret_transactions_v1'), isFalse);
  });

  test('已提交元数据的 upsert 日志会把 staging Key 提升为正式 Key', () async {
    const providerId = 'committed-staging-provider';
    const storageKey = 'ai_apikey_$providerId';
    final provider = AiProvider(
      id: providerId,
      name: 'Committed',
      type: AiProviderType.openai,
      baseUrl: 'https://new.example.com',
    );
    const secureStorage = FlutterSecureStorage();
    await secureStorage.write(key: storageKey, value: 'old-secret');
    await secureStorage.write(
      key: 'ai_apikey_staged_$providerId',
      value: 'new-secret',
    );
    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode([provider.toJson()]),
      'ai_provider_secret_transactions_v1': jsonEncode({
        providerId: {
          'op': 'upsert',
          'expected': provider.toJson(),
          'deleteSecret': false,
        },
      }),
    });
    final prefs = await SharedPreferences.getInstance();

    AiProviderListNotifier(prefs);
    for (var attempt = 0; attempt < 10; attempt++) {
      if (!prefs.containsKey('ai_provider_secret_transactions_v1')) break;
      await Future<void>.delayed(Duration.zero);
    }

    expect(await secureStorage.read(key: storageKey), 'new-secret');
    expect(
      await secureStorage.read(key: 'ai_apikey_staged_$providerId'),
      isNull,
    );
    expect(prefs.containsKey('ai_provider_secret_transactions_v1'), isFalse);
  });

  test('未收敛的密钥事务会阻止后续 metadata mutation', () async {
    const providerId = 'pending-provider';
    final provider = AiProvider(
      id: providerId,
      name: 'Pending',
      type: AiProviderType.openai,
      baseUrl: 'https://example.com',
    );
    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode([provider.toJson()]),
      'ai_provider_secret_transactions_v1': jsonEncode({
        providerId: {
          'op': 'upsert',
          'expected': provider.toJson(),
          'deleteSecret': false,
        },
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final notifier = AiProviderListNotifier(prefs);
    await Future<void>.delayed(Duration.zero);

    await expectLater(notifier.togglePin(providerId), throwsStateError);
    expect(notifier.state.single.pinned, isFalse);
    expect(prefs.containsKey('ai_provider_secret_transactions_v1'), isTrue);
    expect(await AiProviderListNotifier.getApiKey(providerId), isNull);
  });
}
