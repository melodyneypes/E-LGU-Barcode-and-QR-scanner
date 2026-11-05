import '../theme/theme_controller.dart';
import '../theme/app_colors.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/realtime_service.dart';
import 'login_screen.dart';
import 'scanner_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _manualQueueController = TextEditingController();
  bool _isManualCheckingIn = false;
  int _currentTabIndex = 0;
  bool _isLoading = true;
  

  // Theming & Branding (Dynamic from systemSettings)
  Color _themeColor = const Color(0xFF1E3A8A);
  String? _siteLogo;
  String _municipalityName = "Municipal Front Desk";

  // Dashboard Metrics
  int _totalToday = 0;
  int _inQueue = 0;
  int _served = 0;
  List<dynamic> _activeQueue = [];

  // History State & Infinite Pagination
  final ScrollController _historyScrollController = ScrollController();
  final TextEditingController _historySearchController = TextEditingController();
  Timer? _searchDebounceTimer;
  List<dynamic> _historyList = [];
  int _historyPage = 1;
  int _historyTotalCount = 0;
  bool _isHistoryLoading = false;
  bool _isHistoryLoadingMore = false;
  bool _historyHasMore = true;

  // Live Clock
  late Timer _clockTimer;
  DateTime _currentTime = DateTime.now();

  // Realtime Subscriptions & Debounce
  StreamSubscription? _queueRealtimeSub;
  StreamSubscription? _historyRealtimeSub;
  StreamSubscription? _connectionStateSub;
  final Set<String> _recentScannedCodes = {};

  @override
  void initState() {
    super.initState();
    _loadInitialBranding();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() => _currentTime = DateTime.now());
      }
    });

    _fetchDashboardData();
    _initRealtimeListeners();

    _historyScrollController.addListener(_onHistoryScroll);
  }

  void _initRealtimeListeners() {
    final realtime = RealtimeService.instance;

    // Listen to real-time Transaction changes: instantly sync Active Queue & Dashboard stats (inQueue, served, totalToday)
    _queueRealtimeSub = realtime.onActiveQueueUpdate.listen((record) {
      if (!mounted) return;
      _handleRealtimeQueueUpdate(record);
    });

    // Listen to real-time Check-In History changes
    _historyRealtimeSub = realtime.onCheckInHistoryUpdate.listen((record) {
      if (!mounted) return;
      _handleRealtimeHistoryUpdate(record);
    });

    _connectionStateSub = realtime.onConnectionStateChanged.listen((connected) {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _handleRealtimeQueueUpdate(Map<String, dynamic> record) {
    // Sync dashboard stats (totalToday, inQueue, served) and active queue list in real-time
    _fetchDashboardData(silent: true);
  }

  void _handleRealtimeHistoryUpdate(Map<String, dynamic> record) {
    final queueNo = record['queueNumber']?.toString() ?? '';
    final ticketId = record['id']?.toString() ?? '';

    setState(() {
      final existingIndex = _historyList.indexWhere((item) {
        final itemQueue = item['queueNumber']?.toString();
        final itemId = item['id']?.toString();
        return (queueNo.isNotEmpty && itemQueue == queueNo) ||
               (ticketId.isNotEmpty && itemId == ticketId);
      });

      if (existingIndex >= 0) {
        _historyList[existingIndex] = {
          ..._historyList[existingIndex],
          ...record,
        };
      } else {
        _historyList.insert(0, record);
        _historyTotalCount++;
      }
    });
  }

  void _onHistoryScroll() {
    if (_historyScrollController.position.pixels >=
        _historyScrollController.position.maxScrollExtent - 200) {
      if (!_isHistoryLoading && !_isHistoryLoadingMore && _historyHasMore) {
        _loadMoreHistory();
      }
    }
  }

  Future<void> _fetchHistory({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _historyPage = 1;
        _historyHasMore = true;
        _isHistoryLoading = true;
      });
    } else {
      setState(() => _isHistoryLoading = true);
    }

    final query = _historySearchController.text.trim();
    final res = await ApiService.getCheckInHistory(
      page: 1,
      limit: 15,
      search: query.isNotEmpty ? query : null,
    );

    if (!mounted) return;

    if (res['success'] == true) {
      final List<dynamic> items = res['data'] ?? [];
      final pagination = res['pagination'] ?? {};
      setState(() {
        _historyList = items;
        _historyPage = 1;
        _historyTotalCount = pagination['totalCount'] ?? items.length;
        _historyHasMore = pagination['hasMore'] ?? false;
        _isHistoryLoading = false;
      });
    } else {
      setState(() => _isHistoryLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res['error'] ?? 'Failed to load check-in history'),
          backgroundColor: const Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _loadMoreHistory() async {
    if (_isHistoryLoadingMore || !_historyHasMore) return;

    setState(() => _isHistoryLoadingMore = true);
    final nextPage = _historyPage + 1;
    final query = _historySearchController.text.trim();

    final res = await ApiService.getCheckInHistory(
      page: nextPage,
      limit: 15,
      search: query.isNotEmpty ? query : null,
    );

    if (!mounted) return;

    if (res['success'] == true) {
      final List<dynamic> newItems = res['data'] ?? [];
      final pagination = res['pagination'] ?? {};
      setState(() {
        _historyList.addAll(newItems);
        _historyPage = nextPage;
        _historyTotalCount = pagination['totalCount'] ?? _historyList.length;
        _historyHasMore = pagination['hasMore'] ?? false;
        _isHistoryLoadingMore = false;
      });
    } else {
      setState(() => _isHistoryLoadingMore = false);
    }
  }

  Future<void> _loadInitialBranding() async {
    // 1. Instant cached branding
    final cachedTheme = await ApiService.getCachedThemeColor();
    final cachedLogo = await ApiService.getCachedLogo();
    final cachedMuni = await ApiService.getCachedMunicipalityName();

    if (mounted) {
      setState(() {
        if (cachedTheme != null && cachedTheme.isNotEmpty) {
          _themeColor = _hexToColor(cachedTheme);
        }
        if (cachedLogo != null && cachedLogo.isNotEmpty) {
          _siteLogo = cachedLogo;
        }
        if (cachedMuni != null && cachedMuni.isNotEmpty) {
          _municipalityName = cachedMuni;
        }
      });
    }

    // 2. Fetch fresh dynamic settings (with Supabase fallback)
    final fresh = await ApiService.fetchPublicSettings();
    if (mounted && fresh.isNotEmpty) {
      setState(() {
        if (fresh['themeColor'] != null) {
          _themeColor = _hexToColor(fresh['themeColor']);
        }
        if (fresh['siteLogo'] != null && (fresh['siteLogo'] as String).isNotEmpty) {
          _siteLogo = fresh['siteLogo'];
        }
        if (fresh['municipalityName'] != null) {
          _municipalityName = fresh['municipalityName'];
        }
      });
    }
  }

  @override
  void dispose() {
    _manualQueueController.dispose();
    _historyScrollController.dispose();
    _historySearchController.dispose();
    _searchDebounceTimer?.cancel();
    _clockTimer.cancel();
    _queueRealtimeSub?.cancel();
    _historyRealtimeSub?.cancel();
    _connectionStateSub?.cancel();
    super.dispose();
  }

  Color _hexToColor(String? hexString) {
    if (hexString == null || hexString.isEmpty) return const Color(0xFF1E3A8A);
    final buffer = StringBuffer();
    if (hexString.length == 6 || hexString.length == 7) buffer.write('ff');
    buffer.write(hexString.replaceFirst('#', ''));
    try {
      return Color(int.parse(buffer.toString(), radix: 16));
    } catch (_) {
      return const Color(0xFF1E3A8A);
    }
  }

  Future<void> _fetchDashboardData({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);

    final res = await ApiService.getDashboard();

    if (!mounted) return;

    if (res['success'] == true) {
      setState(() {
        _isLoading = false;
        
        if (res['themeColor'] != null) {
          _themeColor = _hexToColor(res['themeColor']);
        }
        if (res['siteLogo'] != null && (res['siteLogo'] as String).isNotEmpty) {
          _siteLogo = res['siteLogo'];
        }
        if (res['municipalityName'] != null) {
          _municipalityName = res['municipalityName'];
        }

        final stats = res['stats'] ?? {};
        _totalToday = stats['totalToday'] ?? 0;
        _inQueue = stats['inQueue'] ?? 0;
        _served = stats['served'] ?? 0;
        _activeQueue = res['activeQueue'] ?? [];
      });
    } else {
      if (!silent) {
        setState(() {
          _isLoading = false;
          
        });
      }
    }
  }

  

  Future<void> _openScanner() async {
    final scannedCode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScannerScreen()),
    );
    if (scannedCode != null && scannedCode.isNotEmpty) {
      _autoMutateScannedTicket(scannedCode);
    } else {
      _fetchDashboardData(silent: true);
    }
  }

  /// Automatically mutates ticket into Queue state immediately upon scanning barcode
  Future<void> _autoMutateScannedTicket(String rawCode) async {
    final code = rawCode.trim();
    if (code.isEmpty) return;

    // 1. Debounce guard: prevent duplicate scans within 3 seconds
    if (_recentScannedCodes.contains(code)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ticket $code is already being processed!'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    _recentScannedCodes.add(code);
    Timer(const Duration(seconds: 3), () {
      _recentScannedCodes.remove(code);
    });

    // 2. Optimistic UI update: Insert placeholder at top of active queue immediately
    final optimisticTicket = {
      'id': 'temp_${DateTime.now().millisecondsSinceEpoch}',
      'queueNumber': code,
      'status': 'QUEUEING',
      'serviceCategory': 'Citizen Check-In',
      'isPriority': false,
      'createdAt': DateTime.now().toIso8601String(),
      '_isOptimistic': true,
    };

    setState(() {
      _activeQueue.insert(0, optimisticTicket);
      _inQueue++;
    });

    HapticFeedback.mediumImpact();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Registering $code into Queue...')),
          ],
        ),
        duration: const Duration(seconds: 2),
        backgroundColor: _themeColor,
      ),
    );

    // 3. Dispatch mutation request to backend immediately
    final res = await ApiService.checkIn(
      ticketOrQueueNumber: code,
      isPriority: false,
    );

    if (!mounted) return;

    if (res['success'] == true) {
      final ticketData = res['ticket'] ?? {};
      HapticFeedback.lightImpact();

      // Authoritative replacement in active queue
      setState(() {
        final optIdx = _activeQueue.indexWhere((item) => item['queueNumber'] == code);
        if (optIdx >= 0) {
          _activeQueue[optIdx] = {
            ...ticketData,
            'status': 'QUEUEING',
          };
        }
      });

      _fetchDashboardData(silent: true);
      _showResultDialog(code: code, result: res);
    } else {
      // Rollback optimistic update on failure
      HapticFeedback.heavyImpact();
      setState(() {
        _activeQueue.removeWhere((item) => item['queueNumber'] == code);
        if (_inQueue > 0) _inQueue--;
      });

      _showResultDialog(code: code, result: res);
    }
  }

  Future<void> _handleManualCheckIn() async {
    final code = _manualQueueController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a queue number or ticket code'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    _processTicketConfirmation(code);
  }

  Future<void> _processTicketConfirmation(String code) async {
    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );

    final infoRes = await ApiService.getTicketInfo(code);

    if (!mounted) return;
    Navigator.pop(context); // Close loading dialog

    if (infoRes['success'] != true) {
      _showResultDialog(
        code: code,
        result: {
          'success': false,
          'error': infoRes['error'] ?? 'Ticket not found or invalid.',
        },
      );
      return;
    }

    final ticket = infoRes;
    _showConfirmationModal(code: code, ticket: ticket);
  }

  void _showConfirmationModal({required String code, required Map<String, dynamic> ticket}) {
    bool isPriority = ticket['isPriority'] == true || ticket['isSenior'] == true || ticket['isPWD'] == true;
    final bool isSenior = ticket['isSenior'] == true;
    final bool isPWD = ticket['isPWD'] == true;
    String priorityReason = 'Senior / PWD Priority';
    if (isSenior && isPWD) {
      priorityReason = 'Senior Citizen & PWD';
    } else if (isSenior) {
      priorityReason = 'Senior Citizen';
    } else if (isPWD) {
      priorityReason = 'PWD';
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 48,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  
                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Verify Citizen Ticket',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            ticket['serviceCategory'] ?? 'Service Request',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          ticket['queueNumber'] ?? code,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: _themeColor,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Resident & Ticket Information Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.person_rounded, size: 20, color: Color(0xFF475569)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                ticket['applicantName'] ?? 'Citizen Applicant',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const Divider(height: 1, color: Color(0xFFE2E8F0)),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Service:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                            Flexible(
                              child: Text(
                                ticket['serviceName'] ?? 'Service',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                                textAlign: TextAlign.right,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Barangay:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                            Text(
                              ticket['barangay'] ?? 'N/A',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Slot:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                            Text(
                              ticket['appointmentSlot'] ?? 'Regular',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Priority Lane Toggle Switch (Auto-toggled if Senior/PWD)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isPriority ? const Color(0xFFFEF3C7) : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isPriority ? const Color(0xFFF59E0B) : const Color(0xFFCBD5E1),
                        width: isPriority ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.accessible_forward_rounded,
                          color: isPriority ? const Color(0xFFD97706) : const Color(0xFF64748B),
                          size: 24,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Priority Lane (Senior / PWD)',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: isPriority ? const Color(0xFF92400E) : const Color(0xFF1E293B),
                                ),
                              ),
                              Text(
                                isPriority ? 'Auto-detected: $priorityReason' : 'Regular Lane',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isPriority ? FontWeight.w600 : FontWeight.normal,
                                  color: isPriority ? const Color(0xFFB45309) : const Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: isPriority,
                          activeColor: const Color(0xFFD97706),
                          onChanged: (val) {
                            setModalState(() {
                              isPriority = val;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Actions
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            side: BorderSide(color: Colors.grey.shade300),
                          ),
                          child: const Text('Cancel', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.pop(ctx); // Close modal
                            setState(() => _isManualCheckingIn = true);

                            final res = await ApiService.checkIn(
                              ticketOrQueueNumber: code,
                              isPriority: isPriority,
                            );

                            if (!mounted) return;
                            setState(() => _isManualCheckingIn = false);
                            _showResultDialog(code: code, result: res);
                          },
                          icon: const Icon(Icons.check_circle_rounded, size: 20),
                          label: const Text('Confirm & Queue', style: TextStyle(fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _themeColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            );
          },
        );
      },
    );
  }


  
  void _showResultDialog({required String code, required Map<String, dynamic> result}) {
    final bool isSuccess = result['success'] == true;
    final ticketData = result['ticket'];

    if (isSuccess) {
      _manualQueueController.clear();
      _fetchDashboardData(silent: true);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isSuccess ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isSuccess ? Icons.check_circle_rounded : Icons.cancel_rounded,
                  color: isSuccess ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                  size: 48,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isSuccess ? 'CHECK-IN SUCCESSFUL' : 'CHECK-IN REJECTED',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: isSuccess ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
              if (ticketData != null && ticketData['queueNumber'] != null) ...[
                Text(
                  'Queue: ${ticketData['queueNumber']}',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0F172A),
                  ),
                ),
                if (ticketData['serviceName'] != null)
                  Text(
                    '${ticketData['serviceName']}',
                    style: const TextStyle(fontSize: 14, color: Color(0xFF64748B)),
                  ),
                const SizedBox(height: 8),
              ],
              Text(
                isSuccess
                    ? (result['message'] ?? 'Ticket has been queued for calling.')
                    : (result['error'] ?? 'Invalid or expired ticket'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: isSuccess ? const Color(0xFF334155) : const Color(0xFF991B1B),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0F172A),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _themeColor,
      foregroundColor: Colors.white,
      elevation: 2,
      shadowColor: Colors.black26,
      toolbarHeight: 70,
      titleSpacing: 0,
      automaticallyImplyLeading: false,
      leading: IconButton(
        icon: const Icon(Icons.menu_rounded, color: Colors.white, size: 26),
        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        tooltip: 'Menu',
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(22)),
      ),
      title: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            // Municipality Seal Logo
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1.5),
              ),
              child: ClipOval(
                child: _siteLogo != null && _siteLogo!.isNotEmpty
                    ? Image.network(
                        _siteLogo!.startsWith('http')
                            ? _siteLogo!
                            : '${ApiService.defaultBaseUrl}$_siteLogo',
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => const Icon(
                          Icons.account_balance_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      )
                    : const Icon(
                        Icons.account_balance_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            // Titles
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _municipalityName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  Text(
                    'Queue Number Scanner',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12, top: 4),
          child: IconButton(
            onPressed: () {
              _fetchDashboardData();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Dashboard refreshed'),
                  duration: Duration(seconds: 1),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            icon: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.refresh_rounded, color: Colors.white, size: 20),
            ),
            tooltip: 'Refresh',
          ),
        ),
      ],
    );
  }

  Widget _buildDateTimeBanner() {
    final colors = context.colors;
    final dateFormat = DateFormat('EEEE, MMM d, yyyy');
    final timeFormat = DateFormat('h:mm a');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 18),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_today_rounded, size: 14, color: _themeColor),
              const SizedBox(width: 6),
              Text(
                dateFormat.format(_currentTime),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF334155),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Color(0xFF16A34A),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                timeFormat.format(_currentTime),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScanHeroCard() {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 18),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: context.isDarkMode ? 0.2 : 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            "Scan Applicants",
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: colors.textPrimary,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              "Scan ticket QR code or enter queue number to verify.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Tap to Scan Button
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              onPressed: _openScanner,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 22),
              label: const Text(
                'Tap to Scan QR Code',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _themeColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Divider
          Row(
            children: [
              Expanded(child: Divider(color: Colors.grey.shade200, thickness: 1)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'OR TYPE QUEUE NUMBER',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Colors.grey.shade400,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              Expanded(child: Divider(color: Colors.grey.shade200, thickness: 1)),
            ],
          ),
          const SizedBox(height: 12),
          // Manual Queue Number Input + Check Button
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 46,
                  decoration: BoxDecoration(
                    color: colors.inputBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: colors.inputBorder),
                  ),
                  child: TextField(
                    controller: _manualQueueController,
                    textCapitalization: TextCapitalization.characters,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                      letterSpacing: 0.5,
                    ),
                    decoration: const InputDecoration(
                      hintText: "Enter Queue / Ticket No.",
                      hintStyle: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.normal,
                        color: Color(0xFF94A3B8),
                      ),
                      prefixIcon: Icon(Icons.pin_outlined, color: Color(0xFF64748B), size: 20),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                    ),
                    onSubmitted: (_) => _handleManualCheckIn(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Check Button
              SizedBox(
                height: 46,
                width: 50,
                child: ElevatedButton(
                  onPressed: _isManualCheckingIn ? null : _handleManualCheckIn,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  child: _isManualCheckingIn
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_rounded, size: 26),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsCard() {
    final colors = context.colors;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 18),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildMetricColumn(
            icon: Icons.people_alt_rounded,
            iconColor: const Color(0xFF2563EB),
            iconBg: const Color(0xFFEFF6FF),
            count: _totalToday.toString(),
            label: 'Total Today',
          ),
          Container(width: 1, height: 44, color: colors.divider),
          _buildMetricColumn(
            icon: Icons.access_time_filled_rounded,
            iconColor: const Color(0xFF6366F1),
            iconBg: const Color(0xFFEEF2FF),
            count: _inQueue.toString(),
            label: 'In Queue',
          ),
          Container(width: 1, height: 44, color: colors.divider),
          _buildMetricColumn(
            icon: Icons.check_circle_rounded,
            iconColor: const Color(0xFF16A34A),
            iconBg: const Color(0xFFDCFCE7),
            count: _served.toString(),
            label: 'Served',
          ),
        ],
      ),
    );
  }

  Widget _buildMetricColumn({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String count,
    required String label,
  }) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
          child: Icon(icon, color: iconColor, size: 16),
        ),
        const SizedBox(height: 8),
        Text(
          count,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: context.colors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _buildActiveQueueSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Active Queue',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: context.colors.textPrimary,
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _currentTabIndex = 1);
                },
                child: Text(
                  'View All',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _themeColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_activeQueue.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.colors.cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: context.colors.cardBorder),
              ),
              child: Column(
                children: [
                  Icon(Icons.checklist_rounded, color: context.colors.textMuted, size: 36),
                  const SizedBox(height: 8),
                  Text(
                    'No active queue right now',
                    style: TextStyle(fontSize: 13, color: context.colors.textSecondary, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _activeQueue.length > 4 ? 4 : _activeQueue.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final item = _activeQueue[index];
                final isNowServing = item['status'] == 'Now Serving';

                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: context.colors.cardBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isNowServing
                          ? (context.isDarkMode ? const Color(0xFF059669) : const Color(0xFF86EFAC))
                          : context.colors.cardBorder,
                      width: isNowServing ? 1.5 : 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: context.isDarkMode ? 0.2 : 0.015),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      // Compact Badge Pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: isNowServing
                              ? (context.isDarkMode ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7))
                              : _themeColor.withValues(alpha: context.isDarkMode ? 0.2 : 0.09),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          item['queueNumber'] ?? 'N/A',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.2,
                            color: isNowServing
                                ? (context.isDarkMode ? const Color(0xFF34D399) : const Color(0xFF16A34A))
                                : _themeColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Service / Department
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['serviceName'] ?? 'Municipal Service',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: context.colors.textPrimary,
                              ),
                            ),
                            Text(
                              item['department'] ?? 'General',
                              style: TextStyle(
                                fontSize: 11,
                                color: context.colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Compact Status Pill
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                        decoration: BoxDecoration(
                          color: isNowServing
                              ? (context.isDarkMode ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7))
                              : (context.isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFEFF6FF)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          item['status'] ?? 'Waiting',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: isNowServing
                                ? (context.isDarkMode ? const Color(0xFF34D399) : const Color(0xFF16A34A))
                                : (context.isDarkMode ? const Color(0xFF60A5FA) : const Color(0xFF2563EB)),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: _themeColor),
      );
    }

    if (_currentTabIndex == 0) {
      return RefreshIndicator(
        onRefresh: () => _fetchDashboardData(),
        color: _themeColor,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              const SizedBox(height: 12),
              _buildDateTimeBanner(),
              const SizedBox(height: 10),
              _buildScanHeroCard(),
              const SizedBox(height: 10),
              _buildMetricsCard(),
              const SizedBox(height: 10),
              _buildActiveQueueSection(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      );
    } else if (_currentTabIndex == 1) {
      // Live Active Queue (Full View) - Strictly Current Day Only
      final dateFormat = DateFormat('EEE, MMM d, yyyy');
      return Scaffold(
        backgroundColor: context.colors.scaffoldBg,
        appBar: AppBar(
          backgroundColor: _themeColor,
          foregroundColor: Colors.white,
          elevation: 2,
          shadowColor: Colors.black26,
          toolbarHeight: 70,
          titleSpacing: 0,
          automaticallyImplyLeading: false,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(22)),
          ),
          leading: IconButton(
            icon: const Icon(Icons.menu_rounded, color: Colors.white, size: 26),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            tooltip: 'Menu',
          ),
          title: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Live Active Queue',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16.5, letterSpacing: -0.2),
                ),
                Text(
                  'Today • ${dateFormat.format(_currentTime)}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: IconButton(
                onPressed: () {
                  _fetchDashboardData();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Queue refreshed'),
                      duration: Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
                ),
                tooltip: 'Refresh Queue',
              ),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () => _fetchDashboardData(),
          color: _themeColor,
          child: Column(
            children: [
              // Summary Banner
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: context.colors.cardBg,
                  border: Border(bottom: BorderSide(color: context.colors.cardBorder, width: 1)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFF16A34A),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_activeQueue.length} Active in Queue Today',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: context.colors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      'Waiting: $_inQueue • Served: $_served',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: context.colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),

              // Queue List
              Expanded(
                child: _activeQueue.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: context.colors.chipBg,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.checklist_rounded, size: 40, color: context.colors.textMuted),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'No Active Tickets for Today',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: context.colors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'All tickets for today have been completed or cleared.',
                              style: TextStyle(fontSize: 12.5, color: context.colors.textSecondary),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        itemCount: _activeQueue.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final item = _activeQueue[index];
                          final isNowServing = item['status'] == 'Now Serving';

                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: context.colors.cardBg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isNowServing
                                    ? (context.isDarkMode ? const Color(0xFF059669) : const Color(0xFF86EFAC))
                                    : context.colors.cardBorder,
                                width: isNowServing ? 1.5 : 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: context.isDarkMode ? 0.2 : 0.02),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                // Compact High-Contrast Badge Pill
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isNowServing
                                        ? (context.isDarkMode ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7))
                                        : _themeColor.withValues(alpha: context.isDarkMode ? 0.2 : 0.09),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    item['queueNumber'] ?? 'N/A',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.3,
                                      color: isNowServing
                                          ? (context.isDarkMode ? const Color(0xFF34D399) : const Color(0xFF16A34A))
                                          : _themeColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Service / Department
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item['serviceName'] ?? 'Municipal Service',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w800,
                                          color: context.colors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                            decoration: BoxDecoration(
                                              color: context.colors.chipBg,
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              item['department'] ?? 'General',
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w600,
                                                color: context.colors.textSecondary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Status Pill
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isNowServing
                                        ? (context.isDarkMode ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7))
                                        : (context.isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFEFF6FF)),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: isNowServing
                                          ? (context.isDarkMode ? const Color(0xFF059669) : const Color(0xFF86EFAC))
                                          : (context.isDarkMode ? const Color(0xFF334155) : const Color(0xFFBFDBFE)),
                                    ),
                                  ),
                                  child: Text(
                                    item['status'] ?? 'Waiting',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: isNowServing
                                          ? (context.isDarkMode ? const Color(0xFF34D399) : const Color(0xFF16A34A))
                                          : (context.isDarkMode ? const Color(0xFF60A5FA) : const Color(0xFF2563EB)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    } else {
      return _buildHistoryView();
    }
  }

  Widget _buildHistoryView() {
    final colors = context.colors;
    final dateFormat = DateFormat('MMM d, yyyy');
    final timeFormat = DateFormat('h:mm a');

    return Scaffold(
      backgroundColor: colors.scaffoldBg,
      appBar: AppBar(
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 2,
        shadowColor: Colors.black26,
        toolbarHeight: 70,
        titleSpacing: 0,
        automaticallyImplyLeading: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(22)),
        ),
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded, color: Colors.white, size: 26),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          tooltip: 'Menu',
        ),
        title: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Check-In History',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16.5, letterSpacing: -0.2),
              ),
              Text(
                '$_historyTotalCount Total Checked-In Records',
                style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(
              onPressed: () => _fetchHistory(refresh: true),
              icon: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.refresh_rounded, color: Colors.white, size: 18),
              ),
              tooltip: 'Refresh History',
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search & Filter Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: colors.cardBg,
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: colors.inputBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.inputBorder),
                    ),
                    child: TextField(
                      controller: _historySearchController,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: colors.textPrimary),
                      textInputAction: TextInputAction.search,
                      onChanged: (value) {
                        _searchDebounceTimer?.cancel();
                        _searchDebounceTimer = Timer(const Duration(milliseconds: 400), () {
                          _fetchHistory(refresh: true);
                        });
                        setState(() {});
                      },
                      onSubmitted: (_) => _fetchHistory(refresh: true),
                      decoration: InputDecoration(
                        hintText: 'Search queue, citizen or ticket...',
                        hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                        prefixIcon: const Icon(Icons.search_rounded, size: 19, color: Color(0xFF64748B)),
                        suffixIcon: _historySearchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, size: 16, color: Color(0xFF64748B)),
                                onPressed: () {
                                  _searchDebounceTimer?.cancel();
                                  _historySearchController.clear();
                                  _fetchHistory(refresh: true);
                                },
                              )
                            : null,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: _themeColor,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _fetchHistory(refresh: true),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Icon(Icons.tune_rounded, color: Colors.white, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: Color(0xFFE2E8F0)),

          // History List View
          Expanded(
            child: _isHistoryLoading && _historyList.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: _themeColor),
                        const SizedBox(height: 12),
                        const Text(
                          'Loading check-in history...',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () => _fetchHistory(refresh: true),
                    color: _themeColor,
                    child: _historyList.isEmpty
                        ? Center(
                            child: SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: colors.chipBg,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(Icons.history_toggle_off_rounded, size: 40, color: colors.textMuted),
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    'No Check-In Records Found',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: colors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Scanned applicants will show up here automatically.',
                                    style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.separated(
                            controller: _historyScrollController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            itemCount: _historyList.length + (_historyHasMore ? 1 : 0),
                            separatorBuilder: (_, __) => const SizedBox(height: 9),
                            itemBuilder: (context, index) {
                              if (index == _historyList.length) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: _themeColor),
                                        ),
                                        const SizedBox(width: 10),
                                        const Text(
                                          'Loading more records...',
                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B)),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }

                              final item = _historyList[index];
                              final queueNo = item['queueNumber'] ?? 'N/A';
                              final citizenName = item['citizenName'] ?? 'Citizen Applicant';
                              final serviceName = item['serviceName'] ?? 'Municipal Service';
                              final department = item['department'] ?? 'General';
                              final isPriority = item['isPriority'] == true;
                              String status = (item['status'] ?? 'QUEUEING').toString().toUpperCase();
                              if (status == 'BOOKED' || status == 'WAITING') {
                                status = 'QUEUEING';
                              }

                              DateTime? checkInDate;
                              if (item['checkedInAt'] != null) {
                                checkInDate = DateTime.tryParse(item['checkedInAt'].toString());
                              } else if (item['createdAt'] != null) {
                                checkInDate = DateTime.tryParse(item['createdAt'].toString());
                              }

                              Color statusBg = context.isDarkMode ? const Color(0xFF1E293B) : const Color(0xFFEFF6FF);
                              Color statusFg = context.isDarkMode ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);
                              if (status == 'COMPLETED' || status == 'RELEASED') {
                                statusBg = context.isDarkMode ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7);
                                statusFg = context.isDarkMode ? const Color(0xFF34D399) : const Color(0xFF16A34A);
                              } else if (status == 'SERVING' || status == 'IN_PROGRESS' || status == 'FOR_CLAIM') {
                                statusBg = context.isDarkMode ? const Color(0xFF78350F) : const Color(0xFFFEF3C7);
                                statusFg = context.isDarkMode ? const Color(0xFFFBBF24) : const Color(0xFFD97706);
                              } else if (status == 'UNPAID' || status == 'CANCELLED') {
                                statusBg = context.isDarkMode ? const Color(0xFF450A0A) : const Color(0xFFFEE2E2);
                                statusFg = context.isDarkMode ? const Color(0xFFF87171) : const Color(0xFFDC2626);
                              }

                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                                decoration: BoxDecoration(
                                  color: colors.cardBg,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: colors.cardBorder),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: context.isDarkMode ? 0.2 : 0.02),
                                      blurRadius: 4,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      children: [
                                        // Queue Number Text
                                        Text(
                                          queueNo,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 0.3,
                                            color: _themeColor,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        // Citizen Name
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                citizenName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: colors.textPrimary,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                serviceName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: colors.textSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        // Status badge
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                          decoration: BoxDecoration(
                                            color: statusBg,
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            status,
                                            style: TextStyle(
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.w800,
                                              color: statusFg,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 7),
                                    Divider(height: 1, thickness: 0.8, color: colors.divider),
                                    const SizedBox(height: 6),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        // Department / Category Chip
                                        Flexible(
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.account_balance_rounded, size: 13, color: colors.textSecondary),
                                              const SizedBox(width: 4),
                                              Flexible(
                                                child: Text(
                                                  department,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    color: colors.textSecondary,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        // Priority Badge (In the middle)
                                        if (isPriority) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: context.isDarkMode ? const Color(0xFF450A0A) : const Color(0xFFFEF2F2),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(
                                                color: context.isDarkMode ? const Color(0xFF7F1D1D) : const Color(0xFFFECACA),
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.star_rounded,
                                                  size: 11,
                                                  color: context.isDarkMode ? const Color(0xFFF87171) : const Color(0xFFDC2626),
                                                ),
                                                const SizedBox(width: 2),
                                                Text(
                                                  'PRIORITY',
                                                  style: TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.w900,
                                                    color: context.isDarkMode ? const Color(0xFFF87171) : const Color(0xFFDC2626),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                        ],
                                        // Check-in Timestamp
                                        if (checkInDate != null)
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.access_time_rounded, size: 12.5, color: colors.textMuted),
                                              const SizedBox(width: 4),
                                              Text(
                                                '${dateFormat.format(checkInDate.toLocal())} • ${timeFormat.format(checkInDate.toLocal())}',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w500,
                                                  color: colors.textSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppDrawer() {
    return Drawer(
      backgroundColor: context.colors.drawerBg,
      child: Column(
        children: [
          // Drawer Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 52, 20, 24),
            decoration: BoxDecoration(
              color: _themeColor,
              borderRadius: const BorderRadius.only(
                bottomRight: Radius.circular(28),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 1.5),
                      ),
                      child: ClipOval(
                        child: _siteLogo != null && _siteLogo!.isNotEmpty
                            ? Image.network(
                                _siteLogo!.startsWith('http')
                                    ? _siteLogo!
                                    : '${ApiService.defaultBaseUrl}$_siteLogo',
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(
                                  Icons.account_balance_rounded,
                                  color: Colors.white,
                                  size: 26,
                                ),
                              )
                            : const Icon(
                                Icons.account_balance_rounded,
                                color: Colors.white,
                                size: 26,
                              ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _municipalityName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Queue Number Scanner',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: Color(0xFF4ADE80),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'Online • Active',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Menu Navigation Items
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                _buildDrawerItem(
                  icon: Icons.qr_code_scanner_rounded,
                  title: 'Scan & Check-In',
                  isSelected: _currentTabIndex == 0,
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _currentTabIndex = 0);
                  },
                ),
                const SizedBox(height: 6),
                _buildDrawerItem(
                  icon: Icons.people_alt_rounded,
                  title: 'Live Active Queue',
                  isSelected: _currentTabIndex == 1,
                  badgeText: '${_activeQueue.length}',
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _currentTabIndex = 1);
                  },
                ),
                const SizedBox(height: 6),
                _buildDrawerItem(
                  icon: Icons.history_rounded,
                  title: 'Check-In History',
                  isSelected: _currentTabIndex == 2,
                  badgeText: _historyTotalCount > 0 ? '$_historyTotalCount' : null,
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _currentTabIndex = 2);
                    if (_historyList.isEmpty) {
                      _fetchHistory(refresh: true);
                    }
                  },
                ),
              ],
            ),
          ),

          const Spacer(),

          // Dynamic Dark / Light Theme Toggle Pill
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: context.colors.chipBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.colors.cardBorder),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        context.isDarkMode ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                        size: 20,
                        color: context.isDarkMode ? const Color(0xFFF59E0B) : const Color(0xFFEAB308),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        context.isDarkMode ? 'Dark Mode' : 'Light Mode',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: context.colors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  Switch(
                    value: context.isDarkMode,
                    activeThumbColor: Colors.white,
                    activeTrackColor: _themeColor,
                    inactiveThumbColor: Colors.white,
                    inactiveTrackColor: const Color(0xFFCBD5E1),
                    onChanged: (_) async {
                      await ThemeController.toggleTheme();
                    },
                  ),
                ],
              ),
            ),
          ),

          // Logout Button at Footer
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              decoration: BoxDecoration(
                color: context.isDarkMode ? const Color(0xFF450A0A) : const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: context.isDarkMode ? const Color(0xFF7F1D1D) : const Color(0xFFFEE2E2),
                ),
              ),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: context.isDarkMode ? 0.25 : 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.logout_rounded,
                    color: context.isDarkMode ? const Color(0xFFF87171) : Colors.red,
                    size: 20,
                  ),
                ),
                title: Text(
                  'Log Out',
                  style: TextStyle(
                    color: context.isDarkMode ? const Color(0xFFF87171) : const Color(0xFFDC2626),
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: context.colors.modalBg,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: Text(
                        'Log Out',
                        style: TextStyle(fontWeight: FontWeight.bold, color: context.colors.textPrimary),
                      ),
                      content: Text(
                        'Are you sure you want to log out of this scanner?',
                        style: TextStyle(color: context.colors.textSecondary),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text('Cancel', style: TextStyle(color: context.colors.textSecondary)),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFDC2626),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Log Out'),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true) {
                    await ApiService.clearAuth();
                    if (!mounted) return;
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    );
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildDrawerItem({
    required IconData icon,
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
    String? badgeText,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isSelected ? _themeColor.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Icon(
          icon,
          color: isSelected ? _themeColor : const Color(0xFF64748B),
          size: 22,
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            color: isSelected ? _themeColor : context.colors.textPrimary,
          ),
        ),
        trailing: badgeText != null && badgeText != '0'
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isSelected ? _themeColor : const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? Colors.white : const Color(0xFF475569),
                  ),
                ),
              )
            : null,
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: context.colors.scaffoldBg,
      drawer: _buildAppDrawer(),
      appBar: _currentTabIndex == 0 ? _buildAppBar() : null,
      body: SafeArea(
        top: _currentTabIndex != 0,
        child: _buildBody(),
      ),
    );
  }
}


