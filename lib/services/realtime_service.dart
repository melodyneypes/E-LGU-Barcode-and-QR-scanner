import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'api_service.dart';

/// RealtimeService manages persistent WebSocket connections to Supabase.
/// It delivers live events for Transactions, Active Queue updates, and Check-In history.
class RealtimeService {
  static RealtimeService? _instance;
  static RealtimeService get instance => _instance ??= RealtimeService._();

  RealtimeService._();

  bool _isInitialized = false;
  RealtimeChannel? _transactionChannel;

  // Stream controllers for decoupled reactivity
  final _activeQueueUpdateController = StreamController<Map<String, dynamic>>.broadcast();
  final _checkInHistoryUpdateController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();

  Stream<Map<String, dynamic>> get onActiveQueueUpdate => _activeQueueUpdateController.stream;
  Stream<Map<String, dynamic>> get onCheckInHistoryUpdate => _checkInHistoryUpdateController.stream;
  Stream<bool> get onConnectionStateChanged => _connectionStateController.stream;

  bool _isConnected = false;
  bool get isConnected => _isConnected;

  /// Initializes Supabase Flutter client safely
  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      await Supabase.initialize(
        url: ApiService.supabaseUrl,
        anonKey: ApiService.supabaseAnonKey,
        realtimeClientOptions: const RealtimeClientOptions(
          eventsPerSecond: 10,
        ),
      );
      _isInitialized = true;
      _subscribeToTransactions();
    } catch (e) {
      // Offline or network error
      _isConnected = false;
      _connectionStateController.add(false);
    }
  }

  /// Subscribes to postgres_changes on the Transaction table
  void _subscribeToTransactions() {
    if (!_isInitialized) return;

    final client = Supabase.instance.client;

    if (_transactionChannel != null) {
      client.removeChannel(_transactionChannel!);
    }

    _transactionChannel = client.channel('public:Transaction')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'Transaction',
        callback: (payload) {
          _handleTransactionChange(payload);
        },
      )
      ..subscribe((status, [error]) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          _isConnected = true;
          _connectionStateController.add(true);
        } else if (status == RealtimeSubscribeStatus.closed ||
            status == RealtimeSubscribeStatus.channelError) {
          _isConnected = false;
          _connectionStateController.add(false);
        }
      });
  }

  /// Evaluates incoming payload and directs to Queue or History stream
  void _handleTransactionChange(PostgresChangePayload payload) {
    final Map<String, dynamic> record = Map<String, dynamic>.from(
      payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord,
    );

    if (record.isEmpty) return;

    // Check if it's a check-in event (metadata additionalData has checkedIn: true)
    final dynamic rawAdditionalData = record['additionalData'];
    Map<String, dynamic>? additionalData;
    if (rawAdditionalData is Map) {
      additionalData = Map<String, dynamic>.from(rawAdditionalData);
    }

    final bool isCheckedIn = additionalData != null && additionalData['checkedIn'] == true;

    // 1. Broadcast to check-in history stream
    if (isCheckedIn) {
      _checkInHistoryUpdateController.add(record);
    }

    // 2. Broadcast to active queue stream
    _activeQueueUpdateController.add(record);
  }

  /// Call to clean up channels if needed
  void dispose() {
    if (_transactionChannel != null && _isInitialized) {
      Supabase.instance.client.removeChannel(_transactionChannel!);
    }
    _activeQueueUpdateController.close();
    _checkInHistoryUpdateController.close();
    _connectionStateController.close();
  }
}
