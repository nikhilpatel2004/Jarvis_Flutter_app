import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:livekit_client/livekit_client.dart' as sdk;
import 'package:livekit_components/livekit_components.dart' as components;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

enum AppScreenState { welcome, agent }

enum AgentScreenState { visualizer, transcription }

class AppCtrl extends ChangeNotifier {
  static const uuid = Uuid();
  static final _logger = Logger('AppCtrl');

  // States
  AppScreenState appScreenState = AppScreenState.welcome;
  AgentScreenState agentScreenState = AgentScreenState.visualizer;

  //Test
  bool isUserCameEnabled = false;
  bool isScreenshareEnabled = false;

  final messageCtrl = TextEditingController();
  final messageFocusNode = FocusNode();

  late final sdk.Room room = sdk.Room(roomOptions: const sdk.RoomOptions(enableVisualizer: true));
  late final roomContext = components.RoomContext(room: room);
  late final sdk.Session session = _createSession(room: room);

  static sdk.Session _createSession({required sdk.Room room}) {
    // Development-only hardcoded credentials (optional).
    const hardcodedServerUrl = null; // e.g. 'wss://your-host'
    const hardcodedToken = null; // e.g. 'eyJ...'

    if (hardcodedServerUrl != null && hardcodedToken != null) {
      return sdk.Session.fromFixedTokenSource(
        sdk.LiteralTokenSource(
          serverUrl: hardcodedServerUrl,
          participantToken: hardcodedToken,
        ),
        options: sdk.SessionOptions(room: room),
      );
    }

    // HTTPS token endpoint (NOT the wss:// LiveKit server URL). The endpoint
    // returns the correct server_url for this project at runtime.
    const defaultTokenEndpoint =
        'https://cloud-api.livekit.io/api/v2/sandbox/connection-details';

    final sandboxId = dotenv.env['LIVEKIT_SANDBOX_ID']?.replaceAll('"', '').trim();
    final agentName = dotenv.env['LIVEKIT_AGENT_NAME']?.replaceAll('"', '').trim();
    final agentDeployment = dotenv.env['LIVEKIT_AGENT_DEPLOYMENT']?.replaceAll('"', '').trim();
    final customEndpoint = dotenv.env['LIVEKIT_TOKEN_ENDPOINT']?.replaceAll('"', '').trim();

    sdk.TokenSourceConfigurable tokenSource;
    if (customEndpoint != null && customEndpoint.isNotEmpty) {
      // Optional override: your own HTTPS token server endpoint.
      tokenSource = sdk.EndpointTokenSource(url: Uri.parse(customEndpoint));
    } else if (sandboxId == null || sandboxId.isEmpty || sandboxId == '<your-sandbox-id>') {
      // Fail with a clear message instead of falling back to a demo endpoint.
      tokenSource = sdk.CustomTokenSource((_) async {
        throw StateError(
          'LIVEKIT_SANDBOX_ID is missing in assets/.env. Copy assets/.env.example '
          'to assets/.env and set the token server ID from LiveKit Cloud '
          '(Project Settings -> Development token server).',
        );
      });
    } else {
      tokenSource = sdk.EndpointTokenSource(
        url: Uri.parse(defaultTokenEndpoint),
        headers: {'X-Sandbox-ID': sandboxId},
      );
    }

    return sdk.Session.fromConfigurableTokenSource(
      tokenSource,
      tokenOptions: sdk.TokenRequestOptions(
        agentName: agentName?.isEmpty ?? true ? null : agentName,
        agentDeployment: agentDeployment?.isEmpty ?? true ? null : agentDeployment,
      ),
      options: sdk.SessionOptions(room: room),
    );
  }

  bool isSendButtonEnabled = false;
  bool isSessionStarting = false;
  bool _hasCleanedUp = false;

  AppCtrl() {
    final format = DateFormat('HH:mm:ss');
    // configure logs for debugging
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${format.format(record.time)}: ${record.message}');
    });

    messageCtrl.addListener(() {
      final newValue = messageCtrl.text.isNotEmpty;
      if (newValue != isSendButtonEnabled) {
        isSendButtonEnabled = newValue;
        notifyListeners();
      }
    });

    session.addListener(_handleSessionChange);
  }

  Future<void> cleanUp() async {
    if (_hasCleanedUp) return;
    _hasCleanedUp = true;

    session.removeListener(_handleSessionChange);
    await session.dispose();
    await room.dispose();
    roomContext.dispose();
    messageCtrl.dispose();
    messageFocusNode.dispose();
  }

  @override
  void dispose() {
    unawaited(cleanUp());
    super.dispose();
  }

  void sendMessage() async {
    isSendButtonEnabled = false;

    final text = messageCtrl.text;
    messageCtrl.clear();
    notifyListeners();

    if (text.isEmpty) return;
    await session.sendText(text);
  }

  void toggleUserCamera(components.MediaDeviceContext? deviceCtx) {
    isUserCameEnabled = !isUserCameEnabled;
    isUserCameEnabled ? deviceCtx?.enableCamera() : deviceCtx?.disableCamera();
    notifyListeners();
  }

  void toggleScreenShare() {
    isScreenshareEnabled = !isScreenshareEnabled;
    notifyListeners();
  }

  void toggleAgentScreenMode() {
    agentScreenState =
        agentScreenState == AgentScreenState.visualizer ? AgentScreenState.transcription : AgentScreenState.visualizer;
    notifyListeners();
  }

  void connect() async {
    if (isSessionStarting) {
      _logger.fine('Connection attempt ignored: session already starting.');
      return;
    }

    _logger.info('Starting session connectionâ€¦');
    isSessionStarting = true;
    notifyListeners();

    try {
      await session.start();
      if (session.connectionState == sdk.ConnectionState.connected) {
        appScreenState = AppScreenState.agent;
        notifyListeners();
      }
    } catch (error, stackTrace) {
      _logger.severe('Connection error: $error', error, stackTrace);
      appScreenState = AppScreenState.welcome;
      notifyListeners();
    } finally {
      if (isSessionStarting) {
        isSessionStarting = false;
        notifyListeners();
      }
    }
  }

  Future<void> disconnect() async {
    await session.end();
    session.restoreMessageHistory(const []);
    appScreenState = AppScreenState.welcome;
    agentScreenState = AgentScreenState.visualizer;
    notifyListeners();
  }

  void _handleSessionChange() {
    final sdk.ConnectionState state = session.connectionState;
    AppScreenState? nextScreen;
    switch (state) {
      case sdk.ConnectionState.connected:
      case sdk.ConnectionState.reconnecting:
        nextScreen = AppScreenState.agent;
        break;
      case sdk.ConnectionState.disconnected:
        nextScreen = AppScreenState.welcome;
        break;
      case sdk.ConnectionState.connecting:
        nextScreen = null;
        break;
    }

    if (nextScreen != null && nextScreen != appScreenState) {
      appScreenState = nextScreen;
      notifyListeners();
    }
  }
}
