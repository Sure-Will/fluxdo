/// Serializes context loading while allowing the requested scope to change.
///
/// A topic can begin loading a small scope and then be switched to "all posts"
/// before the first request finishes. Every caller shares the same in-flight
/// task, and the task re-checks the most recent scope before it reports ready.
class ContextReadinessGate<T> {
  ContextReadinessGate({
    required this.currentTarget,
    required this.isReady,
    required this.load,
  });

  final T Function() currentTarget;
  final bool Function(T target) isReady;
  final Future<bool> Function(T target) load;

  Future<bool>? _inFlight;

  /// Completes only when the latest requested target is ready.
  Future<bool> ensure() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    Future<bool>? task;
    task = _run().whenComplete(() {
      if (identical(_inFlight, task)) _inFlight = null;
    });
    _inFlight = task;
    return task;
  }

  Future<bool> _run() async {
    while (true) {
      final target = currentTarget();
      if (isReady(target)) {
        // Keep the same invariant on the fast path as after an async load.
        // This also protects callers whose target changes as readiness is
        // being observed.
        if (currentTarget() == target) return true;
        continue;
      }

      final loaded = await load(target);
      if (!loaded) return false;

      // The user changed scope during the request. Load the new selection
      // before unblocking a send action.
      if (currentTarget() != target) continue;
      return isReady(target);
    }
  }
}
