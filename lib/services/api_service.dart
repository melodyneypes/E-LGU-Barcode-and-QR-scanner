import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  // Production Backend URL
  static const String defaultBaseUrl = "https://emapandan-lgu.vercel.app";
  static const String appKey = "agno-mobile-secret-2024";

  // Supabase Realtime Configuration (Self-hosted Tailscale / Ubuntu server)
  static const String supabaseUrl = "https://ubuntuserver1.tail054015.ts.net:8443";
  static const String supabaseAnonKey =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzkzMjQ4ODY3LCJleHAiOjE5NTA5Mjg4Njd9.bFnrBb1f4tdv2m5CpXDZVfOUF3bD0f5bk6T26uUar0M";

  static const String tokenKey = 'kiosk_token';
  static const String cachedThemeKey = 'kiosk_cached_theme_color';
  static const String cachedLogoKey = 'kiosk_cached_site_logo';
  static const String cachedMuniNameKey = 'kiosk_cached_municipality_name';
  static const String savedEmailKey = 'kiosk_saved_email';
  static const String rememberMeKey = 'kiosk_remember_me';

  static Future<String> getBaseUrl() async {
    return defaultBaseUrl;
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(tokenKey);
  }

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(tokenKey, token);
  }

  static Future<void> clearAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(tokenKey);
  }

  static Future<String?> getCachedThemeColor() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(cachedThemeKey);
  }

  static Future<String?> getCachedLogo() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(cachedLogoKey);
  }

  static Future<String?> getCachedMunicipalityName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(cachedMuniNameKey);
  }

  static Future<void> cacheBranding({
    String? themeColor,
    String? siteLogo,
    String? municipalityName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (themeColor != null && themeColor.isNotEmpty) {
      await prefs.setString(cachedThemeKey, themeColor);
    }
    if (siteLogo != null && siteLogo.isNotEmpty) {
      await prefs.setString(cachedLogoKey, siteLogo);
    }
    if (municipalityName != null && municipalityName.isNotEmpty) {
      await prefs.setString(cachedMuniNameKey, municipalityName);
    }
  }

  static Future<void> setRememberMe({
    required bool remember,
    required String email,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(rememberMeKey, remember);
    if (remember) {
      await prefs.setString(savedEmailKey, email);
    } else {
      await prefs.remove(savedEmailKey);
    }
  }

  static Future<Map<String, dynamic>> getSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool(rememberMeKey) ?? false;
    final email = prefs.getString(savedEmailKey) ?? "";
    return {'remember': remember, 'email': email};
  }

  static Future<Map<String, dynamic>> fetchPublicSettings() async {
    final base = await getBaseUrl();
    final url = Uri.parse('$base/api/kiosk/public-settings');

    try {
      final response = await http
          .get(url, headers: {'x-app-key': appKey})
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await cacheBranding(
          themeColor: data['themeColor'],
          siteLogo: data['siteLogo'],
          municipalityName: data['municipalityName'],
        );
        return data;
      }
    } catch (_) {}

    // Fallback: Fetch directly from Supabase SystemSetting table
    try {
      final supaUrl = Uri.parse(
        '$supabaseUrl/rest/v1/SystemSetting?key=in.(site_logo,theme_color,municipality_name)',
      );
      final supaRes = await http
          .get(
            supaUrl,
            headers: {
              'apikey': supabaseAnonKey,
              'Authorization': 'Bearer $supabaseAnonKey',
            },
          )
          .timeout(const Duration(seconds: 4));

      if (supaRes.statusCode == 200) {
        final List<dynamic> rows = jsonDecode(supaRes.body);
        String? themeColor;
        String? siteLogo;
        String? municipalityName = "Municipality of Mapandan";

        for (final row in rows) {
          if (row['key'] == 'theme_color') themeColor = row['value'];
          if (row['key'] == 'site_logo') siteLogo = row['value'];
          if (row['key'] == 'municipality_name') {
            municipalityName = row['value'];
          }
        }

        await cacheBranding(
          themeColor: themeColor,
          siteLogo: siteLogo,
          municipalityName: municipalityName,
        );

        return {
          'success': true,
          'themeColor': themeColor,
          'siteLogo': siteLogo,
          'municipalityName': municipalityName,
        };
      }
    } catch (_) {}

    return {};
  }

  static Future<Map<String, dynamic>> login(
    String email,
    String password,
  ) async {
    final base = await getBaseUrl();
    final url = Uri.parse('$base/api/kiosk/login');

    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json', 'x-app-key': appKey},
            body: jsonEncode({'email': email.trim(), 'password': password}),
          )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        if (data['token'] != null) {
          await saveToken(data['token']);
        }
        return {'success': true, 'user': data['user']};
      } else {
        return {
          'success': false,
          'error': data['error'] ?? 'Login failed (${response.statusCode})',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Network connection error: $e'};
    }
  }

  static Future<Map<String, dynamic>> getDashboard() async {
    final base = await getBaseUrl();
    final token = await getToken();

    if (token == null) {
      return {'success': false, 'error': 'Unauthorized'};
    }

    final url = Uri.parse('$base/api/kiosk/dashboard');

    try {
      final response = await http
          .get(
            url,
            headers: {'Authorization': 'Bearer $token', 'x-app-key': appKey},
          )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        await cacheBranding(
          themeColor: data['themeColor'],
          siteLogo: data['siteLogo'],
          municipalityName: data['municipalityName'],
        );
        return data;
      } else {
        return {
          'success': false,
          'error': data['error'] ?? 'Failed to load dashboard',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Connection error: $e'};
    }
  }

  static Future<Map<String, dynamic>> getTicketInfo(String code) async {
    final base = await getBaseUrl();
    final token = await getToken();

    if (token == null) {
      return {
        'success': false,
        'error': 'Session expired. Please login again.',
      };
    }

    final url = Uri.parse('$base/api/kiosk/lookup');

    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'transactionId': code}),
          )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);
      return data;
    } catch (e) {
      return {'success': false, 'error': 'Connection error: $e'};
    }
  }

  static Future<Map<String, dynamic>> checkIn({
    required String ticketOrQueueNumber,
    bool isPriority = false,
  }) async {
    final base = await getBaseUrl();
    final token = await getToken();

    if (token == null) {
      return {
        'success': false,
        'error': 'Session expired. Please login again.',
      };
    }

    final url = Uri.parse('$base/api/kiosk/check-in');

    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              'x-app-key': appKey,
            },
            body: jsonEncode({
              'transactionId': ticketOrQueueNumber.trim(),
              'isPriority': isPriority,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        return {
          'success': true,
          'message': data['message'] ?? 'Check-in successful!',
          'ticket': data['ticket'],
        };
      } else {
        return {
          'success': false,
          'error': data['error'] ?? 'Check-in failed (${response.statusCode})',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Connection error: $e'};
    }
  }

  static Future<Map<String, dynamic>> getCheckInHistory({
    int page = 1,
    int limit = 15,
    String? search,
  }) async {
    final base = await getBaseUrl();
    final token = await getToken();

    if (token == null) {
      return {
        'success': false,
        'error': 'Session expired. Please login again.',
      };
    }

    final queryParams = <String, String>{
      'page': page.toString(),
      'limit': limit.toString(),
    };
    if (search != null && search.trim().isNotEmpty) {
      queryParams['search'] = search.trim();
    }

    final uri = Uri.parse(
      '$base/api/kiosk/history',
    ).replace(queryParameters: queryParams);

    try {
      final response = await http
          .get(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              'x-app-key': appKey,
            },
          )
          .timeout(const Duration(seconds: 12));

      final data = jsonDecode(response.body);
      return data;
    } catch (e) {
      return {'success': false, 'error': 'Connection error: $e'};
    }
  }
}
