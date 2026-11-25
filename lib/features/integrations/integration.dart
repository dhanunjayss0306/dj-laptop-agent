// Integrations framework — how DJ talks to outside apps.
//
// One [Integration] per app. Each one says what it is, whether it is
// connected, how to connect, and what actions it offers. The UI lists
// them from [IntegrationRegistry] and never talks to an app directly.
//
// ADDING A 4TH (OR 7TH) APP IS A SMALL JOB:
//   1. Make a class that implements [Integration] (see whatsapp.dart
//      for the smallest example — a deep-link integration with no auth).
//   2. Give it a unique [Integration.id] and one [IntegrationAction]
//      per thing it can do. An action is just a named function that
//      takes args and returns a plain-text result.
//   3. Register it in [defaultRegistry] (integrations.dart) — one line.
// No change to the framework, the UI, or any other integration.
//
// PRICING: there is none. DJ is the user's own app — no fee, no tiers,
// no usage limits, no account or sign-in system. An integration is
// either connected (the user connected it) or not; nothing is metered.

import 'dart:async';

/// One thing an integration can do.
///
/// [run] takes named args (e.g. {'query': '...'}) and returns a
/// plain-text result for the user. It never throws for a normal
/// failure — it returns a plain message saying what went wrong.
/// [needsConnection] actions refuse politely when not connected.
class IntegrationAction {
  const IntegrationAction({
    required this.name,
    required this.description,
    required this.run,
    this.needsConnection = true,
  });

  final String name;
  final String description;
  final Future<String> Function(Map<String, dynamic> args) run;

  /// False for actions that work without connecting (e.g. opening
  /// the app, or showing the connect instructions).
  final bool needsConnection;
}

/// One outside app DJ can talk to.
abstract class Integration {
  /// Stable id, used as the key in dj_config.json
  /// (integrations.`<id>`). Never change it once shipped.
  String get id;

  /// Display name, e.g. 'WhatsApp'.
  String get name;

  /// One plain line for the UI list.
  String get description;

  /// True when this integration is ready to use right now.
  /// Deep-link integrations are always connected; OAuth ones only
  /// after the user connects them; LocalApps only on Windows/Android.
  bool get isConnected;

  /// Connect this integration. Returns true when it ends up connected.
  ///
  /// For OAuth integrations this returns true only when tokens are
  /// already stored. The first-time flow is: UI calls the
  /// integration's auth-URL method, the user opens it in a browser
  /// and pastes the code back, the UI calls the submit-code method.
  /// [connect] itself never opens a browser — DJ has no browser of
  /// its own to open it in.
  Future<bool> connect();

  /// Disconnect: forgets stored tokens / state for this integration.
  /// Never touches any other integration's data.
  Future<void> disconnect();

  /// The actions this integration offers, in UI order.
  List<IntegrationAction> get actions;

  /// Run one action by name. Unknown name, or an action that needs a
  /// connection when not connected, returns a plain message.
  Future<String> runAction(String actionName, [Map<String, dynamic> args = const {}]) async {
    for (final action in actions) {
      if (action.name != actionName) continue;
      if (action.needsConnection && !isConnected) {
        return '$name is not connected yet. Connect it first, then try again.';
      }
      return action.run(args);
    }
    return 'Unknown action "$actionName" for $name.';
  }
}

/// The list of integrations, in the user's chosen order.
class IntegrationRegistry {
  final List<Integration> _integrations = [];

  void register(Integration integration) {
    _integrations
        .removeWhere((i) => i.id == integration.id);
    _integrations.add(integration);
  }

  void unregister(String id) =>
      _integrations.removeWhere((i) => i.id == id);

  List<Integration> list() => List.unmodifiable(_integrations);

  Integration? get(String id) {
    for (final i in _integrations) {
      if (i.id == id) return i;
    }
    return null;
  }
}
