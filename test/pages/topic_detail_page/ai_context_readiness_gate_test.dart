import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/ai_context_readiness_gate.dart';

enum _Scope { firstFive, all }

void main() {
  test(
    'scope changes during an in-flight load wait for the latest scope',
    () async {
      var currentScope = _Scope.firstFive;
      final ready = <_Scope>{};
      final firstFiveLoad = Completer<bool>();
      final allLoad = Completer<bool>();
      final requestedScopes = <_Scope>[];

      final gate = ContextReadinessGate<_Scope>(
        currentTarget: () => currentScope,
        isReady: ready.contains,
        load: (scope) {
          requestedScopes.add(scope);
          return switch (scope) {
            _Scope.firstFive => firstFiveLoad.future,
            _Scope.all => allLoad.future,
          };
        },
      );

      final firstEnsure = gate.ensure();
      final concurrentEnsure = gate.ensure();
      expect(identical(firstEnsure, concurrentEnsure), isTrue);
      expect(requestedScopes, [_Scope.firstFive]);

      // Simulate selecting "all posts" before the first five posts arrive.
      currentScope = _Scope.all;
      ready.add(_Scope.firstFive);
      firstFiveLoad.complete(true);
      await Future<void>.delayed(Duration.zero);

      expect(requestedScopes, [_Scope.firstFive, _Scope.all]);
      expect(allLoad.isCompleted, isFalse);

      ready.add(_Scope.all);
      allLoad.complete(true);

      await expectLater(firstEnsure, completion(isTrue));
    },
  );

  test('returns false when the requested scope cannot be loaded', () async {
    final gate = ContextReadinessGate<_Scope>(
      currentTarget: () => _Scope.all,
      isReady: (_) => false,
      load: (_) async => false,
    );

    await expectLater(gate.ensure(), completion(isFalse));
  });

  test('rechecks a scope change on the already-ready fast path', () async {
    var currentScope = _Scope.firstFive;
    final ready = <_Scope>{_Scope.firstFive};
    final requestedScopes = <_Scope>[];

    final gate = ContextReadinessGate<_Scope>(
      currentTarget: () => currentScope,
      isReady: (scope) {
        if (scope == _Scope.firstFive) currentScope = _Scope.all;
        return ready.contains(scope);
      },
      load: (scope) async {
        requestedScopes.add(scope);
        ready.add(scope);
        return true;
      },
    );

    await expectLater(gate.ensure(), completion(isTrue));
    expect(requestedScopes, [_Scope.all]);
  });
}
