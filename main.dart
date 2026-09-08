import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}

  runApp(const InfoFutApp());
}

// ============================================================
// API
// ============================================================

class KickoffApiException implements Exception {
  final int statusCode;
  final String message;
  KickoffApiException(this.statusCode, this.message);

  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => 'KickoffAPI $statusCode: $message';
}

class KickoffApiService {
  static const String baseUrl = 'https://api.kickoffapi.com/api/v2';

  String get apiKey => dotenv.env['KICKOFF_API_KEY'] ?? '';

  Future<dynamic> _get(String path, [Map<String, String>? params]) async {
    if (apiKey.isEmpty || apiKey == 'SUA_CHAVE_AQUI') {
      throw Exception('Chave do KickoffAPI não encontrada no .env.');
    }

    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: params);
    final response = await http.get(
      uri,
      headers: {
        'x-api-key': apiKey,
        'Accept': 'application/json',
      },
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KickoffApiException(
        response.statusCode,
        response.body,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic> && decoded['data'] != null) {
      return decoded['data'];
    }
    if (decoded is Map<String, dynamic> && decoded['response'] != null) {
      return decoded['response'];
    }
    return decoded;
  }

  Future<List<dynamic>> getLivescores() async {
    final result = await _get('/fixtures', {'live': 'all'});
    return result is List ? result : [];
  }

  Future<List<dynamic>> getMatchesForDate(DateTime date) async {
    final result = await _get('/fixtures', {'date': _dateOnly(date)});
    return result is List ? result : [];
  }

  Future<dynamic> getFixtureDetails(String id) async {
    final fixture = await _get('/fixtures/$id');
    if (fixture is Map) {
      final map = Map<String, dynamic>.from(fixture);
      try {
        final events = await _get('/fixtures/$id/events');
        if (events is List) map['events'] = events;
      } catch (_) {}
      try {
        final lineups = await _get('/fixtures/$id/lineups');
        if (lineups is List) map['lineups'] = lineups;
      } catch (_) {}
      try {
        final stats = await _get('/fixtures/$id/statistics');
        if (stats is List) map['statistics'] = stats;
      } catch (_) {}
      return map;
    }
    return fixture;
  }

  Future<List<dynamic>> getHeadToHead(String team1, String team2) async {
    final result = await _get('/headtohead', {
      'team1': team1,
      'team2': team2,
    });
    return result is List ? result : [];
  }

  Future<List<dynamic>> getLeagueFixtures(String leagueId, {int? season}) async {
    if (leagueId.trim().isEmpty) return [];
    final params = <String, String>{'league': leagueId};
    if (season != null) params['season'] = '$season';
    final result = await _get('/fixtures', params);
    return result is List ? result : [];
  }

  Future<List<dynamic>> getLeagueStandings(String leagueId, {int? season}) async {
    if (leagueId.trim().isEmpty) return [];
    final params = <String, String>{'league': leagueId};
    if (season != null) params['season'] = '$season';
    final result = await _get('/standings', params);
    return result is List ? result : [];
  }

  Future<List<dynamic>> getLeagueOdds(String leagueId, {int? season}) async {
    if (leagueId.trim().isEmpty) return [];
    final params = <String, String>{'league': leagueId};
    if (season != null) params['season'] = '$season';
    final result = await _get('/odds', params);
    return result is List ? result : [];
  }

  Future<List<dynamic>> getLeagueTopScorers(String leagueId, {int? season}) async {
    if (leagueId.trim().isEmpty) return [];
    final params = <String, String>{'league': leagueId};
    if (season != null) params['season'] = '$season';
    final result = await _get('/topscorers', params);
    return result is List ? result : [];
  }

  String _dateOnly(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}



// ============================================================
// FONTE ALTERNATIVA (ESPN – sem chave)
// ============================================================
// Usada apenas quando a KickoffAPI falha ou retorna 429. Os dados são
// normalizados para o mesmo formato esperado pelos parsers do InfoFut.
class EspnFallbackService {
  static const String baseUrl =
      'https://site.api.espn.com/apis/site/v2/sports/soccer';

  // O endpoint "all" da ESPN pode não entregar todas as partidas.
  // Por isso o fallback consulta também as principais ligas diretamente.
  static const List<String> leagueCodes = [
    'eng.1', 'eng.2', 'eng.3', 'eng.4',
    'esp.1', 'esp.2',
    'ita.1', 'ita.2',
    'ger.1', 'ger.2',
    'fra.1', 'fra.2',
    'bra.1', 'bra.2',
    'mex.1', 'ned.1', 'sco.1', 'usa.1', 'usa.nwsl',
    'por.1', 'bel.1', 'tur.1', 'arg.1',
    'col.1', 'chl.1', 'uru.1', 'ecu.1', 'par.1', 'per.1',
    'uefa.champions', 'uefa.europa',
  ];

  Future<List<dynamic>> getMatchesForDate(DateTime date) async {
    final ymd = _ymd(date);
    final all = <dynamic>[];

    final generic = await _scoreboard(
      'all',
      {'dates': ymd, 'limit': '500'},
    );
    all.addAll(generic);

    final leagueResults = await Future.wait(
      leagueCodes.map(
        (league) => _scoreboard(league, {'dates': ymd, 'limit': '500'}),
      ),
    );
    for (final result in leagueResults) {
      all.addAll(result);
    }

    return _dedupe(all);
  }

  Future<List<dynamic>> getLivescores() async {
    final today = DateTime.now();
    final items = await getMatchesForDate(today);
    return items.where(_isLiveRaw).toList();
  }

  String _ymd(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}'
      '${date.month.toString().padLeft(2, '0')}'
      '${date.day.toString().padLeft(2, '0')}';

  bool _isLiveRaw(dynamic value) {
    final status = _asMap(_asMap(value)?['status']);
    final type = _asMap(status?['type']);
    final short = _safeString(
      status?['short'] ??
          status?['state'] ??
          type?['state'],
    ).toLowerCase();
    return short == 'live' ||
        short == 'in' ||
        short == 'inplay' ||
        short == 'in_play' ||
        short.contains('live');
  }

  List<dynamic> _dedupe(List<dynamic> items) {
    final seen = <String>{};
    final result = <dynamic>[];
    for (final item in items) {
      final id = _safeString(_asMap(item)?['id']);
      if (id.isEmpty || seen.add(id)) result.add(item);
    }
    return result;
  }

  Future<List<dynamic>> _scoreboard(
    String league,
    Map<String, String> params,
  ) async {
    try {
      final uri = Uri.parse('$baseUrl/$league/scoreboard').replace(queryParameters: params);
      final response = await http.get(uri, headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300) return [];
      final decoded = jsonDecode(response.body);
      final root = _asMap(decoded);
      final events = _asList(root?['events']);
      return events.map((event) => _normalizeEvent(event, league)).whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return [];
    }
  }

  String _espnCountry(String code) {
    if (code.startsWith('ita.')) return 'Itália';
    if (code.startsWith('bra.')) return 'Brasil';
    if (code.startsWith('eng.')) return 'Inglaterra';
    if (code.startsWith('esp.')) return 'Espanha';
    if (code.startsWith('ger.')) return 'Alemanha';
    if (code.startsWith('fra.')) return 'França';
    if (code.startsWith('por.')) return 'Portugal';
    if (code.startsWith('ned.')) return 'Holanda';
    if (code.startsWith('bel.')) return 'Bélgica';
    if (code.startsWith('tur.')) return 'Turquia';
    if (code.startsWith('arg.')) return 'Argentina';
    if (code.startsWith('col.')) return 'Colômbia';
    if (code.startsWith('chl.')) return 'Chile';
    if (code.startsWith('uru.')) return 'Uruguai';
    if (code.startsWith('ecu.')) return 'Equador';
    if (code.startsWith('par.')) return 'Paraguai';
    if (code.startsWith('per.')) return 'Peru';
    if (code.startsWith('mex.')) return 'México';
    if (code.startsWith('sco.')) return 'Escócia';
    if (code.startsWith('usa.')) return 'Estados Unidos';
    return 'Internacional';
  }

  Map<String, dynamic>? _normalizeEvent(dynamic raw, String sourceLeagueCode) {
    final event = _asMap(raw);
    if (event == null) return null;
    final competitions = _asList(event['competitions']);
    final comp = competitions.isNotEmpty ? _asMap(competitions.first) : null;
    final competitors = _asList(comp?['competitors']);
    Map<String, dynamic>? home;
    Map<String, dynamic>? away;
    for (final item in competitors) {
      final c = _asMap(item);
      final team = _asMap(c?['team']);
      if (c?['homeAway']?.toString() == 'home') home = {...?team, 'score': c?['score']};
      if (c?['homeAway']?.toString() == 'away') away = {...?team, 'score': c?['score']};
    }
    if (home == null || away == null) return null;
    final statusMap = _asMap(event['status']);
    final type = _asMap(statusMap?['type']);
    final completed = type?['completed'] == true;
    final state = _safeString(type?['state']).toLowerCase();
    final normalizedStatus = completed ? 'FT' : (state == 'in' ? 'LIVE' : 'scheduled');
    final elapsed = _toInt(statusMap?['displayClock']?.toString().split(':').first) ?? _toInt(statusMap?['period']);
    final league = _asMap(event['season']) ?? _asMap(comp?['season']);
    return {
      'id': 'espn_${_safeString(event['id'])}',
      'home': {'id': 'espn_${_safeString(home['id'])}', 'name': home['displayName'] ?? home['name'], 'logo': home['logo']},
      'away': {'id': 'espn_${_safeString(away['id'])}', 'name': away['displayName'] ?? away['name'], 'logo': away['logo']},
      'score': {'home': home['score'], 'away': away['score']},
      'status': {'short': normalizedStatus, 'elapsed': elapsed},
      'league': {
        'id': 'espn:$sourceLeagueCode',
        'code': sourceLeagueCode,
        'name': _safeString(event['name'], _safeString(league?['displayName'], 'Futebol')),
        'country': _espnCountry(sourceLeagueCode),
      },
      'date': event['date'],
      'source': 'espn',
    };
  }
}

// ============================================================
// MODELOS
// ============================================================

class TeamInfo {
  final int id;
  final String apiId;
  final String name;
  final String? logo;

  const TeamInfo({
    required this.id,
    this.apiId = '',
    required this.name,
    this.logo,
  });
}

class MatchEvent {
  final String type;
  final String player;
  final String? assist;
  final int minute;
  final String? team;
  final int? teamId;

  const MatchEvent({
    required this.type,
    required this.player,
    required this.minute,
    this.assist,
    this.team,
    this.teamId,
  });
}

class MatchStat {
  final String label;
  final String home;
  final String away;

  const MatchStat({
    required this.label,
    required this.home,
    required this.away,
  });
}

class MatchLineup {
  final String player;
  final String number;
  final String position;

  const MatchLineup({
    required this.player,
    required this.number,
    required this.position,
  });
}

class LiveMatch {
  final int id;
  final String apiId;
  final TeamInfo home;
  final TeamInfo away;
  final int? homeScore;
  final int? awayScore;
  final String status;
  final int? minute;
  final String league;
  final String country;
  final String leagueApiId;
  final String? leagueLogo;
  final int? leagueSeason;
  final DateTime? startTime;
  final List<MatchEvent> events;
  final String? round;

  const LiveMatch({
    required this.id,
    this.apiId = '',
    required this.home,
    required this.away,
    this.homeScore,
    this.awayScore,
    required this.status,
    this.minute,
    required this.league,
    this.country = 'Internacional',
    this.leagueApiId = '',
    this.leagueLogo,
    this.leagueSeason,
    this.startTime,
    this.events = const [],
    this.round,
  });

  bool get isLive {
    final value = status.toLowerCase();

    return value.contains('live') ||
        value.contains('inplay') ||
        value.contains('in_play') ||
        value.contains('1h') ||
        value.contains('2h') ||
        value.contains('halftime') ||
        value.contains('extra') ||
        value.contains('pen');
  }

  bool get isFinished {
    final value = status.toLowerCase();

    return value.contains('finished') ||
        value.contains('ft') ||
        value.contains('ended') ||
        value.contains('complete');
  }

  bool get isScheduled {
    return !isLive && !isFinished;
  }
}

class MatchDetails {
  final int id;
  final String apiId;
  final TeamInfo home;
  final TeamInfo away;
  final int? homeScore;
  final int? awayScore;
  final String status;
  final String league;
  final String venue;
  final DateTime? startTime;
  final List<MatchEvent> events;
  final List<MatchStat> stats;
  final List<MatchLineup> homeLineup;
  final List<MatchLineup> awayLineup;

  const MatchDetails({
    required this.id,
    this.apiId = '',
    required this.home,
    required this.away,
    this.homeScore,
    this.awayScore,
    required this.status,
    required this.league,
    required this.venue,
    this.startTime,
    this.events = const [],
    this.stats = const [],
    this.homeLineup = const [],
    this.awayLineup = const [],
  });
}

// ============================================================
// PARSERS
// ============================================================

int? _toInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  return int.tryParse(value.toString());
}

String _safeString(dynamic value, [String fallback = '']) {
  if (value == null) return fallback;
  return value.toString();
}

Map<String, dynamic>? _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

List<dynamic> _asList(dynamic value) => value is List ? value : [];

int _localId(String value) => value.hashCode.abs();

List<dynamic> _getParticipants(dynamic fixture) {
  final map = _asMap(fixture);
  if (map == null) return [];

  // KickoffAPI V2 usa diretamente os objetos "home" e "away".
  final teams = _asMap(map['teams']);
  final home = _asMap(map['home']) ?? _asMap(teams?['home']);
  final away = _asMap(map['away']) ?? _asMap(teams?['away']);
  if (home != null || away != null) {
    return [
      if (home != null) {...home, '_side': 'home'},
      if (away != null) {...away, '_side': 'away'},
    ];
  }

  // Compatibilidade com formatos antigos.
  final homeTeam = _asMap(map['homeTeam']);
  final awayTeam = _asMap(map['awayTeam']);
  if (homeTeam != null || awayTeam != null) {
    return [
      if (homeTeam != null) {...homeTeam, '_side': 'home'},
      if (awayTeam != null) {...awayTeam, '_side': 'away'},
    ];
  }

  return _asList(map['participants']);
}

TeamInfo _parseTeam(dynamic raw, String fallbackName) {
  final map = _asMap(raw);
  if (map == null) return TeamInfo(id: 0, name: fallbackName);

  final apiId = _safeString(map['id']);
  final name = _safeString(
    map['name'] ?? map['shortName'] ?? map['short_name'],
    fallbackName,
  );

  final logo = map['logo']?.toString() ??
      map['logoUrl']?.toString() ??
      map['logo_url']?.toString() ??
      map['image_path']?.toString() ??
      map['image']?.toString();

  return TeamInfo(
    id: apiId.isEmpty ? 0 : _localId(apiId),
    apiId: apiId,
    name: name.isEmpty ? fallbackName : name,
    logo: logo,
  );
}

TeamInfo _findHomeTeam(dynamic fixture) {
  final map = _asMap(fixture);

  // KickoffAPI V2 / H2H: home: {...} ou teams: { home: {...} }
  final teams = _asMap(map?['teams']);
  final home = _asMap(map?['home']) ?? _asMap(teams?['home']);
  if (home != null) return _parseTeam(home, 'Mandante');

  final homeTeam = _asMap(map?['homeTeam']);
  if (homeTeam != null) return _parseTeam(homeTeam, 'Mandante');

  for (final raw in _getParticipants(fixture)) {
    final m = _asMap(raw);
    if (m?['_side'] == 'home') return _parseTeam(m, 'Mandante');

    final meta = _asMap(m?['meta']);
    if (meta?['location']?.toString().toLowerCase() == 'home') {
      return _parseTeam(m, 'Mandante');
    }
  }

  final p = _getParticipants(fixture);
  return p.isNotEmpty
      ? _parseTeam(p.first, 'Mandante')
      : const TeamInfo(id: 0, name: 'Mandante');
}

TeamInfo _findAwayTeam(dynamic fixture) {
  final map = _asMap(fixture);

  // KickoffAPI V2 / H2H: away: {...} ou teams: { away: {...} }
  final teams = _asMap(map?['teams']);
  final away = _asMap(map?['away']) ?? _asMap(teams?['away']);
  if (away != null) return _parseTeam(away, 'Visitante');

  final awayTeam = _asMap(map?['awayTeam']);
  if (awayTeam != null) return _parseTeam(awayTeam, 'Visitante');

  for (final raw in _getParticipants(fixture)) {
    final m = _asMap(raw);
    if (m?['_side'] == 'away') return _parseTeam(m, 'Visitante');

    final meta = _asMap(m?['meta']);
    if (meta?['location']?.toString().toLowerCase() == 'away') {
      return _parseTeam(m, 'Visitante');
    }
  }

  final p = _getParticipants(fixture);
  return p.length > 1
      ? _parseTeam(p[1], 'Visitante')
      : const TeamInfo(id: 0, name: 'Visitante');
}

int? _scoreForTeam(dynamic fixture, int teamId) {
  final map = _asMap(fixture);
  if (map == null) return null;

  // KickoffAPI V2: score: { home: 2, away: 1, halftime: {...} }
  final score = _asMap(map['score']) ?? _asMap(map['goals']);
  final teams = _asMap(map['teams']);
  final home = _asMap(map['home']) ?? _asMap(teams?['home']);
  final away = _asMap(map['away']) ?? _asMap(teams?['away']);

  final homeId = _safeString(home?['id']);
  final awayId = _safeString(away?['id']);

  if (homeId.isNotEmpty && _localId(homeId) == teamId) {
    return _toInt(score?['home']) ?? _toInt(map['homeScore']);
  }

  if (awayId.isNotEmpty && _localId(awayId) == teamId) {
    return _toInt(score?['away']) ?? _toInt(map['awayScore']);
  }

  // Compatibilidade com formato antigo.
  final oldHome = _asMap(map['homeTeam']);
  final oldAway = _asMap(map['awayTeam']);
  final oldHomeId = _safeString(oldHome?['id']);
  final oldAwayId = _safeString(oldAway?['id']);

  if (oldHomeId.isNotEmpty && _localId(oldHomeId) == teamId) {
    return _toInt(map['homeScore']) ?? _toInt(score?['home']);
  }

  if (oldAwayId.isNotEmpty && _localId(oldAwayId) == teamId) {
    return _toInt(map['awayScore']) ?? _toInt(score?['away']);
  }

  for (final raw in _asList(map['scores'])) {
    final item = _asMap(raw);
    if (item == null) continue;

    final participant = _safeString(
      item['participant_id'] ?? item['team_id'] ?? _asMap(item['team'])?['id'],
    );

    if (participant.isNotEmpty && _localId(participant) == teamId) {
      return _toInt(_asMap(item['score'])?['goals']) ??
          _toInt(item['goals']);
    }
  }

  return null;
}

String _findState(dynamic fixture) {
  final map = _asMap(fixture);

  // KickoffAPI V2 normalmente devolve status como objeto:
  // { long: "Second Half", short: "2H", elapsed: 74 }
  final statusMap = _asMap(map?['status']);
  if (statusMap != null) {
    final shortValue = _safeString(
      statusMap['short'] ??
          statusMap['short_name'] ??
          statusMap['code'] ??
          statusMap['status'],
    );
    if (shortValue.isNotEmpty) return shortValue;

    final longValue = _safeString(
      statusMap['long'] ??
          statusMap['name'] ??
          statusMap['developer_name'],
    );
    if (longValue.isNotEmpty) return longValue;
  }

  // Compatibilidade com respostas onde status vem como texto.
  final statusText = map?['status'];
  if (statusText is String && statusText.trim().isNotEmpty) {
    return statusText.trim();
  }

  final state = _asMap(map?['state']);
  return _safeString(
    state?['short'] ??
        state?['short_name'] ??
        state?['name'] ??
        state?['developer_name'],
    'scheduled',
  );
}

int? _findMinute(dynamic fixture) {
  final map = _asMap(fixture);
  final status = _asMap(map?['status']);
  final direct = _toInt(map?['minute']) ?? _toInt(status?['elapsed']);
  if (direct != null) return direct;
  for (final raw in _asList(map?['periods']).reversed) {
    final p = _asMap(raw);
    final m = _toInt(p?['minutes']) ?? _toInt(p?['elapsed']);
    if (m != null) return m;
  }
  return null;
}

String _findCountry(dynamic fixture) {
  final map = _asMap(fixture);
  final league = _asMap(map?['league']);
  final direct = _safeString(league?['country'] ?? league?['countryName']).trim();
  if (direct.isNotEmpty) return direct;

  final name = _safeString(league?['name']).toLowerCase();
  if (name.contains('premier league') || name.contains('championship') || name.contains('league one') || name.contains('league two')) return 'Inglaterra';
  if (name.contains('laliga') || name.contains('la liga')) return 'Espanha';
  if (name.contains('serie a') || name.contains('serie b')) return 'Itália';
  if (name.contains('bundesliga')) return 'Alemanha';
  if (name.contains('ligue 1') || name.contains('ligue 2')) return 'França';
  if (name.contains('eredivisie') || name.contains('eerste divisie')) return 'Holanda';
  if (name.contains('primeira liga') || name.contains('liga portugal')) return 'Portugal';
  if (name.contains('brasileir') || name.contains('carioca') || name.contains('paulista')) return 'Brasil';
  if (name.contains('nwsl') || name.contains('mls')) return 'Estados Unidos';
  if (name.contains('liga de expansión') || name.contains('liga de expansion') || name.contains('liga mx')) return 'México';
  if (name.contains('liga profesional')) return 'Argentina';
  if (name.contains('champions') || name.contains('europa league') || name.contains('conference league')) return 'Europa';
  return 'Internacional';
}

String _findLeague(dynamic fixture) {
  final map = _asMap(fixture);
  return _safeString(_asMap(map?['league'])?['name'], 'Futebol');
}

String _findLeagueApiId(dynamic fixture) {
  final map = _asMap(fixture);
  return _safeString(_asMap(map?['league'])?['id']);
}

String? _findLeagueLogo(dynamic fixture) {
  final map = _asMap(fixture);
  final league = _asMap(map?['league']);
  final value = league?['logo'] ?? league?['image'] ?? league?['image_path'];
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

int? _findLeagueSeason(dynamic fixture) {
  final map = _asMap(fixture);
  return _toInt(_asMap(map?['league'])?['season']);
}

DateTime? _findStartTime(dynamic fixture) {
  final map = _asMap(fixture);
  return DateTime.tryParse(_safeString(map?['date'] ?? map?['starting_at']))?.toLocal();
}

String _findVenue(dynamic fixture) {
  final venue = _asMap(_asMap(fixture)?['venue']);
  return _safeString(venue?['name'], 'Estádio não informado');
}

int _findEventMinute(Map<String, dynamic> event) {
  final time = _asMap(event['time']);
  return _toInt(event['minute']) ?? _toInt(event['time']) ?? _toInt(time?['elapsed']) ?? 0;
}

String _findPlayerName(Map<String, dynamic> event) {
  final player = _asMap(event['player']);
  return _safeString(player?['name'] ?? event['playerName'] ?? event['player_name'], 'Jogador');
}

String _normalizeEventType(Map<String, dynamic> event) {
  final type = [event['type'], event['code'], event['event_type'], event['sub_type'], event['detail']]
      .where((e) => e != null).map((e) => e.toString().toLowerCase()).join(' ');
  if (type.contains('goal') || type.contains('scored') || type.contains('score')) return 'goal';
  if (type.contains('yellow')) return 'yellow';
  if (type.contains('red')) return 'red';
  if (type.contains('substitution') || type.contains('sub')) return 'substitution';
  return 'other';
}

List<MatchEvent> _parseEvents(dynamic fixture) {
  final map = _asMap(fixture);
  if (map == null) return [];

  // Os provedores não usam sempre o mesmo nome para a linha do tempo.
  // Procura também nas estruturas mais comuns para não perder os minutos dos gols.
  final nestedFixture = _asMap(map['fixture']);
  final rawEvents = <dynamic>[
    ..._asList(map['events']),
    ..._asList(map['incidents']),
    ..._asList(map['timeline']),
    ..._asList(map['event']),
    ..._asList(nestedFixture?['events']),
    ..._asList(nestedFixture?['incidents']),
    ..._asList(nestedFixture?['timeline']),
  ];

  final result = <MatchEvent>[];
  final seen = <String>{};
  for (final raw in rawEvents) {
    final event = _asMap(raw);
    if (event == null) continue;
    final type = _normalizeEventType(event);
    if (type == 'other') continue;
    final minute = _findEventMinute(event);
    final uniqueKey = '${type}_${minute}_${_safeString(event['id'] ?? event['playerId'] ?? event['player_id'] ?? event['playerName'])}';
    if (!seen.add(uniqueKey)) continue;
    final teamRaw = _asMap(event['team']) ?? _asMap(event['participant']);
    final teamIdText = _safeString(
      event['teamId'] ??
          event['team_id'] ??
          event['participant_id'] ??
          event['participantId'] ??
          teamRaw?['id'],
    );
    final teamId = teamIdText.isEmpty ? null : _localId(teamIdText);
    String? teamName = _safeString(
      teamRaw?['name'] ?? event['teamName'] ?? event['team_name'],
    );
    if (teamName.isEmpty) teamName = null;
    if (teamName == null && teamIdText.isNotEmpty) {
      for (final rawTeam in _getParticipants(fixture)) {
        final t = _asMap(rawTeam);
        if (_safeString(t?['id']) == teamIdText) { teamName = t?['name']?.toString(); break; }
      }
    }
    final assist = _asMap(event['assist']);
    result.add(MatchEvent(
      type: type,
      player: _findPlayerName(event),
      assist: assist?['name']?.toString() ?? event['assistName']?.toString(),
      minute: minute,
      team: teamName,
      teamId: teamId,
    ));
  }
  result.sort((a, b) => a.minute.compareTo(b.minute));
  return result;
}

String? _findRound(dynamic fixture) {
  final map = _asMap(fixture);
  final league = _asMap(map?['league']);
  final season = _asMap(map?['season']);
  final round = map?['round'] ?? map?['matchday'] ?? map?['roundName'] ??
      league?['round'] ?? league?['matchday'] ?? season?['round'];
  if (round == null) return null;
  final value = round.toString().trim();
  return value.isEmpty ? null : value;
}

LiveMatch _parseLiveMatch(dynamic fixture) {
  final map = _asMap(fixture) ?? {};
  final home = _findHomeTeam(fixture);
  final away = _findAwayTeam(fixture);
  final apiId = _safeString(map['id']);
  return LiveMatch(
    id: apiId.isEmpty ? 0 : _localId(apiId),
    apiId: apiId,
    home: home,
    away: away,
    homeScore: _scoreForTeam(fixture, home.id),
    awayScore: _scoreForTeam(fixture, away.id),
    status: _findState(fixture),
    minute: _findMinute(fixture),
    league: _findLeague(fixture),
    country: _findCountry(fixture),
    leagueApiId: _findLeagueApiId(fixture),
    leagueLogo: _findLeagueLogo(fixture),
    leagueSeason: _findLeagueSeason(fixture),
    startTime: _findStartTime(fixture),
    events: _parseEvents(fixture),
    round: _findRound(fixture),
  );
}

MatchDetails _parseDetails(dynamic fixture) {
  final map = _asMap(fixture) ?? {};
  final home = _findHomeTeam(fixture);
  final away = _findAwayTeam(fixture);
  final apiId = _safeString(map['id']);
  final lineups = _parseLineups(map['lineups']);
  return MatchDetails(
    id: apiId.isEmpty ? 0 : _localId(apiId),
    apiId: apiId,
    home: home,
    away: away,
    homeScore: _scoreForTeam(fixture, home.id),
    awayScore: _scoreForTeam(fixture, away.id),
    status: _findState(fixture),
    league: _findLeague(fixture),
    venue: _findVenue(fixture),
    startTime: _findStartTime(fixture),
    events: _parseEvents(fixture),
    stats: _parseStatistics(map['statistics']),
    homeLineup: lineups.$1,
    awayLineup: lineups.$2,
  );
}

List<MatchStat> _parseStatistics(dynamic raw) {
  final result = <MatchStat>[];
  for (final itemRaw in _asList(raw)) {
    final item = _asMap(itemRaw);
    if (item == null) continue;
    final stats = _asMap(item['statistics']);
    if (stats != null) {
      final teamId = _safeString(item['teamId'] ?? _asMap(item['team'])?['id']);
      for (final entry in stats.entries) {
        final label = entry.key.toString();
        final value = entry.value?.toString() ?? '-';
        result.add(MatchStat(label: label, home: teamId.isNotEmpty && result.length.isEven ? value : '-', away: teamId.isNotEmpty && result.length.isOdd ? value : '-'));
      }
      continue;
    }
    final type = _asMap(item['type']);
    result.add(MatchStat(
      label: _safeString(item['name'] ?? type?['name'], 'Estatística'),
      home: _safeString(item['home'] ?? _asMap(item['data'])?['home'], '-'),
      away: _safeString(item['away'] ?? _asMap(item['data'])?['away'], '-'),
    ));
  }
  return result;
}

(List<MatchLineup>, List<MatchLineup>) _parseLineups(dynamic raw) {
  final home = <MatchLineup>[];
  final away = <MatchLineup>[];
  for (final itemRaw in _asList(raw)) {
    final item = _asMap(itemRaw);
    if (item == null) continue;
    final teamId = _safeString(item['teamId'] ?? _asMap(item['team'])?['id']);
    final add = (dynamic playerRaw) {
      final p = _asMap(playerRaw) ?? {};
      final player = _asMap(p['player']);
      return MatchLineup(
        player: _safeString(p['playerName'] ?? player?['name'], 'Jogador'),
        number: _safeString(p['number'] ?? p['jersey_number'], '-'),
        position: _safeString(p['pos'] ?? p['position'], ''),
      );
    };
    final starters = _asList(item['startXI']);
    final substitutes = _asList(item['substitutes']);
    final target = teamId == '' ? home : (home.isEmpty ? home : away);
    for (final p in [...starters, ...substitutes]) target.add(add(p));
  }
  return (home, away);
}

class _ProfileMenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;
  const _ProfileMenuItem({required this.icon, required this.title, required this.onTap, this.danger = false});
  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        leading: Icon(icon, color: danger ? Colors.red : null),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: danger ? Colors.red : null)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: onTap,
      );
}

class _ThemeQuickOption extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _ThemeQuickOption({required this.title, required this.icon, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? const Color(0xFF18C96E) : Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 18),
            const SizedBox(width: 6),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        ),
      );
}

// ============================================================
// MEU PERFIL
// ============================================================

class ProfilePage extends StatefulWidget {
  final double currentFontScale;
  final Future<void> Function(double value) onFontScaleChanged;
  final String currentMatchOrder;
  final Future<void> Function(String value) onMatchOrderChanged;

  const ProfilePage({
    super.key,
    required this.currentFontScale,
    required this.onFontScaleChanged,
    required this.currentMatchOrder,
    required this.onMatchOrderChanged,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late double selectedScale;
  late String selectedMatchOrder;

  @override
  void initState() {
    super.initState();
    selectedScale = widget.currentFontScale;
    selectedMatchOrder = widget.currentMatchOrder;
  }

  String _fontLabel(double value) {
    if (value >= 1.45) return 'Extra grande';
    if (value >= 1.15) return 'Grande';
    return 'Normal';
  }

  Future<void> _selectFont(double value) async {
    setState(() => selectedScale = value);
    await widget.onFontScaleChanged(value);
  }

  Future<void> _selectMatchOrder(String value) async {
    setState(() => selectedMatchOrder = value);
    await widget.onMatchOrderChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meu perfil'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: const BoxDecoration(
                    color: Color(0xFF18C96E),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person, color: Colors.black, size: 32),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Meu perfil', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                      SizedBox(height: 4),
                      Text('Personalize sua experiência no InfoFut', style: TextStyle(color: Colors.white54, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Text('Tamanho da fonte', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text(
            'Normal é o tamanho base; Grande aumenta 30% e Extra grande aumenta mais 30 pontos.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 14),
          _FontOption(
            title: 'Normal',
            subtitle: 'Tamanho padrão',
            scale: 1.0,
            selected: selectedScale < 1.075,
            onTap: () => _selectFont(1.0),
          ),
          const SizedBox(height: 8),
          _FontOption(
            title: 'Grande',
            subtitle: 'Mais 30% sobre o tamanho normal',
            scale: 1.30,
            selected: selectedScale >= 1.15 && selectedScale < 1.45,
            onTap: () => _selectFont(1.30),
          ),
          const SizedBox(height: 8),
          _FontOption(
            title: 'Extra grande',
            subtitle: 'Mais 30 pontos sobre Grande',
            scale: 1.60,
            selected: selectedScale >= 1.45,
            onTap: () => _selectFont(1.60),
          ),
          const SizedBox(height: 24),
          const Text('Ordem Jogos', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text(
            'Escolha como os jogos serão organizados nas listas.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 12),
          _OrderOption(
            title: 'Hora/Jogo',
            subtitle: 'Organiza pela hora de início da partida',
            selected: selectedMatchOrder == 'time',
            onTap: () => _selectMatchOrder('time'),
          ),
          const SizedBox(height: 8),
          _OrderOption(
            title: 'Nome da liga',
            subtitle: 'Organiza pelo nome da competição',
            selected: selectedMatchOrder == 'league',
            onTap: () => _selectMatchOrder('league'),
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(
              'Tamanho atual: ${_fontLabel(selectedScale)}',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _FontOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final double scale;
  final bool selected;
  final VoidCallback onTap;

  const _FontOption({
    required this.title,
    required this.subtitle,
    required this.scale,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF102B35) : const Color(0xFF0C1C24),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFF18C96E) : Colors.white10,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? const Color(0xFF18C96E) : Colors.white38,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 18 * scale, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: TextStyle(color: Colors.white54, fontSize: 12 * scale)),
                ],
              ),
            ),
            Text(
              'Aa',
              style: TextStyle(fontSize: 15 * scale, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _OrderOption({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF102B35) : const Color(0xFF0C1C24),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFF18C96E) : Colors.white10,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? const Color(0xFF18C96E) : Colors.white38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeMenuOption extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeMenuOption({
    required this.title,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      trailing: selected ? const Icon(Icons.check, color: Color(0xFF18C96E)) : null,
      onTap: onTap,
    );
  }
}

// ============================================================
// APP
// ============================================================

class InfoFutApp extends StatefulWidget {
  const InfoFutApp({super.key});

  @override
  State<InfoFutApp> createState() => _InfoFutAppState();
}

class _InfoFutAppState extends State<InfoFutApp> {
  ThemeMode themeMode = ThemeMode.system;

  void _setThemeMode(ThemeMode mode) {
    setState(() => themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    final darkTheme = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF07130E),
      cardColor: const Color(0xFF10231A),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF18C96E),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );

    final lightTheme = ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF7F7F7),
      cardColor: Colors.white,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF18C96E),
        brightness: Brightness.light,
        surface: Colors.white,
      ),
      useMaterial3: true,
    );

    return MaterialApp(
      title: 'InfoFut',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: lightTheme,
      darkTheme: darkTheme,
      home: MainPage(
        themeMode: themeMode,
        onThemeModeChanged: _setThemeMode,
      ),
    );
  }
}

// ============================================================
// MAIN PAGE
// ============================================================

class MainPage extends StatefulWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  const MainPage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  State<MainPage> createState() =>
      _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final KickoffApiService api =
      KickoffApiService();
  final EspnFallbackService fallbackApi =
      EspnFallbackService();

  Timer? _timer;

  int currentIndex = 0;
  int selectedGoals = 0;
  // Filtros opcionais por minuto do gol. O usuário digita os minutos.
  int? goalBeforeMinute;
  int? goalAfterMinute;
  bool showResultsMenu = false;
  String filterType = 'goals';
  String filterStatus = 'ongoing';
  final Set<String> resultOutcomes = <String>{};
  DateTime? filterStartDate;
  DateTime? filterEndDate;
  double fontScale = 1.08;
  String matchOrder = 'time';

  DateTime selectedDate =
      DateTime.now();

  List<LiveMatch> liveMatches = [];
  List<LiveMatch> todayMatches = [];

  Set<int> favorites = {};
  Set<int> favoriteMatches = {};
  Set<String> favoriteLeagues = {};

  bool loading = true;
  bool refreshing = false;

  String? error;
  String liveDiagnostic = '';

  DateTime? lastUpdate;

  @override
  void initState() {
    super.initState();

    _loadFavorites();
    _loadFontScale();
    _loadMatchOrder();
    _loadThemeMode();
    _loadData();

    // O plano Hobby tem 100 chamadas/dia.
    // Atualizamos silenciosamente a cada 10 minutos e, durante o refresh
    // silencioso, consultamos apenas os jogos ao vivo.
    _timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => _loadData(silent: true),
    );
  }

  Future<void> _openFilterSheet() async {
    final result = await showModalBottomSheet<_FilterSheetResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(.28),
      builder: (sheetContext) => _FilterBottomSheet(
        filterType: filterType,
        statusFilter: filterStatus,
        selectedGoals: selectedGoals,
        goalBeforeMinute: goalBeforeMinute,
        goalAfterMinute: goalAfterMinute,
        outcomeFilters: resultOutcomes,
        startDate: filterStartDate,
        endDate: filterEndDate,
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      filterType = result.filterType;
      filterStatus = result.statusFilter;
      selectedGoals = result.selectedGoals;
      goalBeforeMinute = result.goalBeforeMinute;
      goalAfterMinute = result.goalAfterMinute;
      resultOutcomes
        ..clear()
        ..addAll(result.outcomeFilters);
      filterStartDate = result.startDate;
      filterEndDate = result.endDate;
      currentIndex = 3;
    });

    // Ao aplicar um período, buscamos os jogos de cada dia via ESPN para
    // complementar o cache/KickoffAPI. Isso garante que partidas encerradas
    // (inclusive 0x0) apareçam mesmo quando o cache do dia estava incompleto.
    await _loadFilterPeriodData(result.startDate, result.endDate);
  }

  Future<void> _loadFilterPeriodData(DateTime? start, DateTime? end) async {
    final first = start ?? end ?? selectedDate;
    final last = end ?? start ?? first;
    DateTime cursor = DateTime(first.year, first.month, first.day);
    final limit = DateTime(last.year, last.month, last.day);
    final byId = <int, LiveMatch>{
      for (final m in todayMatches) m.id: m,
    };

    // Mantém o custo controlado: o filtro usa a fonte alternativa sem
    // consumir a cota diária da KickoffAPI.
    while (!cursor.isAfter(limit)) {
      try {
        final raw = await fallbackApi.getMatchesForDate(cursor);
        for (final item in raw) {
          final match = _parseLiveMatch(item);
          if (match.id != 0) byId[match.id] = match;
        }
      } catch (_) {}
      cursor = cursor.add(const Duration(days: 1));
    }

    final merged = byId.values.toList()..sort(_sortMatches);
    if (!mounted) return;
    setState(() => todayMatches = merged);
  }

  @override
  void dispose() {
    _timer?.cancel();

    super.dispose();
  }

  Future<void> _loadFontScale() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getDouble('font_scale') ?? 1.08;
    if (!mounted) return;
    setState(() {
      fontScale = saved.clamp(1.08, 1.60).toDouble();
    });
  }

  Future<void> _setFontScale(double value) async {
    final normalized = value.clamp(1.08, 1.60).toDouble();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('font_scale', normalized);
    if (!mounted) return;
    setState(() => fontScale = normalized);
  }

  Future<void> _loadMatchOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('match_order') ?? 'time';
    if (!mounted) return;
    setState(() {
      matchOrder = saved == 'league' ? 'league' : 'time';
    });
  }

  Future<void> _setMatchOrder(String value) async {
    final normalized = value == 'league' ? 'league' : 'time';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('match_order', normalized);
    if (!mounted) return;
    setState(() => matchOrder = normalized);
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('theme_mode') ?? 'system';
    final mode = saved == 'light'
        ? ThemeMode.light
        : saved == 'dark'
            ? ThemeMode.dark
            : ThemeMode.system;
    if (!mounted) return;
    widget.onThemeModeChanged(mode);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    final value = mode == ThemeMode.light
        ? 'light'
        : mode == ThemeMode.dark
            ? 'dark'
            : 'system';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', value);
    if (!mounted) return;
    widget.onThemeModeChanged(mode);
  }

  void _openMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final current = widget.themeMode;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: SizedBox(width: 38, child: Divider(thickness: 3))),
                const SizedBox(height: 8),
                const Text('Menu', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                const SizedBox(height: 16),
                const Text('Tema', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                _ThemeMenuOption(
                  title: 'Padrão Sistema',
                  icon: Icons.brightness_auto_outlined,
                  selected: current == ThemeMode.system,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _setThemeMode(ThemeMode.system);
                  },
                ),
                _ThemeMenuOption(
                  title: 'Claro',
                  icon: Icons.light_mode_outlined,
                  selected: current == ThemeMode.light,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _setThemeMode(ThemeMode.light);
                  },
                ),
                _ThemeMenuOption(
                  title: 'Escuro',
                  icon: Icons.dark_mode_outlined,
                  selected: current == ThemeMode.dark,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _setThemeMode(ThemeMode.dark);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openLiveFromNotification() {
    setState(() {
      currentIndex = 1;
      showResultsMenu = false;
      showResultsMenu = false;
    });

    if (favoriteLeagues.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Ao vivo: ${favoriteLeagues.length} liga(s) favorita(s) em primeiro lugar.',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _openProfile() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) {
        final dark = Theme.of(sheetContext).brightness == Brightness.dark;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 42, child: Divider(thickness: 3)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: const Color(0xFF18C96E),
                      child: Icon(Icons.person, color: dark ? Colors.black : Colors.white),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Meu perfil',
                        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _ProfileMenuItem(
                  icon: Icons.person_outline,
                  title: 'Minha Conta',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Future.delayed(Duration.zero, _openProfilePage);
                  },
                ),
                _ProfileMenuItem(
                  icon: Icons.settings_outlined,
                  title: 'Configurações',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Future.delayed(Duration.zero, _openProfilePage);
                  },
                ),
                _ProfileMenuItem(
                  icon: Icons.notifications_none,
                  title: 'Notificações',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openLiveFromNotification();
                  },
                ),
                const Divider(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                    child: Text(
                      'Tema',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(child: _ThemeQuickOption(title: 'Claro', icon: Icons.light_mode_outlined, selected: widget.themeMode == ThemeMode.light, onTap: () { Navigator.pop(sheetContext); _setThemeMode(ThemeMode.light); })),
                    const SizedBox(width: 8),
                    Expanded(child: _ThemeQuickOption(title: 'Escuro', icon: Icons.dark_mode_outlined, selected: widget.themeMode == ThemeMode.dark, onTap: () { Navigator.pop(sheetContext); _setThemeMode(ThemeMode.dark); })),
                  ],
                ),
                const SizedBox(height: 8),
                _ProfileMenuItem(
                  icon: Icons.logout,
                  title: 'Sair',
                  danger: true,
                  onTap: () => Navigator.pop(sheetContext),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openProfilePage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProfilePage(
          currentFontScale: fontScale,
          onFontScaleChanged: _setFontScale,
          currentMatchOrder: matchOrder,
          onMatchOrderChanged: _setMatchOrder,
        ),
      ),
    );
  }

  Future<void> _loadFavorites() async {
    final prefs =
        await SharedPreferences.getInstance();

    final values =
        prefs.getStringList('favorite_teams') ??
            [];
    final leagues =
        prefs.getStringList('favorite_leagues') ??
            [];
    final matchValues =
        prefs.getStringList('favorite_matches') ??
            [];

    if (!mounted) return;

    setState(() {
      favorites = values
          .map(int.tryParse)
          .whereType<int>()
          .toSet();
      favoriteLeagues = leagues
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      favoriteMatches = matchValues
          .map(int.tryParse)
          .whereType<int>()
          .toSet();
    });
  }

  Future<void> _toggleFavorite(
    int teamId,
  ) async {
    if (teamId == 0) return;

    final prefs =
        await SharedPreferences.getInstance();

    final updated =
        Set<int>.from(favorites);

    if (updated.contains(teamId)) {
      updated.remove(teamId);
    } else {
      updated.add(teamId);
    }

    await prefs.setStringList(
      'favorite_teams',
      updated
          .map((e) => e.toString())
          .toList(),
    );

    if (!mounted) return;

    setState(() {
      favorites = updated;
    });
  }

  Future<void> _toggleFavoriteMatch(int matchId) async {
    if (matchId == 0) return;

    final prefs = await SharedPreferences.getInstance();
    final updated = Set<int>.from(favoriteMatches);

    if (updated.contains(matchId)) {
      updated.remove(matchId);
    } else {
      updated.add(matchId);
    }

    await prefs.setStringList(
      'favorite_matches',
      updated.map((e) => e.toString()).toList(),
    );

    if (!mounted) return;
    setState(() => favoriteMatches = updated);
  }

  Future<void> _toggleFavoriteLeague(String league) async {
    final name = league.trim();
    if (name.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final updated = Set<String>.from(favoriteLeagues);

    if (updated.contains(name)) {
      updated.remove(name);
    } else {
      updated.add(name);
    }

    await prefs.setStringList(
      'favorite_leagues',
      updated.toList(),
    );

    if (!mounted) return;
    setState(() => favoriteLeagues = updated);
  }

  Future<void> _loadData({
    bool silent = false,
  }) async {
    if (!silent) {
      setState(() {
        loading = true;
        error = null;
      });
    } else if (mounted) {
      setState(() {
        refreshing = true;
      });
    }

    final now = DateTime.now();
    final selectedIsToday =
        selectedDate.year == now.year &&
        selectedDate.month == now.month &&
        selectedDate.day == now.day;

    // Mantemos os dados atuais durante a atualização silenciosa.
    // Assim o app nunca fica vazio só porque uma chamada demorou/falhou.
    List<LiveMatch> previous = List<LiveMatch>.from(todayMatches);
    List<dynamic> dateRaw = [];
    List<dynamic> liveRaw = [];
    Object? dateError;
    Object? liveError;
    String liveSource = 'nenhuma';
    int kickoffLiveCount = 0;
    int espnLiveCount = 0;

    // 1) Primeiro tenta usar cache do dia. Isso reduz bastante o consumo
    // do plano gratuito e permite continuar mostrando os últimos dados.
    dateRaw = await _readCachedRawList(_dateCacheKey(selectedDate));
    final hasDateCache = dateRaw.isNotEmpty;
    final shouldFetchDate = !hasDateCache && (!silent || !selectedIsToday || previous.isEmpty);
    if (shouldFetchDate) {
      try {
        dateRaw = await api.getMatchesForDate(selectedDate);
        if (dateRaw.isNotEmpty) {
          await _saveCachedRawList(_dateCacheKey(selectedDate), dateRaw);
        }
      } catch (e) {
        dateError = e;
        // Fallback automático: quando a KickoffAPI estiver indisponível ou
        // com limite 429, tenta uma fonte alternativa sem consumir a chave.
        final fallbackData = await fallbackApi.getMatchesForDate(selectedDate);
        if (fallbackData.isNotEmpty) {
          dateRaw = fallbackData;
          await _saveCachedRawList(_dateCacheKey(selectedDate), dateRaw);
          dateError = null;
        }
      }
    }

    // 2) AO VIVO: ESPN primeiro. KickoffAPI apenas como segunda fonte.
    // Assim o Ao Vivo continua funcionando mesmo quando a KickoffAPI estiver em 429.
    if (selectedIsToday) {
      List<dynamic> espnLive = [];

      try {
        espnLive = await fallbackApi.getLivescores();
        espnLiveCount = espnLive.length;
        final parsed = espnLive
            .map(_parseLiveMatch)
            .where((m) => m.id != 0 && m.isLive)
            .toList();
        if (parsed.isNotEmpty) {
          liveRaw = espnLive;
          liveSource = 'ESPN';
          liveError = null;
          await _saveCachedRawList('kickoff_live_cache', liveRaw);
        }
      } catch (e) {
        liveError = e;
      }

      if (liveRaw.isEmpty) {
        try {
          final kickoffLive = await api.getLivescores();
          kickoffLiveCount = kickoffLive.length;
          final parsed = kickoffLive
              .map(_parseLiveMatch)
              .where((m) => m.id != 0 && m.isLive)
              .toList();
          if (parsed.isNotEmpty) {
            liveRaw = kickoffLive;
            liveSource = 'KickoffAPI';
            liveError = null;
            await _saveCachedRawList('kickoff_live_cache', liveRaw);
          }
        } catch (e) {
          liveError = e;
        }
      }

      if (liveRaw.isEmpty) {
        try {
          final cached = await _readCachedRawList('kickoff_live_cache');
          final useful = cached
              .map(_parseLiveMatch)
              .where((m) => m.id != 0 && m.isLive)
              .toList();
          if (useful.isNotEmpty) {
            liveRaw = cached;
            liveSource = 'Cache';
          }
        } catch (_) {}
      }

      if (liveRaw.isEmpty) {
        try {
          final today = await fallbackApi.getMatchesForDate(DateTime.now());
          final liveToday = today
              .map(_parseLiveMatch)
              .where((m) => m.id != 0 && m.isLive)
              .toList();
          if (liveToday.isNotEmpty) {
            liveRaw = today;
            liveSource = 'ESPN hoje';
            liveError = null;
            await _saveCachedRawList('kickoff_live_cache', liveRaw);
          }
        } catch (_) {}
      }
    }

    final byId = <int, LiveMatch>{};

    // Mantém os jogos que já estavam na tela durante refresh silencioso.
    if (silent && selectedIsToday && previous.isNotEmpty) {
      for (final match in previous) {
        byId[match.id] = match;
      }
    }

    for (final raw in dateRaw) {
      final match = _parseLiveMatch(raw);
      if (match.id != 0) {
        byId[match.id] = match;
      }
    }

    // Monta o Ao Vivo a partir de DUAS fontes: endpoint live e também
    // os jogos de hoje já carregados. Isso é importante quando a KickoffAPI
    // está em 429 ou quando o endpoint live não responde, mas o cache/placar
    // do dia ainda contém partidas em andamento.
    final liveFromEndpoint = liveRaw
        .map(_parseLiveMatch)
        .where((m) => m.id != 0 && m.isLive)
        .toList();

    final liveFromToday = dateRaw
        .map(_parseLiveMatch)
        .where((m) => m.id != 0 && m.isLive)
        .toList();

    final liveById = <int, LiveMatch>{};
    for (final match in liveFromEndpoint) {
      liveById[match.id] = match;
    }
    for (final match in liveFromToday) {
      liveById[match.id] = match;
    }

    final live = liveById.values.toList();

    if (selectedIsToday) {
      for (final match in live) {
        byId[match.id] = match;
      }
    }

    // Se uma atualização silenciosa falhar completamente, preservamos a tela.
    final combined = byId.values.toList();
    if (combined.isEmpty && silent && previous.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        liveMatches = live;
        todayMatches = previous;
        loading = false;
        refreshing = false;
        lastUpdate = DateTime.now();
      });
      return;
    }

    combined.sort(_sortMatches);

    // Só exibimos erro se realmente não conseguimos obter nenhum jogo.
    if (combined.isEmpty && dateError != null) {
      if (!mounted) return;
      setState(() {
        loading = false;
        refreshing = false;
        error = _isRateLimitError(dateError)
            ? 'Não foi possível atualizar os jogos agora. A KickoffAPI atingiu o limite diário e não havia dados alternativos disponíveis.'
            : 'Falha ao consultar a KickoffAPI:\n$dateError';
      });
      return;
    }

    if (!mounted) return;

    setState(() {
      liveMatches = live;
      todayMatches = combined;
      loading = false;
      refreshing = false;
      error = (liveError != null && selectedIsToday)
          ? (_isRateLimitError(liveError)
              ? 'Limite diário da KickoffAPI atingido (429). Mostrando os últimos dados disponíveis em cache.'
              : 'Jogos do dia carregados, mas o ao vivo falhou:\n$liveError')
          : null;
      lastUpdate = DateTime.now();
    });
  }


  String _dateCacheKey(DateTime date) =>
      'kickoff_date_${date.year}_${date.month}_${date.day}';

  Future<void> _saveCachedRawList(String key, List<dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'data': data,
      }));
    } catch (_) {}
  }

  Future<List<dynamic>> _readCachedRawList(
    String key, {
    Duration? maxAge,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return [];
      final savedAt = decoded['savedAt'];
      if (maxAge != null && savedAt is num) {
        final age = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(savedAt.toInt()),
        );
        if (age > maxAge) return [];
      }
      final data = decoded['data'];
      return data is List ? List<dynamic>.from(data) : [];
    } catch (_) {
      return [];
    }
  }

  bool _isRateLimitError(Object? value) =>
      value is KickoffApiException && value.isRateLimited;

  int _sortMatches(
    LiveMatch a,
    LiveMatch b,
  ) {
    if (a.isLive && !b.isLive) {
      return -1;
    }

    if (!a.isLive && b.isLive) {
      return 1;
    }

    if (a.isFinished && !b.isFinished) {
      return 1;
    }

    if (!a.isFinished && b.isFinished) {
      return -1;
    }

    final aTime =
        a.startTime?.millisecondsSinceEpoch ??
            0;

    final bTime =
        b.startTime?.millisecondsSinceEpoch ??
            0;

    return aTime.compareTo(bTime);
  }

  void _changeDate(int days) {
    setState(() {
      selectedDate =
          selectedDate.add(
        Duration(days: days),
      );
    });

    _loadData();
  }

  bool get isToday {
    final now = DateTime.now();

    return selectedDate.year == now.year &&
        selectedDate.month == now.month &&
        selectedDate.day == now.day;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: TextScaler.linear(fontScale),
      ),
      child: Scaffold(
        body: Stack(
        children: [
          IndexedStack(
            index: currentIndex,
            children: [
              HomePage(
                matches: todayMatches,
                liveMatches: liveMatches,
                favorites: favorites,
                favoriteLeagues: favoriteLeagues,
                loading: loading,
                refreshing: refreshing,
                error: error,
                selectedDate: selectedDate,
                lastUpdate: lastUpdate,
                onRefresh: _loadData,
                onChangeDate: _changeDate,
                onToggleFavorite: _toggleFavorite,
                onToggleFavoriteLeague: _toggleFavoriteLeague,
                onOpenProfile: _openProfile,
                matchOrder: matchOrder,
                onOpenMatch: (match) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MatchDetailsPage(
                        match: match,
                        api: api,
                        favorites: favorites,
                        onToggleFavorite: _toggleFavorite,
                      ),
                    ),
                  );
                },
              ),
              LivePage(
                matches: liveMatches,
                liveDiagnostic: liveDiagnostic,
                favorites: favorites,
                favoriteMatches: favoriteMatches,
                favoriteLeagues: favoriteLeagues,
                onToggleFavoriteLeague: _toggleFavoriteLeague,
                onToggleFavorite: _toggleFavorite,
                onToggleFavoriteMatch: _toggleFavoriteMatch,
                onOpenProfile: _openProfile,
                onOpenMenu: _openMenu,
                matchOrder: matchOrder,
                onOpenLeague: (league, matches) {
                  final reference = matches.isNotEmpty ? matches.first : null;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LeagueDetailsPage(
                        api: api,
                        leagueName: league,
                        country: reference?.country ?? 'Internacional',
                        leagueId: reference?.leagueApiId ?? '',
                        leagueLogo: reference?.leagueLogo,
                        season: reference?.leagueSeason,
                        initialMatches: matches,
                      ),
                    ),
                  );
                },
                onOpenMatch: (match) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MatchDetailsPage(
                        match: match,
                        api: api,
                        favorites: favorites,
                        onToggleFavorite: _toggleFavorite,
                      ),
                    ),
                  );
                },
              ),
              FavoritesPage(
                matches: todayMatches,
                favorites: favorites,
                favoriteMatches: favoriteMatches,
                onToggleFavorite: _toggleFavorite,
                onToggleFavoriteMatch: _toggleFavoriteMatch,
                onOpenMatch: (match) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MatchDetailsPage(
                        match: match,
                        api: api,
                        favorites: favorites,
                        onToggleFavorite: _toggleFavorite,
                      ),
                    ),
                  );
                },
              ),
              ResultsPage(
                matches: todayMatches,
                filterType: filterType,
                statusFilter: filterStatus,
                selectedGoals: selectedGoals,
                goalBeforeMinute: goalBeforeMinute,
                goalAfterMinute: goalAfterMinute,
                outcomeFilters: resultOutcomes,
                startDate: filterStartDate,
                endDate: filterEndDate,
                favoriteLeagues: favoriteLeagues,
                onOpenMatch: (match) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MatchDetailsPage(
                        match: match,
                        api: api,
                        favorites: favorites,
                        onToggleFavorite: _toggleFavorite,
                      ),
                    ),
                  );
                },
              ),
              CompetitionsPage(
                matches: todayMatches,
                favoriteLeagues: favoriteLeagues,
                onToggleFavoriteLeague: _toggleFavoriteLeague,
                onOpenMatch: (match) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MatchDetailsPage(
                        match: match,
                        api: api,
                        favorites: favorites,
                        onToggleFavorite: _toggleFavorite,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),

          // O filtro abre como uma folha inferior, sem ficar sobre o centro dos jogos.
          // A própria folha é semi-transparente para manter o contexto da tela ao fundo.
        ],
      ),
      bottomNavigationBar: NavigationBar(
        height: 68,
        selectedIndex: currentIndex,
        onDestinationSelected: (index) {
          if (index == 3) {
            setState(() {
              currentIndex = 3;
              showResultsMenu = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _openFilterSheet();
            });
            return;
          }

          setState(() {
            currentIndex = index;
            showResultsMenu = false;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_soccer_outlined),
            selectedIcon: Icon(Icons.sports_soccer),
            label: 'Ao vivo',
          ),
          NavigationDestination(
            icon: Icon(Icons.star_border),
            selectedIcon: Icon(Icons.star),
            label: 'Favoritos',
          ),
          NavigationDestination(
            icon: Icon(Icons.filter_alt_outlined),
            selectedIcon: Icon(Icons.filter_alt),
            label: 'Filtro',
          ),
          NavigationDestination(
            icon: Icon(Icons.emoji_events_outlined),
            selectedIcon: Icon(Icons.emoji_events),
            label: 'Ligas',
          ),
        ],
      ),
      ),
    );
  }
}

// ============================================================
// HOME
// ============================================================

class HomePage extends StatefulWidget {
  final List<LiveMatch> matches;
  final List<LiveMatch> liveMatches;
  final Set<int> favorites;
  final Set<String> favoriteLeagues;
  final bool loading;
  final bool refreshing;
  final String? error;
  final DateTime selectedDate;
  final DateTime? lastUpdate;

  final Future<void> Function({bool silent}) onRefresh;
  final void Function(int days) onChangeDate;
  final Future<void> Function(int teamId) onToggleFavorite;
  final Future<void> Function(String league) onToggleFavoriteLeague;
  final void Function(LiveMatch match) onOpenMatch;
  final VoidCallback? onOpenProfile;
  final String matchOrder;

  const HomePage({
    super.key,
    required this.matches,
    required this.liveMatches,
    required this.favorites,
    required this.favoriteLeagues,
    required this.loading,
    required this.refreshing,
    required this.error,
    required this.selectedDate,
    required this.lastUpdate,
    required this.onRefresh,
    required this.onChangeDate,
    required this.onToggleFavorite,
    required this.onToggleFavoriteLeague,
    required this.onOpenMatch,
    this.onOpenProfile,
    this.matchOrder = 'time',
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final EspnFallbackService fallbackApi = EspnFallbackService();
  final TextEditingController search = TextEditingController();
  String query = '';
  String filter = 'Todos';
  bool showSearch = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<LiveMatch> get filtered {
    Iterable<LiveMatch> result = widget.matches;
    final q = query.trim().toLowerCase();

    if (q.isNotEmpty) {
      result = result.where((m) =>
          m.home.name.toLowerCase().contains(q) ||
          m.away.name.toLowerCase().contains(q) ||
          m.league.toLowerCase().contains(q));
    }

    if (filter == 'Ao vivo') {
      result = result.where((m) => m.isLive);
    } else if (filter == 'Próximos') {
      result = result.where((m) => m.isScheduled);
    } else if (filter == 'Encerrados') {
      result = result.where((m) => m.isFinished);
    } else if (filter == 'Favoritos') {
      result = result.where((m) =>
          widget.favorites.contains(m.home.id) ||
          widget.favorites.contains(m.away.id) ||
          widget.favoriteLeagues.contains(m.league));
    }

    final list = result.toList();
    list.sort((a, b) {
      if (widget.matchOrder == 'league') {
        final league = a.league.toLowerCase().compareTo(b.league.toLowerCase());
        if (league != 0) return league;
      }
      if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
      if (a.isFinished != b.isFinished) return a.isFinished ? 1 : -1;
      return (a.startTime?.millisecondsSinceEpoch ?? 0)
          .compareTo(b.startTime?.millisecondsSinceEpoch ?? 0);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () => widget.onRefresh(silent: false),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _buildTopBar()),
            if (showSearch) SliverToBoxAdapter(child: _buildSearch()),
            SliverToBoxAdapter(child: _buildDateSelector()),
            SliverToBoxAdapter(child: _buildOfferBanner()),
            SliverToBoxAdapter(child: _buildAllGamesHeader()),
            if (widget.error != null)
              SliverToBoxAdapter(child: _buildError()),
            if (widget.favoriteLeagues.isNotEmpty)
              SliverToBoxAdapter(child: _buildFavoriteCompetitions()),
            if (widget.liveMatches.isNotEmpty)
              SliverToBoxAdapter(child: _buildLiveStrip()),
            if (widget.loading && filtered.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (filtered.isEmpty)
              SliverToBoxAdapter(child: _buildEmpty())
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final grouped = <String, Map<String, List<LiveMatch>>>{};
                    for (final match in filtered) {
                      grouped.putIfAbsent(match.country, () => {});
                      grouped[match.country]!
                          .putIfAbsent(match.league, () => [])
                          .add(match);
                    }
                    final countries = grouped.keys.toList();
                    final country = countries[index];
                    return _CountryBlock(
                      country: country,
                      leagues: grouped[country]!,
                      favorites: widget.favorites,
                      favoriteLeagues: widget.favoriteLeagues,
                      onToggleFavorite: widget.onToggleFavorite,
                      onToggleFavoriteLeague: widget.onToggleFavoriteLeague,
                      onOpenMatch: widget.onOpenMatch,
                    );
                  },
                  childCount: _countriesCount(),
                ),
              ),
            SliverToBoxAdapter(child: _buildLastUpdate()),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  int _countriesCount() {
    return filtered.map((m) => m.country.trim().isEmpty ? 'Internacional' : m.country)
        .toSet().length;
  }

  Widget _buildTopBar() {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface),
      child: Row(
        children: [
          Icon(Icons.sports_soccer, color: Theme.of(context).colorScheme.primary, size: 27),
          const SizedBox(width: 8),
          const Text('Futebol', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
          const SizedBox(width: 4),
          const Icon(Icons.keyboard_arrow_down, size: 19),
          const Spacer(),
          IconButton(
            tooltip: 'Buscar',
            onPressed: () => setState(() => showSearch = !showSearch),
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: 'Atualizar',
            onPressed: widget.refreshing ? null : () => widget.onRefresh(silent: false),
            icon: widget.refreshing
                ? const SizedBox(width: 19, height: 19, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Meu perfil',
            onPressed: widget.onOpenProfile,
            icon: const Icon(Icons.account_circle_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
      child: TextField(
        controller: search,
        autofocus: true,
        onChanged: (v) => setState(() => query = v),
        decoration: InputDecoration(
          hintText: 'Buscar time ou competição',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: query.isEmpty ? null : IconButton(
            onPressed: () { search.clear(); setState(() => query = ''); },
            icon: const Icon(Icons.clear),
          ),
          filled: true,
          fillColor: const Color(0xFF10232D),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }

  Widget _buildDateSelector() {
    final now = DateTime.now();
    final base = DateTime(now.year, now.month, now.day);
    final days = List.generate(7, (i) => base.add(Duration(days: i - 2)));
    const week = ['SEG', 'TER', 'QUA', 'QUI', 'SEX', 'SÁB', 'DOM'];

    return Container(
      height: 76,
      color: const Color(0xFF07151D),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
        scrollDirection: Axis.horizontal,
        itemCount: days.length,
        separatorBuilder: (_, __) => const SizedBox(width: 3),
        itemBuilder: (_, i) {
          final day = days[i];
          final selected = day.year == widget.selectedDate.year &&
              day.month == widget.selectedDate.month &&
              day.day == widget.selectedDate.day;
          final diff = day.difference(base).inDays;
          final title = diff == 0 ? 'HOJE' : diff == -1 ? 'ONTEM' : diff == 1 ? 'AMANHÃ' : week[day.weekday - 1];
          return GestureDetector(
            onTap: () {
              final current = DateTime(widget.selectedDate.year, widget.selectedDate.month, widget.selectedDate.day);
              final delta = day.difference(current).inDays;
              if (delta != 0) widget.onChangeDate(delta);
            },
            child: Container(
              width: selected ? 58 : 54,
              height: 60,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF0D222C) : Colors.transparent,
                border: Border(bottom: BorderSide(color: selected ? Colors.red : Colors.transparent, width: 3)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: selected ? Colors.red : Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.',
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildOfferBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: const BoxDecoration(color: Color(0xFF0B252E)),
      child: Row(
        children: [
          const Icon(Icons.card_giftcard, color: Colors.white, size: 24),
          const SizedBox(width: 9),
          const Expanded(
            child: Text('Versão de odds e apostas +18', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          ),
          const Icon(Icons.chevron_right, color: Colors.white70),
        ],
      ),
    );
  }

  Widget _buildAllGamesHeader() {
    final liveCount = widget.liveMatches.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 9, 13, 9),
      color: const Color(0xFF061923),
      child: Row(
        children: [
          const Icon(Icons.format_list_bulleted, color: Colors.white70, size: 22),
          const SizedBox(width: 10),
          const Text('Todos os Jogos', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
          const Spacer(),
          if (liveCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(7)),
              child: Text('$liveCount', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
            ),
          const SizedBox(width: 9),
          Text('${filtered.length}', style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _buildFavoriteCompetitions() {
    final leagues = widget.favoriteLeagues.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(15, 9, 15, 5),
          child: Text('COMPETIÇÕES FAVORITAS', style: TextStyle(color: Color(0xFFFFD400), fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: .8)),
        ),
        ...leagues.map((league) {
          final leagueMatches = widget.matches.where((m) => m.league == league).toList();
          final live = leagueMatches.where((m) => m.isLive).length;
          final country = leagueMatches.isNotEmpty ? leagueMatches.first.country : 'Internacional';
          return InkWell(
            onTap: () => setState(() => filter = 'Favoritos'),
            child: Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white.withOpacity(.045)))),
              child: Row(
                children: [
                  const Icon(Icons.flag_outlined, size: 22, color: Colors.white70),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(country.toUpperCase(), style: const TextStyle(color: Colors.white54, fontSize: 11.5, fontWeight: FontWeight.w900)),
                        Text(league, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
                      ],
                    ),
                  ),
                  if (live > 0)
                    Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3), decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(5)), child: Text('$live', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900))),
                  const SizedBox(width: 8),
                  Text('${leagueMatches.length}', style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildLiveStrip() {
    final lives = widget.liveMatches;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(width: 7, height: 7, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            const Text('AO VIVO AGORA', style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w900)),
          ]),
          const SizedBox(height: 6),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: lives.length,
              separatorBuilder: (_, __) => const SizedBox(width: 4),
              itemBuilder: (_, i) => _LiveMiniCard(match: lives[i], favorite: false, onTap: () => widget.onOpenMatch(lives[i])),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.red.withOpacity(.08), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          const Icon(Icons.warning_amber, color: Colors.orange, size: 19),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.error!, style: const TextStyle(fontSize: 11))),
        ]),
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(children: [
        const Icon(Icons.sports_soccer, size: 48, color: Colors.white24),
        const SizedBox(height: 12),
        const Text('Nenhum jogo encontrado', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 5),
        Text(query.isNotEmpty || filter != 'Todos' ? 'Altere a busca ou o filtro.' : 'Não há partidas disponíveis para esta data.', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _buildLastUpdate() {
    if (widget.lastUpdate == null) return const SizedBox.shrink();
    return Center(child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('Atualizado às ${_formatTime(widget.lastUpdate!)}', style: const TextStyle(color: Colors.white30, fontSize: 11))));
  }
}

// ============================================================
// RESULTADOS
// ============================================================

class ResultsPage extends StatelessWidget {
  final List<LiveMatch> matches;
  final String filterType;
  final String statusFilter;
  final int selectedGoals;
  final int? goalBeforeMinute;
  final int? goalAfterMinute;
  final Set<String> outcomeFilters;
  final DateTime? startDate;
  final DateTime? endDate;
  final Set<String> favoriteLeagues;
  final void Function(LiveMatch match) onOpenMatch;

  const ResultsPage({
    super.key,
    required this.matches,
    required this.filterType,
    required this.statusFilter,
    required this.selectedGoals,
    required this.goalBeforeMinute,
    required this.goalAfterMinute,
    required this.outcomeFilters,
    required this.startDate,
    required this.endDate,
    required this.favoriteLeagues,
    required this.onOpenMatch,
  });

  bool _statusOk(LiveMatch m) {
    if (statusFilter == 'ongoing') return m.isLive;
    return m.isFinished;
  }

  int _totalGoals(LiveMatch m) {
    final h = m.homeScore;
    final a = m.awayScore;
    if (h == null || a == null) return -1;
    return h + a;
  }

  bool _goalOk(LiveMatch m) {
    final total = _totalGoals(m);
    if (total < 0) return false;
    final quantityOk = selectedGoals == 5
        ? total > 4
        : selectedGoals == 6
            ? total < 5
            : total == selectedGoals;
    if (!quantityOk) return false;

    if (goalBeforeMinute == null && goalAfterMinute == null) return true;

    final goals = m.events
        .where((e) => e.type.toLowerCase() == 'goal' && e.minute >= 0)
        .toList();

    // A lista de partidas de alguns provedores vem sem timeline/eventos.
    // Não descartamos o jogo inteiro por falta desses dados; assim os jogos
    // continuam aparecendo e os detalhes podem trazer a timeline depois.
    if (goals.isEmpty) return true;

    if (goalBeforeMinute != null &&
        !goals.any((e) => e.minute <= goalBeforeMinute!)) {
      return false;
    }
    if (goalAfterMinute != null &&
        !goals.any((e) => e.minute >= goalAfterMinute!)) {
      return false;
    }
    return true;
  }

  bool _outcomeOk(LiveMatch m) {
    if (outcomeFilters.isEmpty) return true;
    final h = m.homeScore ?? 0;
    final a = m.awayScore ?? 0;
    if (h > a && outcomeFilters.contains('home')) return true;
    if (h == a && outcomeFilters.contains('draw')) return true;
    if (a > h && outcomeFilters.contains('away')) return true;
    return false;
  }

  String _goalLabel(int value) {
    if (value == 5) return 'Mais de 4 gols';
    if (value == 6) return 'Menos de 5 gols';
    return '$value ${value == 1 ? 'gol' : 'gols'}';
  }

  String _statusLabel() => statusFilter == 'ongoing' ? 'Ao vivo' : 'Encerrados';

  bool _dateOk(LiveMatch m) {
    if (startDate == null && endDate == null) return true;
    final dt = m.startTime;
    if (dt == null) return false;
    final day = DateTime(dt.year, dt.month, dt.day);
    if (startDate != null && day.isBefore(DateTime(startDate!.year, startDate!.month, startDate!.day))) return false;
    if (endDate != null && day.isAfter(DateTime(endDate!.year, endDate!.month, endDate!.day))) return false;
    return true;
  }

  String _periodLabel() {
    if (startDate == null && endDate == null) return 'Todos os dias';
    String f(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
    if (startDate != null && endDate != null) return '${f(startDate!)} - ${f(endDate!)}';
    return f(startDate ?? endDate!);
  }

  @override
  Widget build(BuildContext context) {
    final list = matches.where((m) {
      if (!_statusOk(m)) return false;
      if (!_dateOk(m)) return false;
      return filterType == 'goals' ? _goalOk(m) : _outcomeOk(m);
    }).toList();

    bool isFavoriteLeague(LiveMatch m) => favoriteLeagues.any((name) => name.trim().toLowerCase() == m.league.trim().toLowerCase());

    list.sort((a, b) {
      final af = isFavoriteLeague(a);
      final bf = isFavoriteLeague(b);
      if (af != bf) return af ? -1 : 1;
      if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
      return (a.startTime?.millisecondsSinceEpoch ?? 0)
          .compareTo(b.startTime?.millisecondsSinceEpoch ?? 0);
    });

    final subtitle = filterType == 'goals'
        ? '${_statusLabel()} • ${_goalLabel(selectedGoals)}${goalBeforeMinute != null ? ' • Gol antes de $goalBeforeMinute min' : ''}${goalAfterMinute != null ? ' • Gol depois de $goalAfterMinute min' : ''} • ${_periodLabel()}'
        : '${_statusLabel()} • ${outcomeFilters.isEmpty ? 'Todos os resultados' : outcomeFilters.map((e) => e == 'home' ? 'Casa' : e == 'draw' ? 'Empate' : 'Fora').join(' + ')} • ${_periodLabel()}';

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
              child: Text(
                filterType == 'goals' ? 'Gols' : 'Placares',
                style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w900),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  const Icon(Icons.filter_alt, size: 15, color: Colors.red),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      subtitle,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${list.length}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
                  ),
                ],
              ),
            ),
          ),
          if (list.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    filterType == 'goals'
                        ? 'Nenhum jogo encontrado para este filtro de gols.'
                        : 'Nenhum jogo encontrado para este filtro de placares.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white60, fontSize: 16),
                  ),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final match = list[index];
                  return MatchCard(
                    compact: true,
                    match: match,
                    favorite: false,
                    onFavorite: () {},
                    onTap: () => onOpenMatch(match),
                  );
                },
                childCount: list.length,
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterSheetResult {
  final String filterType;
  final String statusFilter;
  final int selectedGoals;
  final int? goalBeforeMinute;
  final int? goalAfterMinute;
  final Set<String> outcomeFilters;
  final DateTime? startDate;
  final DateTime? endDate;

  const _FilterSheetResult({
    required this.filterType,
    required this.statusFilter,
    required this.selectedGoals,
    required this.goalBeforeMinute,
    required this.goalAfterMinute,
    required this.outcomeFilters,
    required this.startDate,
    required this.endDate,
  });
}

class _FilterBottomSheet extends StatefulWidget {
  final String filterType;
  final String statusFilter;
  final int selectedGoals;
  final int? goalBeforeMinute;
  final int? goalAfterMinute;
  final Set<String> outcomeFilters;
  final DateTime? startDate;
  final DateTime? endDate;

  const _FilterBottomSheet({
    required this.filterType,
    required this.statusFilter,
    required this.selectedGoals,
    required this.goalBeforeMinute,
    required this.goalAfterMinute,
    required this.outcomeFilters,
    required this.startDate,
    required this.endDate,
  });

  @override
  State<_FilterBottomSheet> createState() => _FilterBottomSheetState();
}

class _FilterBottomSheetState extends State<_FilterBottomSheet> {
  late String filterType;
  late String statusFilter;
  late int selectedGoals;
  int? goalBeforeMinute;
  int? goalAfterMinute;
  late Set<String> outcomeFilters;
  DateTime? startDate;
  DateTime? endDate;

  @override
  void initState() {
    super.initState();
    filterType = widget.filterType;
    statusFilter = widget.statusFilter;
    selectedGoals = widget.selectedGoals;
    goalBeforeMinute = widget.goalBeforeMinute;
    goalAfterMinute = widget.goalAfterMinute;
    outcomeFilters = {...widget.outcomeFilters};
    startDate = widget.startDate;
    endDate = widget.endDate;
  }

  String _dateText(DateTime? d) {
    if (d == null) return 'Selecionar';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  Future<void> _pickStart() async {
    final now = DateTime.now();
    final initial = startDate ?? endDate ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
      helpText: 'DATA INICIAL',
    );
    if (picked == null) return;
    setState(() {
      startDate = picked;
      if (endDate != null && endDate!.isBefore(picked)) endDate = picked;
    });
  }

  Future<void> _pickEnd() async {
    final now = DateTime.now();
    final initial = endDate ?? startDate ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
      helpText: 'DATA FINAL',
    );
    if (picked == null) return;
    setState(() {
      endDate = picked;
      if (startDate != null && startDate!.isAfter(picked)) startDate = picked;
    });
  }

  Widget _chip(String label, IconData icon, bool selected, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: selected ? const Color(0xFF18C96E) : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15, color: selected ? Colors.black : cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: selected ? Colors.black : cs.onSurface)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _option(String label, bool selected, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? Colors.red.withOpacity(.14) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(
            children: [
              Icon(selected ? Icons.check_box : Icons.check_box_outline_blank, size: 20, color: selected ? Colors.red : cs.onSurfaceVariant),
              const SizedBox(width: 9),
              Text(label, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w900 : FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _goalMinuteInput({
    required String label,
    required String hint,
    required int? value,
    required ValueChanged<int?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 5),
          TextFormField(
            initialValue: value?.toString() ?? '',
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              suffixText: 'min',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onChanged: (text) {
              final minute = int.tryParse(text.trim());
              onChanged(minute != null && minute >= 0 && minute <= 130 ? minute : null);
            },
          ),
        ],
      ),
    );
  }

  void _apply() {
    Navigator.pop(
      context,
      _FilterSheetResult(
        filterType: filterType,
        statusFilter: statusFilter,
        selectedGoals: selectedGoals,
        goalBeforeMinute: goalBeforeMinute,
        goalAfterMinute: goalAfterMinute,
        outcomeFilters: outcomeFilters,
        startDate: startDate,
        endDate: endDate,
      ),
    );
  }

  void _clear() {
    setState(() {
      filterType = 'goals';
      statusFilter = 'ongoing';
      selectedGoals = 0;
      goalBeforeMinute = null;
      goalAfterMinute = null;
      outcomeFilters.clear();
      startDate = null;
      endDate = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      top: false,
      child: Container(
        margin: EdgeInsets.only(top: 55, bottom: bottom),
        decoration: BoxDecoration(
          color: cs.surface.withOpacity(.96),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          border: Border.all(color: cs.outline.withOpacity(.18)),
          boxShadow: const [BoxShadow(blurRadius: 28, offset: Offset(0, -4), color: Colors.black54)],
        ),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: .72,
          minChildSize: .55,
          maxChildSize: .90,
          builder: (context, controller) => Column(
            children: [
              const SizedBox(height: 9),
              Container(width: 42, height: 4, decoration: BoxDecoration(color: cs.onSurfaceVariant.withOpacity(.55), borderRadius: BorderRadius.circular(20))),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    const Expanded(child: Text('FILTROS', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 20)),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                  children: [
                    const Text('PERÍODO', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Expanded(child: _dateBox('Data inicial', _dateText(startDate), _pickStart)),
                        const SizedBox(width: 8),
                        Expanded(child: _dateBox('Data final', _dateText(endDate), _pickEnd)),
                      ],
                    ),
                    if (startDate != null || endDate != null)
                      Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () => setState(() { startDate = null; endDate = null; }), icon: const Icon(Icons.clear, size: 15), label: const Text('Limpar período'))),
                    const SizedBox(height: 8),
                    const Text('STATUS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 7),
                    Row(children: [
                      _chip('Ao Vivo', Icons.circle, statusFilter == 'ongoing', () => setState(() => statusFilter = 'ongoing')),
                      const SizedBox(width: 8),
                      _chip('Encerrados', Icons.flag_outlined, statusFilter == 'finished', () => setState(() => statusFilter = 'finished')),
                    ]),
                    const SizedBox(height: 12),
                    const Text('TIPO', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 7),
                    Row(children: [
                      _chip('GOLS', Icons.sports_soccer, filterType == 'goals', () => setState(() => filterType = 'goals')),
                      const SizedBox(width: 8),
                      _chip('PLACARES', Icons.scoreboard_outlined, filterType == 'scores', () => setState(() => filterType = 'scores')),
                    ]),
                    const SizedBox(height: 10),
                    if (filterType == 'goals') ...[
                      const Text('QUANTIDADE DE GOLS', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 3),
                      for (final item in <List<dynamic>>[
                        [0, '0 Gols'], [1, '1 Gol'], [2, '2 Gols'], [3, '3 Gols'], [4, '4 Gols'], [5, 'Mais de 4 Gols'], [6, 'Menos de 5 Gols'],
                      ]) _option(item[1] as String, selectedGoals == item[0], () => setState(() { selectedGoals = item[0] as int; filterType = 'goals'; })),
                      const SizedBox(height: 12),
                      const Text('MOMENTO DO GOL', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 3),
                      _goalMinuteInput(
                        label: 'Gol antes de ____ min',
                        hint: 'Digite o minuto (ex.: 15)',
                        value: goalBeforeMinute,
                        onChanged: (minute) => setState(() => goalBeforeMinute = minute),
                      ),
                      _goalMinuteInput(
                        label: 'Gol depois de ____ min',
                        hint: 'Digite o minuto (ex.: 60)',
                        value: goalAfterMinute,
                        onChanged: (minute) => setState(() => goalAfterMinute = minute),
                      ),
                    ] else ...[
                      const Text('RESULTADO', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 3),
                      _option('VITÓRIA CASA', outcomeFilters.contains('home'), () => setState(() { outcomeFilters.contains('home') ? outcomeFilters.remove('home') : outcomeFilters.add('home'); })),
                      _option('EMPATE', outcomeFilters.contains('draw'), () => setState(() { outcomeFilters.contains('draw') ? outcomeFilters.remove('draw') : outcomeFilters.add('draw'); })),
                      _option('VITÓRIA FORA', outcomeFilters.contains('away'), () => setState(() { outcomeFilters.contains('away') ? outcomeFilters.remove('away') : outcomeFilters.add('away'); })),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                child: Row(children: [
                  Expanded(child: OutlinedButton(onPressed: _clear, child: const Text('LIMPAR'))),
                  const SizedBox(width: 9),
                  Expanded(flex: 2, child: FilledButton(onPressed: _apply, child: const Text('APLICAR FILTRO'))),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateBox(String title, String value, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          child: Row(children: [
            const Icon(Icons.calendar_month_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
            ])),
          ]),
        ),
      ),
    );
  }
}

class _PopoverArrowPainter extends CustomPainter {
  final Color color;
  final Color borderColor;

  const _PopoverArrowPainter({required this.color, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    // A seta fica sobre o centro da aba "Placares" (aprox. 70% da barra).
    final x = size.width * .70;
    final path = Path()
      ..moveTo(x - 7, 0)
      ..lineTo(x, size.height)
      ..lineTo(x + 7, 0)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _PopoverArrowPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.borderColor != borderColor;
}

// ============================================================
// NOTÍCIAS
// ============================================================

class NewsPage extends StatelessWidget {
  const NewsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 18, 16, 10),
              child: Text('Notícias', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900)),
            ),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              _NewsPlaceholderCard(icon: Icons.public, title: 'Notícias do futebol', subtitle: 'Em breve: notícias, transferências e destaques das principais ligas.'),
              _NewsPlaceholderCard(icon: Icons.trending_up, title: 'Mercado da bola', subtitle: 'Uma área exclusiva do InfoFut para acompanhar transferências.'),
              _NewsPlaceholderCard(icon: Icons.insights, title: 'Análises', subtitle: 'Estatísticas e análises dos jogos também chegarão aqui.'),
            ]),
          ),
        ],
      ),
    );
  }
}

class _NewsPlaceholderCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _NewsPlaceholderCard({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 5, 12, 7),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: const Color(0xFF10231A), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Container(width: 45, height: 45, decoration: BoxDecoration(color: const Color(0xFF18C96E).withOpacity(.15), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: const Color(0xFF18C96E))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ])),
      ]),
    );
  }
}

class _CountryBlock extends StatelessWidget {
  final String country;
  final Map<String, List<LiveMatch>> leagues;
  final Set<int> favorites;
  final Set<String> favoriteLeagues;
  final Future<void> Function(int teamId) onToggleFavorite;
  final Future<void> Function(String league) onToggleFavoriteLeague;
  final void Function(LiveMatch match) onOpenMatch;
  final String liveDiagnostic;

  const _CountryBlock({
    required this.country,
    required this.leagues,
    required this.favorites,
    required this.favoriteLeagues,
    required this.onToggleFavorite,
    required this.onToggleFavoriteLeague,
    required this.onOpenMatch,
    this.liveDiagnostic = '',
  });

  @override
  Widget build(BuildContext context) {
    final entries = leagues.entries.toList();
    entries.sort((a, b) => a.key.compareTo(b.key));

    return Container(
      margin: const EdgeInsets.fromLTRB(6, 8, 6, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 5),
            child: Row(
              children: [
                const Icon(Icons.public, size: 16, color: Colors.white54),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    country.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      letterSpacing: .9,
                      color: Colors.white70,
                    ),
                  ),
                ),
                Text(
                  '${entries.length} ligas',
                  style: const TextStyle(color: Colors.white30, fontSize: 11),
                ),
              ],
            ),
          ),
          ...entries.map(
            (entry) => _LeagueBlock(
              league: entry.key,
              matches: entry.value,
              liveDiagnostic: liveDiagnostic,
              favorites: favorites,
              favoriteLeagues: favoriteLeagues,
              onToggleFavorite: onToggleFavorite,
              onToggleFavoriteLeague: onToggleFavoriteLeague,
              onOpenMatch: onOpenMatch,
            ),
          ),
        ],
      ),
    );
  }
}

class _LeagueBlock extends StatelessWidget {
  final String league;
  final List<LiveMatch> matches;
  final String liveDiagnostic;
  final Set<int> favorites;
  final Set<String> favoriteLeagues;
  final Future<void> Function(int teamId) onToggleFavorite;
  final Future<void> Function(String league) onToggleFavoriteLeague;
  final void Function(LiveMatch match) onOpenMatch;

  const _LeagueBlock({
    required this.league,
    required this.matches,
    required this.liveDiagnostic,
    required this.favorites,
    required this.favoriteLeagues,
    required this.onToggleFavorite,
    required this.onToggleFavoriteLeague,
    required this.onOpenMatch,
  });

  @override
  Widget build(BuildContext context) {
    final liveCount = matches.where((m) => m.isLive).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1B13),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(.04)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF14261C),
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.emoji_events_outlined, size: 18, color: Color(0xFF18C96E)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    league,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                  ),
                ),
                if (liveCount > 0) ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 5),
                  Text('$liveCount ao vivo', style: const TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.bold)),
                ],
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  onPressed: () => onToggleFavoriteLeague(league),
                  icon: Icon(
                    favoriteLeagues.contains(league) ? Icons.star : Icons.star_border,
                    size: 19,
                    color: favoriteLeagues.contains(league) ? Colors.amber : Colors.white38,
                  ),
                ),
                const SizedBox(width: 2),
                Text('${matches.length}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          ...matches.map(
            (match) => _FlashMatchRow(
              match: match,
              favorite: favorites.contains(match.home.id) || favorites.contains(match.away.id),
              onFavorite: () {
                final teamId = favorites.contains(match.home.id) ? match.home.id : match.away.id;
                onToggleFavorite(teamId);
              },
              onTap: () => onOpenMatch(match),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveMiniCard extends StatelessWidget {
  final LiveMatch match;
  final bool favorite;
  final VoidCallback onTap;

  const _LiveMiniCard({
    required this.match,
    required this.favorite,
    required this.onTap,
  });

  List<int> _goalMinutesFor(TeamInfo team) {
    final minutes = <int>[];
    final name = team.name.trim().toLowerCase();
    for (final event in match.events) {
      if (event.type != 'goal' || event.minute <= 0) continue;
      final sameId = event.teamId != null && event.teamId == team.id;
      final sameName = event.team != null && event.team!.trim().toLowerCase() == name;
      if (sameId || sameName) minutes.add(event.minute);
    }
    minutes.sort();
    return minutes;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 270,
      child: Material(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.outlineVariant.withOpacity(.45)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 38,
                  child: Text(
                    match.minute != null ? "${match.minute}'" : 'LIVE',
                    style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _TeamLine(name: match.home.name, logo: match.home.logo, goalMinutes: _goalMinutesFor(match.home)),
                      const SizedBox(height: 4),
                      _TeamLine(name: match.away.name, logo: match.away.logo, goalMinutes: _goalMinutesFor(match.away)),
                    ],
                  ),
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${match.homeScore ?? 0}', style: TextStyle(color: match.isLive ? Colors.red : cs.onSurface, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text('${match.awayScore ?? 0}', style: TextStyle(color: match.isLive ? Colors.red : cs.onSurface, fontWeight: FontWeight.w900)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FlashMatchRow extends StatelessWidget {
  final LiveMatch match;
  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback? onMatchFavorite;
  final VoidCallback onTap;

  const _FlashMatchRow({
    required this.match,
    required this.favorite,
    required this.onFavorite,
    this.onMatchFavorite,
    required this.onTap,
  });

  List<int> _goalMinutesFor(TeamInfo team) {
    final teamName = team.name.trim().toLowerCase();
    final minutes = <int>[];

    for (final event in match.events) {
      if (event.type != 'goal' || event.minute <= 0) continue;

      final sameId = event.teamId != null && event.teamId == team.id;
      final sameName = event.team != null &&
          event.team!.trim().toLowerCase() == teamName;

      if (sameId || sameName) minutes.add(event.minute);
    }

    minutes.sort();
    return minutes;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white.withOpacity(.035))),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 43,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    match.isLive
                        ? (match.minute != null ? "${match.minute}'" : 'LIVE')
                        : match.isFinished
                            ? 'ENC'
                            : _formatTime(match.startTime!),
                    style: TextStyle(
                      color: match.isLive ? Colors.red : Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (match.isLive)
                    const Text('AO VIVO', style: TextStyle(color: Colors.red, fontSize: 9, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TeamLine(
                    name: match.home.name,
                    logo: match.home.logo,
                    goalMinutes: _goalMinutesFor(match.home),
                  ),
                  const SizedBox(height: 5),
                  _TeamLine(
                    name: match.away.name,
                    logo: match.away.logo,
                    goalMinutes: _goalMinutesFor(match.away),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 34,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    match.isScheduled ? '-' : '${match.homeScore ?? 0}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: match.isLive ? Colors.red : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    match.isScheduled ? '-' : '${match.awayScore ?? 0}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: match.isLive ? Colors.red : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              onPressed: onMatchFavorite ?? onFavorite,
              icon: Icon(
                favorite ? Icons.star : Icons.star_border,
                size: 20,
                color: favorite ? Colors.amber : Colors.white38,
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}

class _TeamLine extends StatelessWidget {
  final String name;
  final String? logo;
  final List<int> goalMinutes;

  const _TeamLine({
    required this.name,
    required this.logo,
    this.goalMinutes = const [],
  });

  @override
  Widget build(BuildContext context) {
    final goalText = goalMinutes.map((minute) => "⚽ ${minute}'").join('  ');

    return Row(
      children: [
        ClubShield(
          team: TeamInfo(id: 0, name: name, logo: logo),
          size: 19,
        ),
        const SizedBox(width: 7),
        Expanded(
          flex: 5,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        if (goalText.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            flex: 4,
            child: Text(
              goalText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ============================================================
// LIVE PAGE
// ============================================================

class LivePage extends StatefulWidget {
  final List<LiveMatch> matches;
  final String liveDiagnostic;
  final Set<int> favorites;
  final Set<int> favoriteMatches;
  final Set<String> favoriteLeagues;
  final Future<void> Function(int teamId) onToggleFavorite;
  final Future<void> Function(int matchId) onToggleFavoriteMatch;
  final Future<void> Function(String league) onToggleFavoriteLeague;
  final VoidCallback onOpenProfile;
  final VoidCallback onOpenMenu;
  final String matchOrder;
  final void Function(String league, List<LiveMatch> matches) onOpenLeague;
  final void Function(LiveMatch match) onOpenMatch;

  const LivePage({
    super.key,
    required this.matches,
    required this.liveDiagnostic,
    required this.favorites,
    required this.favoriteMatches,
    required this.favoriteLeagues,
    required this.onToggleFavorite,
    required this.onToggleFavoriteMatch,
    required this.onToggleFavoriteLeague,
    required this.onOpenProfile,
    required this.onOpenMenu,
    required this.matchOrder,
    required this.onOpenLeague,
    required this.onOpenMatch,
  });

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final Set<String> collapsedLeagues = {};

  Map<String, List<LiveMatch>> get grouped {
    final map = <String, List<LiveMatch>>{};
    for (final match in widget.matches) {
      map.putIfAbsent(match.league, () => []).add(match);
    }
    for (final entry in map.entries) {
      entry.value.sort((a, b) {
        final at = a.startTime?.millisecondsSinceEpoch ?? 0;
        final bt = b.startTime?.millisecondsSinceEpoch ?? 0;
        return at.compareTo(bt);
      });
    }
    final entries = map.entries.toList()
      ..sort((a, b) {
        // Sempre coloca as ligas favoritas primeiro no Ao vivo.
        final aFavorite = widget.favoriteLeagues.contains(a.key);
        final bFavorite = widget.favoriteLeagues.contains(b.key);
        if (aFavorite != bFavorite) {
          return aFavorite ? -1 : 1;
        }

        // Dentro de cada grupo, respeita a preferência de ordenação do usuário.
        if (widget.matchOrder == 'league') {
          return a.key.toLowerCase().compareTo(b.key.toLowerCase());
        }

        final at = a.value.isEmpty
            ? 0
            : (a.value.first.startTime?.millisecondsSinceEpoch ?? 0);
        final bt = b.value.isEmpty
            ? 0
            : (b.value.first.startTime?.millisecondsSinceEpoch ?? 0);
        final timeCompare = at.compareTo(bt);
        if (timeCompare != 0) return timeCompare;

        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });
    return Map.fromEntries(entries);
  }

  @override
  Widget build(BuildContext context) {
    final leagues = grouped;

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              height: 58,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface),
              child: Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 9),
                  const Text('Ao vivo', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(8)),
                    child: Text('${widget.matches.length}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Meu perfil',
                    onPressed: widget.onOpenProfile,
                    icon: const Icon(Icons.account_circle_outlined),
                  ),
                  IconButton(
                    tooltip: 'Menu',
                    onPressed: widget.onOpenMenu,
                    icon: const Icon(Icons.menu),
                  ),
                ],
              ),
            ),
          ),
          if (widget.matches.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sports_soccer_outlined, size: 42, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: 12),
                      const Text('Nenhuma partida ao vivo encontrada', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 10),
                      Text('O futebol ao vivo existe neste momento, então o problema está na fonte ou no parser do app.', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 14),
                      if (widget.liveDiagnostic.isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Theme.of(context).dividerColor),
                          ),
                          child: Text(widget.liveDiagnostic, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final league = leagues.keys.elementAt(index);
                  final matches = leagues[league]!;
                  final collapsed = collapsedLeagues.contains(league);
                  final liveCount = matches.where((m) => m.isLive).length;
                  final isFavorite = widget.favoriteLeagues.contains(league);

                  return Container(
                    margin: const EdgeInsets.fromLTRB(8, 5, 8, 3),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Column(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(9),
                          onTap: () => widget.onOpenLeague(league, matches),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            child: Row(
                              children: [
                                if (liveCount > 0) ...[
                                  const Padding(
                                    padding: EdgeInsets.only(left: 1, right: 6),
                                    child: Icon(Icons.circle, color: Colors.red, size: 7),
                                  ),
                                ] else ...[
                                  const SizedBox(width: 14),
                                ],
                                _LeagueLogo(url: matches.first.leagueLogo, size: 20),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        league,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Color(0xFF73BFFF), fontSize: 15, fontWeight: FontWeight.w900),
                                      ),
                                      Row(
                                        children: [
                                          Text(_countryFlag(matches.first.country), style: const TextStyle(fontSize: 12)),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              '${matches.first.country} • ${matches.length} jogo(s)',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 9),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                if (liveCount > 0) ...[
                                  Text('$liveCount AO VIVO', style: const TextStyle(color: Colors.red, fontSize: 11.5, fontWeight: FontWeight.w900)),
                                  const SizedBox(width: 4),
                                ],
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  onPressed: () => widget.onToggleFavoriteLeague(league),
                                  icon: Icon(isFavorite ? Icons.star : Icons.star_border, color: isFavorite ? Colors.amber : Theme.of(context).colorScheme.onSurfaceVariant, size: 19),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  tooltip: collapsed ? 'Expandir jogos' : 'Recolher jogos',
                                  onPressed: () => setState(() {
                                    if (collapsed) {
                                      collapsedLeagues.remove(league);
                                    } else {
                                      collapsedLeagues.add(league);
                                    }
                                  }),
                                  icon: Icon(collapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (!collapsed)
                          ...matches.map((match) => MatchCard(
                                compact: true,
                                match: match,
                                favorite: widget.favoriteMatches.contains(match.id),
                                onFavorite: () => widget.onToggleFavoriteMatch(match.id),
                                favoriteHome: widget.favorites.contains(match.home.id),
                                favoriteAway: widget.favorites.contains(match.away.id),
                                onFavoriteHome: () => widget.onToggleFavorite(match.home.id),
                                onFavoriteAway: () => widget.onToggleFavorite(match.away.id),
                                onTap: () => widget.onOpenMatch(match),
                              )),
                      ],
                    ),
                  );
                },
                childCount: leagues.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

// ============================================================
// DETALHES DA LIGA
// ============================================================

String _countryFlag(String country) {
  final normalized = country.trim().toLowerCase();
  const flags = <String, String>{
    'inglaterra': '🇬🇧',
    'england': '🇬🇧',
    'espanha': '🇪🇸',
    'spain': '🇪🇸',
    'itália': '🇮🇹',
    'italia': '🇮🇹',
    'italy': '🇮🇹',
    'alemanha': '🇩🇪',
    'germany': '🇩🇪',
    'frança': '🇫🇷',
    'franca': '🇫🇷',
    'france': '🇫🇷',
    'portugal': '🇵🇹',
    'holanda': '🇳🇱',
    'netherlands': '🇳🇱',
    'bélgica': '🇧🇪',
    'belgica': '🇧🇪',
    'belgium': '🇧🇪',
    'turquia': '🇹🇷',
    'turkey': '🇹🇷',
    'escócia': '🏴',
    'escocia': '🏴',
    'scotland': '🏴',
    'brasil': '🇧🇷',
    'brazil': '🇧🇷',
    'méxico': '🇲🇽',
    'mexico': '🇲🇽',
    'argentina': '🇦🇷',
    'colômbia': '🇨🇴',
    'colombia': '🇨🇴',
    'chile': '🇨🇱',
    'uruguai': '🇺🇾',
    'uruguay': '🇺🇾',
    'equador': '🇪🇨',
    'ecuador': '🇪🇨',
    'paraguai': '🇵🇾',
    'paraguay': '🇵🇾',
    'peru': '🇵🇪',
    'estados unidos': '🇺🇸',
    'united states': '🇺🇸',
    'usa': '🇺🇸',
    'canadá': '🇨🇦',
    'canada': '🇨🇦',
    'europa': '🇪🇺',
    'internacional': '🌎',
  };
  return flags[normalized] ?? '🌎';
}

class _LeagueLogo extends StatelessWidget {
  final String? url;
  final double size;

  const _LeagueLogo({this.url, this.size = 32});

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.emoji_events_outlined, size: size * .65, color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * .22),
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Icon(Icons.emoji_events_outlined, size: size * .65, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class LeagueDetailsPage extends StatefulWidget {
  final KickoffApiService api;
  final String leagueName;
  final String country;
  final String leagueId;
  final String? leagueLogo;
  final int? season;
  final List<LiveMatch> initialMatches;

  const LeagueDetailsPage({
    super.key,
    required this.api,
    required this.leagueName,
    required this.country,
    required this.leagueId,
    required this.leagueLogo,
    required this.season,
    required this.initialMatches,
  });

  @override
  State<LeagueDetailsPage> createState() => _LeagueDetailsPageState();
}

class _LeagueDetailsPageState extends State<LeagueDetailsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<dynamic> fixtures = [];
  List<dynamic> standings = [];
  List<dynamic> odds = [];
  List<dynamic> topScorers = [];
  bool loadingFixtures = false;
  bool loadingStandings = false;
  bool loadingOdds = false;
  bool loadingTopScorers = false;
  bool fixturesLoaded = false;
  bool standingsLoaded = false;
  bool oddsLoaded = false;
  bool topScorersLoaded = false;
  String filter = 'Todos';
  String standingsFilter = 'Geral';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _tabs.addListener(() {
      if (_tabs.indexIsChanging) return;
      // Cada aba consulta os dados reais da liga selecionada.
      if (_tabs.index == 0 || _tabs.index == 2 || _tabs.index == 3 || _tabs.index == 4) {
        _loadFixtures();
      }
      if (_tabs.index == 2) {
        _loadStandings();
        _loadTopScorers();
      }
      if (_tabs.index == 1) _loadOdds();
    });
    _loadFixtures();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadFixtures() async {
    if (fixturesLoaded || loadingFixtures || widget.leagueId.isEmpty) return;
    setState(() => loadingFixtures = true);
    try {
      final result = await widget.api.getLeagueFixtures(widget.leagueId, season: widget.season);
      if (!mounted) return;
      setState(() {
        fixtures = result;
        fixturesLoaded = true;
        loadingFixtures = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        fixturesLoaded = true;
        loadingFixtures = false;
      });
    }
  }

  Future<void> _loadStandings() async {
    if (standingsLoaded || loadingStandings || widget.leagueId.isEmpty) return;
    setState(() => loadingStandings = true);
    try {
      final result = await widget.api.getLeagueStandings(widget.leagueId, season: widget.season);
      if (!mounted) return;
      setState(() {
        standings = result;
        standingsLoaded = true;
        loadingStandings = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        standingsLoaded = true;
        loadingStandings = false;
      });
    }
  }

  Future<void> _loadOdds() async {
    if (oddsLoaded || loadingOdds || widget.leagueId.isEmpty) return;
    setState(() => loadingOdds = true);
    try {
      final result = await widget.api.getLeagueOdds(widget.leagueId, season: widget.season);
      if (!mounted) return;
      setState(() {
        odds = result;
        oddsLoaded = true;
        loadingOdds = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        oddsLoaded = true;
        loadingOdds = false;
      });
    }
  }


  Future<void> _loadTopScorers() async {
    if (topScorersLoaded || loadingTopScorers || widget.leagueId.isEmpty) return;
    setState(() => loadingTopScorers = true);
    try {
      final result = await widget.api.getLeagueTopScorers(widget.leagueId, season: widget.season);
      if (!mounted) return;
      setState(() {
        topScorers = result;
        topScorersLoaded = true;
        loadingTopScorers = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        topScorersLoaded = true;
        loadingTopScorers = false;
      });
    }
  }


  List<LiveMatch> get fallbackMatches => widget.initialMatches.toList()
    ..sort((a, b) => (a.startTime?.millisecondsSinceEpoch ?? 0).compareTo(b.startTime?.millisecondsSinceEpoch ?? 0));

  String _normLeagueText(String value) {
    var v = value.toLowerCase().trim();
    const replacements = {
      'á': 'a', 'à': 'a', 'ã': 'a', 'â': 'a', 'ä': 'a',
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
      'ó': 'o', 'ò': 'o', 'õ': 'o', 'ô': 'o', 'ö': 'o',
      'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ç': 'c',
    };
    replacements.forEach((from, to) => v = v.replaceAll(from, to));
    v = v.replaceAll(RegExp(r'\s+'), ' ');
    return v;
  }

  String _canonicalLeagueName(String name, String country) {
    final n = _normLeagueText(name);
    final c = _normLeagueText(country);
    if (c == 'italia' && (n == 'serie a' || n.contains('serie a'))) return 'serie a';
    if (c == 'brasil' && (n.contains('brasileir') || n == 'serie a')) return 'brasileirao';
    if (c == 'inglaterra' && n.contains('premier league')) return 'premier league';
    if (c == 'espanha' && (n == 'laliga' || n == 'la liga')) return 'laliga';
    if (c == 'alemanha' && n.contains('bundesliga')) return 'bundesliga';
    if (c == 'franca' && n.contains('ligue 1')) return 'ligue 1';
    return n;
  }

  String? _expectedEspnLeagueCode() {
    final n = _normLeagueText(widget.leagueName);
    final c = _normLeagueText(widget.country);
    if (c == 'italia' && n == 'serie a') return 'ita.1';
    if (c == 'italia' && n == 'serie b') return 'ita.2';
    if (c == 'brasil' && (n.contains('brasileir') || n == 'serie a')) return 'bra.1';
    if (c == 'brasil' && n.contains('serie b')) return 'bra.2';
    if (c == 'inglaterra' && n == 'premier league') return 'eng.1';
    if (c == 'inglaterra' && n == 'championship') return 'eng.2';
    if (c == 'espanha' && (n == 'laliga' || n == 'la liga')) return 'esp.1';
    if (c == 'espanha' && (n.contains('laliga 2') || n.contains('la liga 2'))) return 'esp.2';
    if (c == 'alemanha' && n == 'bundesliga') return 'ger.1';
    if (c == 'alemanha' && n.contains('2. bundesliga')) return 'ger.2';
    if (c == 'franca' && n == 'ligue 1') return 'fra.1';
    if (c == 'franca' && n == 'ligue 2') return 'fra.2';
    if (c == 'portugal' && n.contains('primeira liga')) return 'por.1';
    if (c == 'holanda' && n == 'eredivisie') return 'ned.1';
    if (c == 'belgica' && n.contains('pro league')) return 'bel.1';
    if (c == 'turquia' && n.contains('super lig')) return 'tur.1';
    if (c == 'argentina' && n.contains('liga profesional')) return 'arg.1';
    if (c == 'paraguai' && n.contains('copa de primera')) return 'par.1';
    if (c == 'mexico' && n.contains('liga mx')) return 'mex.1';
    if (c == 'escocia' && n.contains('premiership')) return 'sco.1';
    if (c == 'eua' && n == 'mls') return 'usa.1';
    return null;
  }

  bool _sameLeague(LiveMatch match) {
    final wantedName = _canonicalLeagueName(widget.leagueName, widget.country);
    final matchName = _canonicalLeagueName(match.league, match.country);
    final wantedCountry = _normLeagueText(widget.country);
    final matchCountry = _normLeagueText(match.country);

    // Nunca aceite uma partida apenas porque o ID coincidiu. O nome + país
    // também precisam representar a mesma competição.
    if (wantedCountry.isNotEmpty && wantedCountry != 'internacional') {
      if (matchCountry.isNotEmpty && matchCountry != 'internacional' && wantedCountry != matchCountry) {
        return false;
      }
    }

    final expectedEspn = _expectedEspnLeagueCode();
    if (expectedEspn != null && match.leagueApiId == 'espn:$expectedEspn') return true;

    if (wantedName.isNotEmpty && matchName.isNotEmpty) {
      if (wantedName == matchName) return true;
      // Série A italiana e Brasileirão jamais são equivalentes.
      if ((wantedName == 'serie a' && wantedCountry == 'italia') ||
          (matchName == 'serie a' && matchCountry == 'italia')) return false;
      if ((wantedName == 'brasileirao' && wantedCountry == 'brasil') ||
          (matchName == 'brasileirao' && matchCountry == 'brasil')) return false;
      return false;
    }

    final wantedId = widget.leagueId.trim();
    final matchId = match.leagueApiId.trim();
    return wantedId.isNotEmpty && matchId.isNotEmpty && wantedId == matchId;
  }

  List<LiveMatch> get parsedFixtures {
    final source = fixtures.isEmpty ? fallbackMatches : fixtures.map(_parseLiveMatch).toList();
    // MUITO IMPORTANTE: uma página de liga só pode mostrar partidas daquela
    // liga. Antes havia uma condição que aceitava qualquer partida quando
    // leagueId estava preenchido, fazendo a Serie A italiana receber jogos
    // do Brasileirão.
    final filtered = source.where(_sameLeague).toList();
    filtered.sort((a, b) => (a.startTime?.millisecondsSinceEpoch ?? 0)
        .compareTo(b.startTime?.millisecondsSinceEpoch ?? 0));
    return filtered;
  }

  List<LiveMatch> get resultMatches {
    final list = parsedFixtures.where((m) => m.isFinished).toList();
    list.sort((a, b) => (b.startTime?.millisecondsSinceEpoch ?? 0)
        .compareTo(a.startTime?.millisecondsSinceEpoch ?? 0));
    return list;
  }

  List<LiveMatch> get calendarMatches {
    final list = parsedFixtures.where((m) => m.isScheduled || m.isLive).toList();
    list.sort((a, b) => (a.startTime?.millisecondsSinceEpoch ?? 0).compareTo(b.startTime?.millisecondsSinceEpoch ?? 0));
    return list;
  }

  String _roundKey(LiveMatch match) {
    final raw = (match.round ?? '').trim();
    if (raw.isEmpty) return 'Próxima rodada';
    final matchNumber = RegExp(r'(\d+)').firstMatch(raw)?.group(1);
    if (matchNumber != null) return 'Rodada $matchNumber';
    return raw.toLowerCase().contains('round') ? raw.replaceFirst(RegExp('round', caseSensitive: false), 'Rodada') : raw;
  }

  int _roundNumber(String key) {
    return int.tryParse(RegExp(r'(\d+)').firstMatch(key)?.group(1) ?? '') ?? 99999;
  }

  Map<String, List<LiveMatch>> _calendarGroups() {
    final groups = <String, List<LiveMatch>>{};
    for (final match in calendarMatches) {
      groups.putIfAbsent(_roundKey(match), () => []).add(match);
    }
    final entries = groups.entries.toList();
    entries.sort((a, b) {
      final an = _roundNumber(a.key);
      final bn = _roundNumber(b.key);
      if (an != bn) return an.compareTo(bn);
      final ad = a.value.first.startTime?.millisecondsSinceEpoch ?? 0;
      final bd = b.value.first.startTime?.millisecondsSinceEpoch ?? 0;
      return ad.compareTo(bd);
    });
    return {for (final e in entries) e.key: e.value};
  }

  Map<String, List<LiveMatch>> _resultGroups() {
    final groups = <String, List<LiveMatch>>{};
    for (final match in resultMatches) {
      groups.putIfAbsent(_roundKey(match), () => []).add(match);
    }

    final entries = groups.entries.toList();
    entries.sort((a, b) {
      final an = _roundNumber(a.key);
      final bn = _roundNumber(b.key);
      // Resultados: rodada mais recente primeiro, como no exemplo solicitado.
      if (an != 99999 && bn != 99999 && an != bn) return bn.compareTo(an);
      if (an != bn) return an.compareTo(bn);
      final ad = a.value.isEmpty ? 0 : (a.value.first.startTime?.millisecondsSinceEpoch ?? 0);
      final bd = b.value.isEmpty ? 0 : (b.value.first.startTime?.millisecondsSinceEpoch ?? 0);
      return bd.compareTo(ad);
    });

    for (final entry in entries) {
      entry.value.sort((a, b) => (b.startTime?.millisecondsSinceEpoch ?? 0)
          .compareTo(a.startTime?.millisecondsSinceEpoch ?? 0));
    }

    return {for (final e in entries) e.key: e.value};
  }

  List<LiveMatch> _applyFilter(List<LiveMatch> input) {
    switch (filter) {
      case 'Ao vivo':
        return input.where((m) => m.isLive).toList();
      case 'Finalizados':
        return input.where((m) => m.isFinished).toList();
      case 'Próximos':
        return input.where((m) => m.isScheduled).toList();
      default:
        return input;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final currentSeason = widget.season?.toString() ?? 'Temporada atual';
    final matches = _applyFilter(parsedFixtures);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: const Color(0xFF082433),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: const BackButton(),
        titleSpacing: 0,
        title: Row(
          children: [
            Text(_countryFlag(widget.country), style: const TextStyle(fontSize: 19)),
            const SizedBox(width: 7),
            const Text('Futebol', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.share_outlined)),
          IconButton(onPressed: () {}, icon: const Icon(Icons.star_border)),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
            color: const Color(0xFF0A3142),
            child: Row(
              children: [
                _LeagueLogo(url: widget.leagueLogo, size: 54),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.leagueName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Text(_countryFlag(widget.country), style: const TextStyle(fontSize: 13)),
                          const SizedBox(width: 5),
                          Text(widget.country, style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w700)),
                          const SizedBox(width: 8),
                          const Text('•', style: TextStyle(color: Colors.white38)),
                          const SizedBox(width: 8),
                          Text(currentSeason, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 42,
            child: TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: const Color(0xFF73BFFF),
              unselectedLabelColor: Colors.white54,
              indicatorColor: const Color(0xFF73BFFF),
              indicatorWeight: 2.5,
              labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
              tabs: const [
                Tab(text: 'SUMÁRIO'),
                Tab(text: 'ODDS'),
                Tab(text: 'CLASSIFICAÇÕES'),
                Tab(text: 'RESULTADOS'),
                Tab(text: 'CALENDÁRIO'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _summaryTab(matches, cs),
                _oddsTab(cs),
                _standingsTab(cs),
                _resultsTab(cs),
                _calendarTab(cs),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryTab(List<LiveMatch> matches, ColorScheme cs) {
    final live = matches.where((m) => m.isLive).toList();
    final upcoming = matches.where((m) => m.isScheduled).take(12).toList();
    return RefreshIndicator(
      onRefresh: () async {
        setState(() {
          fixturesLoaded = false;
          fixtures = [];
        });
        await _loadFixtures();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 24),
        children: [
          _filterBar(),
          const SizedBox(height: 8),
          if (live.isNotEmpty) _sectionTitle('Ao vivo', Colors.red),
          ...live.map((m) => _leagueMatchTile(m, cs)),
          if (upcoming.isNotEmpty) _sectionTitle('Próximos jogos', const Color(0xFF73BFFF)),
          ...upcoming.map((m) => _leagueMatchTile(m, cs)),
          if (live.isEmpty && upcoming.isEmpty && loadingFixtures)
            const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator())),
          if (live.isEmpty && upcoming.isEmpty && !loadingFixtures)
            const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('Sem partidas para exibir.', style: TextStyle(color: Colors.white54)))),
          const SizedBox(height: 14),
          _sectionTitle('Classificações', const Color(0xFF73BFFF)),
          _standingsPreview(cs),
        ],
      ),
    );
  }

  Widget _standingsPreview(ColorScheme cs) {
    if (standings.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Text(loadingStandings ? 'Carregando classificação...' : 'Classificação não disponível.', style: const TextStyle(color: Colors.white54, fontSize: 11)),
      );
    }
    final rows = standings.take(6).map((raw) {
      final item = _asMap(raw) ?? {};
      final team = _asMap(item['team']) ?? {};
      final rank = item['rank'] ?? '';
      final points = item['points'] ?? item['pts'] ?? '-';
      return '${_safeString(team['name'], 'Time')}  •  ${item['played'] ?? _asMap(item['all'])?['played'] ?? '-'}J  •  $points pts';
    }).toList();
    return Column(
      children: rows.asMap().entries.map((entry) {
        final index = entry.key;
        final value = entry.value;
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${index + 1}.',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 10,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _filterBar() {
    const filters = ['Todos', 'Ao vivo', 'Finalizados', 'Próximos'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters.map((value) {
          final selected = filter == value;
          return Padding(
            padding: const EdgeInsets.only(right: 7),
            child: ChoiceChip(
              label: Text(value),
              selected: selected,
              onSelected: (_) => setState(() => filter = value),
              labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70, fontSize: 11, fontWeight: FontWeight.w800),
              selectedColor: const Color(0xFF0C5A83),
              backgroundColor: const Color(0xFF10232D),
              side: BorderSide(color: selected ? const Color(0xFF73BFFF) : Colors.white12),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _sectionTitle(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      child: Row(
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(title, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _leagueMatchTile(LiveMatch match, ColorScheme cs) {
    return MatchCard(
      compact: true,
      match: match,
      favorite: false,
      onFavorite: () {},
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MatchDetailsPage(
            match: match,
            api: widget.api,
            favorites: <int>{},
            onToggleFavorite: (_) async {},
          ),
        ),
      ),
    );
  }

  Widget _matchesTab(List<LiveMatch> list, ColorScheme cs, String emptyText) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 24),
      children: [
        _filterBar(),
        const SizedBox(height: 8),
        if (list.isEmpty && loadingFixtures) const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator())),
        if (list.isEmpty && !loadingFixtures) Padding(padding: const EdgeInsets.all(28), child: Center(child: Text(emptyText, style: const TextStyle(color: Colors.white54)))),
        ...list.map((m) => _leagueMatchTile(m, cs)),
      ],
    );
  }

  Widget _standingsTab(ColorScheme cs) {
    final filters = ['Ao vivo', 'Geral', 'Artilheiros', 'Casa', 'Fora', 'Forma'];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 3),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: filters.map((value) {
                final selected = standingsFilter == value;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(value),
                    selected: selected,
                    onSelected: (_) => setState(() => standingsFilter = value),
                    labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70, fontSize: 10, fontWeight: FontWeight.w900),
                    selectedColor: const Color(0xFF0C5A83),
                    backgroundColor: const Color(0xFF10232D),
                    side: BorderSide(color: selected ? const Color(0xFF73BFFF) : Colors.white12),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        Expanded(child: _standingsContent(cs)),
      ],
    );
  }

  Widget _standingsContent(ColorScheme cs) {
    if (standingsFilter == 'Artilheiros') return _topScorersTab(cs);
    if (loadingStandings) return const Center(child: CircularProgressIndicator());
    if (standings.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(28), child: Text('Classificação não disponível para esta competição.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54))));
    }

    final liveTeamIds = <int>{};
    if (standingsFilter == 'Ao vivo') {
      for (final m in parsedFixtures.where((m) => m.isLive)) {
        liveTeamIds.add(m.home.id);
        liveTeamIds.add(m.away.id);
      }
    }

    final rows = standings.where((raw) {
      final item = _asMap(raw) ?? {};
      final team = _asMap(item['team']) ?? {};
      final teamId = _localId(_safeString(team['id']));
      if (standingsFilter == 'Ao vivo') return liveTeamIds.contains(teamId);
      return true;
    }).toList();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 24),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 7),
            child: Row(children: [
              const SizedBox(width: 25),
              const Expanded(child: Text('EQUIPE', style: TextStyle(color: Colors.white54, fontSize: 11.5, fontWeight: FontWeight.w900))),
              _standingsCell('J', 'J'),
              _standingsCell('G', 'G'),
              _standingsCell('P', 'P', strong: true),
            ]),
          );
        }
        final item = _asMap(rows[index - 1]) ?? {};
        final team = _asMap(item['team']) ?? {};
        final rank = item['rank'] ?? index;
        final points = item['points'] ?? item['pts'] ?? '-';
        final all = _asMap(item['all']) ?? {};
        final home = _asMap(item['home']) ?? {};
        final away = _asMap(item['away']) ?? {};
        final source = standingsFilter == 'Casa' ? home : standingsFilter == 'Fora' ? away : all;
        final played = source['played'] ?? item['played'] ?? '-';
        final wins = source['win'] ?? source['wins'] ?? item['wins'] ?? '-';
        final draws = source['draw'] ?? source['draws'] ?? item['draws'] ?? '-';
        final losses = source['lose'] ?? source['losses'] ?? item['losses'] ?? '-';
        final goalsMap = _asMap(source['goals']);
        final goalsFor = goalsMap?['for'] ?? source['goalsFor'];
        final goalsAgainst = goalsMap?['against'] ?? source['goalsAgainst'];
        final formValue = source['form'] ?? item['form'] ?? item['recentForm'] ?? item['formString'];
        final form = formValue?.toString() ?? '';
        final logo = team['logo']?.toString();
        return Container(
          margin: const EdgeInsets.only(bottom: 5),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
          decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(9)),
          child: Row(children: [
            SizedBox(width: 25, child: Text('$rank', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 10))),
            if (logo != null && logo.isNotEmpty) ...[ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.network(logo, width: 22, height: 22, fit: BoxFit.contain)), const SizedBox(width: 7)] else const SizedBox(width: 29),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_safeString(team['name'], 'Time'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
              if (standingsFilter == 'Forma' && form.isNotEmpty) Text(form, style: const TextStyle(color: Colors.white54, fontSize: 10.5, fontWeight: FontWeight.w800)),
              if ((standingsFilter == 'Casa' || standingsFilter == 'Fora') && (goalsFor != null || goalsAgainst != null)) Text('$goalsFor:$goalsAgainst', style: const TextStyle(color: Colors.white54, fontSize: 10.5, fontWeight: FontWeight.w800)),
            ])),
            _standingsCell('J', played),
            _standingsCell('G', wins),
            _standingsCell('P', standingsFilter == 'Geral' || standingsFilter == 'Forma' || standingsFilter == 'Ao vivo' ? points : (source['points'] ?? points), strong: true),
            if (standingsFilter == 'Geral' || standingsFilter == 'Forma' || standingsFilter == 'Ao vivo') _standingsCell('E/D', '$draws/$losses'),
          ]),
        );
      },
    );
  }

  Widget _topScorersTab(ColorScheme cs) {
    if (loadingTopScorers) return const Center(child: CircularProgressIndicator());
    if (topScorers.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(28), child: Text('Artilheiros não disponíveis para esta competição.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54))));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: topScorers.length,
      itemBuilder: (context, index) {
        final item = _asMap(topScorers[index]) ?? {};
        final player = _asMap(item['player']) ?? {};
        final stats = _asMap(item['statistics'] is List && (item['statistics'] as List).isNotEmpty ? (item['statistics'] as List).first : item['statistics']) ?? {};
        final goals = _asMap(stats['goals']) ?? {};
        final games = _asMap(stats['games']) ?? {};
        return Container(
          margin: const EdgeInsets.only(bottom: 5),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(9)),
          child: Row(children: [
            SizedBox(width: 28, child: Text('${index + 1}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900))),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_safeString(player['name'], 'Jogador'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
              if (games['appearances'] != null || games['appearences'] != null) Text('Jogos: ${games['appearances'] ?? games['appearences']}', style: const TextStyle(color: Colors.white54, fontSize: 8)),
            ])),
            Text('${goals['total'] ?? item['goals'] ?? 0}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            const SizedBox(width: 4),
            const Text('gols', style: TextStyle(color: Colors.white54, fontSize: 9)),
          ]),
        );
      },
    );
  }

  String _resultDate(LiveMatch match) {
    final date = match.startTime;
    if (date == null) return '--.--';
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.';
  }

  String _resultOddLabel(LiveMatch match, String side) {
    // A estrutura de odds varia conforme a casa/mercado retornado pela API.
    // Procuramos recursivamente por valores associados à partida e aceitamos
    // os formatos mais comuns: 1/X/2, home/draw/away e value/odd.
    final fixtureId = match.apiId.trim();
    for (final raw in odds) {
      final root = _asMap(raw);
      if (root == null) continue;
      if (fixtureId.isNotEmpty && !_containsFixtureId(root, fixtureId)) continue;
      final value = _findOddValue(root, side);
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return '-';
  }

  bool _containsFixtureId(dynamic value, String fixtureId) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        final item = entry.value;
        if ((key == 'fixture' || key == 'fixtureid' || key == 'fixture_id' || key == 'match' || key == 'matchid' || key == 'match_id' || key == 'event') && item != null) {
          if (item.toString() == fixtureId) return true;
          final map = _asMap(item);
          if (map != null && (map['id']?.toString() == fixtureId || map['fixture']?.toString() == fixtureId)) return true;
        }
        if (_containsFixtureId(item, fixtureId)) return true;
      }
    } else if (value is List) {
      for (final item in value) {
        if (_containsFixtureId(item, fixtureId)) return true;
      }
    }
    return false;
  }

  String? _findOddValue(dynamic value, String side) {
    final wanted = side == 'home'
        ? const {'home', '1', 'team1', 'homewin'}
        : side == 'away'
            ? const {'away', '2', 'team2', 'awaywin'}
            : const {'draw', 'x', 'tie'};

    if (value is Map) {
      final direct = value['odd'] ?? value['price'];
      final valueLabel = value['value']?.toString().toLowerCase().trim();
      if (direct != null && valueLabel != null && wanted.contains(valueLabel)) {
        return direct.toString();
      }

      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase().replaceAll('_', '').replaceAll('-', '');
        if (wanted.contains(key)) {
          final nested = _asMap(entry.value);
          if (nested != null) {
            final odd = nested['odd'] ?? nested['price'] ?? nested['value'];
            if (odd != null) return odd.toString();
          } else if (entry.value != null) {
            return entry.value.toString();
          }
        }
      }

      for (final entry in value.entries) {
        final found = _findOddValue(entry.value, side);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final item in value) {
        final found = _findOddValue(item, side);
        if (found != null) return found;
      }
    }
    return null;
  }

  Widget _resultOdd(String value, {bool highlight = false}) {
    return Container(
      constraints: const BoxConstraints(minWidth: 45),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFF183E50) : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        value,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: highlight ? Colors.white : Colors.white70,
          fontSize: 10,
          fontWeight: highlight ? FontWeight.w900 : FontWeight.w700,
        ),
      ),
    );
  }

  Widget _resultMatchRow(LiveMatch match, ColorScheme cs) {
    final homeOdd = _resultOddLabel(match, 'home');
    final drawOdd = _resultOddLabel(match, 'draw');
    final awayOdd = _resultOddLabel(match, 'away');
    final homeScore = match.homeScore?.toString() ?? '-';
    final awayScore = match.awayScore?.toString() ?? '-';
    final homeWon = (match.homeScore ?? -1) > (match.awayScore ?? -1);
    final awayWon = (match.awayScore ?? -1) > (match.homeScore ?? -1);

    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MatchDetailsPage(
              match: match,
              api: widget.api,
              favorites: <int>{},
              onToggleFavorite: (_) async {},
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 9, 8, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 46,
                child: Text(
                  _resultDate(match),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 11.5, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        ClubShield(team: match.home, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            match.home.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, fontWeight: homeWon ? FontWeight.w900 : FontWeight.w700),
                          ),
                        ),
                        Text(homeScore, style: TextStyle(fontSize: 14, fontWeight: homeWon ? FontWeight.w900 : FontWeight.w700)),
                        const SizedBox(width: 5),
                        _resultOdd(homeOdd, highlight: homeWon),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        const SizedBox(width: 24),
                        Expanded(
                          child: Text(
                            match.away.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, fontWeight: awayWon ? FontWeight.w900 : FontWeight.w700),
                          ),
                        ),
                        Text(awayScore, style: TextStyle(fontSize: 14, fontWeight: awayWon ? FontWeight.w900 : FontWeight.w700)),
                        const SizedBox(width: 5),
                        _resultOdd(awayOdd, highlight: awayWon),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        const Text('X', style: TextStyle(color: Colors.white30, fontSize: 8, fontWeight: FontWeight.w900)),
                        const SizedBox(width: 4),
                        _resultOdd(drawOdd),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resultsTab(ColorScheme cs) {
    final groups = _resultGroups();
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [
        if (groups.isEmpty && loadingFixtures)
          const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator())),
        if (groups.isEmpty && !loadingFixtures)
          const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('Nenhum resultado encontrado para esta liga.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)))),
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(5, 14, 5, 9),
            child: Row(
              children: [
                const Icon(Icons.calendar_today_outlined, size: 14, color: Color(0xFF73BFFF)),
                const SizedBox(width: 6),
                Text(entry.key, style: const TextStyle(color: Color(0xFF73BFFF), fontSize: 15, fontWeight: FontWeight.w900)),
              ],
            ),
          ),
          ...entry.value.map((match) => Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: _resultMatchRow(match, cs),
              )),
        ],
      ],
    );
  }

  Widget _calendarTab(ColorScheme cs) {
    final groups = _calendarGroups();
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 24),
      children: [
        _filterBar(),
        const SizedBox(height: 8),
        if (groups.isEmpty && loadingFixtures) const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator())),
        if (groups.isEmpty && !loadingFixtures) const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('Nenhum jogo no calendário encontrado.', style: TextStyle(color: Colors.white54)))),
        for (final entry in groups.entries) ...[
          Padding(padding: const EdgeInsets.fromLTRB(4, 9, 4, 7), child: Row(children: [const Icon(Icons.calendar_month, size: 16, color: Color(0xFF73BFFF)), const SizedBox(width: 6), Text(entry.key, style: const TextStyle(color: Color(0xFF73BFFF), fontSize: 15, fontWeight: FontWeight.w900))])),
          ...entry.value.map((m) => _calendarMatchTile(m, cs)),
        ],
      ],
    );
  }

  Widget _calendarMatchTile(LiveMatch match, ColorScheme cs) {
    final date = match.startTime;
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MatchDetailsPage(match: match, api: widget.api, favorites: <int>{}, onToggleFavorite: (_) async {}))),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(children: [
            SizedBox(width: 58, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(date == null ? '--.--' : '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
              Text(date == null ? '--:--' : _formatTime(date), style: const TextStyle(color: Colors.white54, fontSize: 9, fontWeight: FontWeight.w800)),
            ])),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [ClubShield(team: match.home, size: 18), const SizedBox(width: 6), Expanded(child: Text(match.home.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)))]),
              const SizedBox(height: 4),
              Row(children: [ClubShield(team: match.away, size: 18), const SizedBox(width: 6), Expanded(child: Text(match.away.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)))]),
            ])),
            SizedBox(width: 46, child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text('-', style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w900)), const SizedBox(height: 4), Text('-', style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w900))])),
          ]),
        ),
      ),
    );
  }

  Widget _standingsCell(String label, dynamic value, {bool strong = false}) {
    return SizedBox(width: 27, child: Column(children: [Text(label, style: const TextStyle(color: Colors.white38, fontSize: 7, fontWeight: FontWeight.w800)), const SizedBox(height: 2), Text('$value', style: TextStyle(fontSize: 9, fontWeight: strong ? FontWeight.w900 : FontWeight.w700))]));
  }

  Widget _oddsTab(ColorScheme cs) {
    if (loadingOdds) return const Center(child: CircularProgressIndicator());
    if (odds.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(28), child: Text('Odds não disponíveis para esta competição no plano atual da API.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54))));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: odds.length,
      itemBuilder: (context, index) {
        final item = _asMap(odds[index]) ?? {};
        final bookmaker = _asMap(item['bookmaker']) ?? {};
        final betType = _asMap(item['betType']) ?? _asMap(item['bet']) ?? {};
        final values = _asList(item['values'] ?? item['odds']);
        return Container(
          margin: const EdgeInsets.only(bottom: 7),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_safeString(bookmaker['name'], 'Casa de apostas'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
            const SizedBox(height: 3),
            Text(_safeString(betType['name'], 'Mercado'), style: const TextStyle(color: Colors.white54, fontSize: 9)),
            const SizedBox(height: 7),
            Wrap(spacing: 6, runSpacing: 5, children: values.map((v) { final m = _asMap(v) ?? {}; return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), decoration: BoxDecoration(color: const Color(0xFF0A3142), borderRadius: BorderRadius.circular(7)), child: Text('${_safeString(m['value'], 'Opção')}  ${_safeString(m['odd'], '-')} ', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800))); }).toList()),
          ]),
        );
      },
    );
  }
}

// ============================================================
// GOLS HOJE
// ============================================================

class GoalsTodayPage extends StatelessWidget {
  final List<LiveMatch> matches;
  final Set<String> favoriteLeagues;
  final Set<int> favorites;
  final Set<int> favoriteMatches;
  final int selectedGoals;
  final ValueChanged<int> onSelectedGoalsChanged;
  final String matchOrder;
  final Future<void> Function(int teamId) onToggleFavorite;
  final Future<void> Function(int matchId) onToggleFavoriteMatch;
  final void Function(LiveMatch match) onOpenMatch;

  const GoalsTodayPage({
    super.key,
    required this.matches,
    required this.favoriteLeagues,
    required this.favorites,
    required this.favoriteMatches,
    required this.selectedGoals,
    required this.onSelectedGoalsChanged,
    required this.matchOrder,
    required this.onToggleFavorite,
    required this.onToggleFavoriteMatch,
    required this.onOpenMatch,
  });

  int _totalGoals(LiveMatch match) {
    final home = match.homeScore;
    final away = match.awayScore;
    if (home == null || away == null) return -1;
    return home + away;
  }

  List<LiveMatch> get filteredMatches {
    if (favoriteLeagues.isEmpty) return const [];

    final list = matches.where((match) {
      if (!favoriteLeagues.contains(match.league)) return false;
      final total = _totalGoals(match);
      if (total < 0) return false;
      return selectedGoals == 6 ? total >= 6 : total == selectedGoals;
    }).toList();

    list.sort((a, b) {
      if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
      if (a.isFinished != b.isFinished) return a.isFinished ? 1 : -1;
      return (a.startTime?.millisecondsSinceEpoch ?? 0)
          .compareTo(b.startTime?.millisecondsSinceEpoch ?? 0);
    });
    return list;
  }

  String _goalLabel(int value) {
    if (value == 0) return '0 - gols';
    if (value == 1) return '1 - gol';
    if (value == 6) return '6+ - gols';
    return '$value - gols';
  }

  @override
  Widget build(BuildContext context) {
    final list = filteredMatches;

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Container(
              height: 58,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface),
              child: Row(
                children: [
                  const Icon(Icons.filter_alt, color: Colors.red, size: 24),
                  const SizedBox(width: 9),
                  const Text('Gols Hoje', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  const Spacer(),
                  Text(_goalLabel(selectedGoals), style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 5),
              child: Row(
                children: [
                  const Icon(Icons.star, color: Colors.amber, size: 16),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      favoriteLeagues.isEmpty
                          ? 'Marque suas competições favoritas em Ligas.'
                          : 'Filtro em ${favoriteLeagues.length} competição(ões) favorita(s)',
                      style: const TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text('${list.length}', style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w900)),
                ],
              ),
            ),
          ),
          if (favoriteLeagues.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                    'Você ainda não selecionou competições favoritas.\n\nEntre em Ligas e marque as competições com ★.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60, fontSize: 16, height: 1.4),
                  ),
                ),
              ),
            )
          else if (list.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    'Nenhum jogo encontrado com ${_goalLabel(selectedGoals)} nas suas competições favoritas.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white60, fontSize: 16, height: 1.4),
                  ),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final match = list[index];
                  return _FlashMatchRow(
                    match: match,
                    favorite: favoriteMatches.contains(match.id),
                    onFavorite: () => onToggleFavorite(match.home.id),
                    onMatchFavorite: () => onToggleFavoriteMatch(match.id),
                    onTap: () => onOpenMatch(match),
                  );
                },
                childCount: list.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

// ============================================================
// FAVORITES
// ============================================================

class FavoritesPage extends StatelessWidget {
  final List<LiveMatch> matches;
  final Set<int> favorites;
  final Set<int> favoriteMatches;
  final Future<void> Function(int teamId) onToggleFavorite;
  final Future<void> Function(int matchId) onToggleFavoriteMatch;
  final void Function(LiveMatch match) onOpenMatch;

  const FavoritesPage({
    super.key,
    required this.matches,
    required this.favorites,
    required this.favoriteMatches,
    required this.onToggleFavorite,
    required this.onToggleFavoriteMatch,
    required this.onOpenMatch,
  });

  @override
  Widget build(BuildContext context) {
    final favoriteGameMatches = matches.where((match) {
      return favoriteMatches.contains(match.id) ||
          favorites.contains(match.home.id) ||
          favorites.contains(match.away.id);
    }).toList();

    favoriteGameMatches.sort((a, b) {
      if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
      if (a.isFinished != b.isFinished) return a.isFinished ? 1 : -1;
      return (a.startTime?.millisecondsSinceEpoch ?? 0)
          .compareTo(b.startTime?.millisecondsSinceEpoch ?? 0);
    });

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Favoritos',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
              ),
            ),
          ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'Aqui aparecem jogos marcados com ★ e jogos dos seus times favoritos.',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ),
          ),
          if (favoriteGameMatches.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(30),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_border, size: 64, color: Colors.white24),
                      SizedBox(height: 14),
                      Text('Nenhum favorito', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      SizedBox(height: 6),
                      Text(
                        'Marque um jogo com ★ ou favorite um time nos detalhes da partida.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final match = favoriteGameMatches[index];
                  return MatchCard(
                    match: match,
                    favorite: favoriteMatches.contains(match.id),
                    onFavorite: () => onToggleFavoriteMatch(match.id),
                    onTap: () => onOpenMatch(match),
                  );
                },
                childCount: favoriteGameMatches.length,
              ),
            ),
        ],
      ),
    );
  }
}

class CompetitionsPage extends StatelessWidget {
  final List<LiveMatch> matches;
  final Set<String> favoriteLeagues;
  final Future<void> Function(String league) onToggleFavoriteLeague;
  final void Function(LiveMatch match) onOpenMatch;

  const CompetitionsPage({
    super.key,
    required this.matches,
    required this.favoriteLeagues,
    required this.onToggleFavoriteLeague,
    required this.onOpenMatch,
  });

  static const List<Map<String, String>> mainLeagues = [
    {'country': 'EUROPA', 'name': 'Champions League'},
    {'country': 'EUROPA', 'name': 'Europa League'},
    {'country': 'EUROPA', 'name': 'Conference League'},
    {'country': 'EUROPA', 'name': 'Super Cup'},
    {'country': 'INGLATERRA', 'name': 'Premier League'},
    {'country': 'INGLATERRA', 'name': 'Championship'},
    {'country': 'ESPANHA', 'name': 'LaLiga'},
    {'country': 'ESPANHA', 'name': 'LaLiga 2'},
    {'country': 'ITÁLIA', 'name': 'Serie A'},
    {'country': 'ITÁLIA', 'name': 'Serie B'},
    {'country': 'ALEMANHA', 'name': 'Bundesliga'},
    {'country': 'ALEMANHA', 'name': '2. Bundesliga'},
    {'country': 'FRANÇA', 'name': 'Ligue 1'},
    {'country': 'FRANÇA', 'name': 'Ligue 2'},
    {'country': 'PORTUGAL', 'name': 'Primeira Liga'},
    {'country': 'HOLANDA', 'name': 'Eredivisie'},
    {'country': 'BÉLGICA', 'name': 'Pro League'},
    {'country': 'TURQUIA', 'name': 'Süper Lig'},
    {'country': 'ESCÓCIA', 'name': 'Premiership'},
    {'country': 'ÁUSTRIA', 'name': 'Bundesliga'},
    {'country': 'SUÍÇA', 'name': 'Super League'},
    {'country': 'DINAMARCA', 'name': 'Superliga'},
    {'country': 'NORUEGA', 'name': 'Eliteserien'},
    {'country': 'SUÉCIA', 'name': 'Allsvenskan'},
    {'country': 'POLÔNIA', 'name': 'Ekstraklasa'},
    {'country': 'REP. TCHECA', 'name': 'First League'},
    {'country': 'GRÉCIA', 'name': 'Super League'},
    {'country': 'CROÁCIA', 'name': 'HNL'},
    {'country': 'SÉRVIA', 'name': 'SuperLiga'},
    {'country': 'ROMÊNIA', 'name': 'Liga I'},
    {'country': 'UCRÂNIA', 'name': 'Premier League'},
    {'country': 'RÚSSIA', 'name': 'Premier League'},
    {'country': 'EUA', 'name': 'MLS'},
    {'country': 'MÉXICO', 'name': 'Liga MX'},
    {'country': 'BRASIL', 'name': 'Brasileirão'},
    {'country': 'BRASIL', 'name': 'Brasileirão Série B'},
    {'country': 'ARGENTINA', 'name': 'Liga Profesional'},
    {'country': 'AMÉRICA DO SUL', 'name': 'Libertadores'},
    {'country': 'AMÉRICA DO SUL', 'name': 'Copa Sudamericana'},
  ];
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 18, 18, 6),
              child: Text('Ligas', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            ),
          ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Text('Principais competições', style: TextStyle(color: Colors.white54)),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final league = mainLeagues[index];
                final name = league['name']!;
                final country = league['country']!;
                final selected = favoriteLeagues.contains(name);
                final games = matches.where((m) => m.league == name).toList();

                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListTile(
                    dense: true,
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: const Icon(Icons.emoji_events_outlined, color: Colors.white70),
                    ),
                    title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(
                      games.isEmpty ? country : '$country  •  ${games.length} jogo(s) hoje',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    trailing: IconButton(
                      tooltip: selected ? 'Remover dos favoritos' : 'Adicionar aos favoritos',
                      onPressed: () => onToggleFavoriteLeague(name),
                      icon: Icon(
                        selected ? Icons.star : Icons.star_border,
                        color: selected ? Colors.amber : Colors.white54,
                      ),
                    ),
                  ),
                );
              },
              childCount: mainLeagues.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 30)),
        ],
      ),
    );
  }
}

class _CompetitionCard
    extends StatelessWidget {
  final String league;
  final List<LiveMatch> matches;

  final void Function(LiveMatch match)
      onOpenMatch;

  const _CompetitionCard({
    required this.league,
    required this.matches,
    required this.onOpenMatch,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 9,
        vertical: 7,
      ),
      child: Card(
        color:
            const Color(0xFF10231A),
        child: ExpansionTile(
          leading: Container(
            width: 42,
            height: 42,
            decoration:
                BoxDecoration(
              color:
                  const Color(
                0xFF18C96E,
              ).withOpacity(.12),
              shape:
                  BoxShape.circle,
            ),
            child: const Icon(
              Icons.emoji_events,
              color:
                  Color(0xFF18C96E),
            ),
          ),
          title: Text(
            league,
            style:
                const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
          subtitle: Text(
            '${matches.length} jogo(s)',
            style:
                const TextStyle(
              color:
                  Colors.white54,
            ),
          ),
          children: matches
              .map(
                (match) => InkWell(
                  onTap: () =>
                      onOpenMatch(
                    match,
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets
                            .fromLTRB(
                      16,
                      8,
                      16,
                      12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            match.home.name,
                            textAlign:
                                TextAlign.end,
                          ),
                        ),
                        const Padding(
                          padding:
                              EdgeInsets
                                  .symmetric(
                            horizontal:
                                10,
                          ),
                          child: Text(
                            'x',
                            style:
                                TextStyle(
                              color:
                                  Colors.white54,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            match.away.name,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _GoalPopupMenu extends StatelessWidget {
  final int selectedGoals;
  final ValueChanged<int> onSelect;
  final VoidCallback onClose;

  const _GoalPopupMenu({
    required this.selectedGoals,
    required this.onSelect,
    required this.onClose,
  });

  String _label(int value) {
    if (value == 0) return '0 - gols';
    if (value == 1) return '1 - gol';
    if (value == 6) return '6+ - gols';
    return '$value - gols';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF0A1A23),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
          boxShadow: const [BoxShadow(blurRadius: 18, spreadRadius: 1, offset: Offset(0, 5), color: Colors.black54)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 8, 4),
              child: Row(
                children: [
                  const Expanded(child: Text('Gols Hoje', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900))),
                  InkWell(onTap: onClose, child: const Icon(Icons.close, size: 17, color: Colors.white38)),
                ],
              ),
            ),
            ...List.generate(7, (i) => InkWell(
                  onTap: () => onSelect(i),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    color: selectedGoals == i ? Colors.red.withOpacity(.16) : Colors.transparent,
                    child: Row(
                      children: [
                        Icon(selectedGoals == i ? Icons.radio_button_checked : Icons.radio_button_off, size: 15, color: selectedGoals == i ? Colors.red : Colors.white38),
                        const SizedBox(width: 8),
                        Text(_label(i), style: TextStyle(color: selectedGoals == i ? Colors.white : Colors.white70, fontSize: 12, fontWeight: selectedGoals == i ? FontWeight.w900 : FontWeight.w600)),
                      ],
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// MATCH CARD
// ============================================================

class _LiveClock extends StatefulWidget {
  final LiveMatch match;
  const _LiveClock({required this.match});

  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  Timer? _timer;
  int seconds = 0;
  int baseMinute = 0;

  @override
  void initState() {
    super.initState();
    baseMinute = widget.match.minute ?? 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => seconds = (seconds + 1) % 60);
    });
  }

  @override
  void didUpdateWidget(covariant _LiveClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.match.minute != oldWidget.match.minute && widget.match.minute != null) {
      baseMinute = widget.match.minute!;
      seconds = 0;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalMinutes = baseMinute + (seconds >= 60 ? 1 : 0);
    final displaySeconds = seconds.toString().padLeft(2, '0');
    return Text(
      '${totalMinutes.toString().padLeft(2, '0')}:$displaySeconds',
      style: const TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.w900),
    );
  }
}

List<int> _goalMinutesForTeam(LiveMatch match, TeamInfo team) {
  final result = <int>[];
  for (final event in match.events) {
    if (event.type != 'goal' || event.minute <= 0) continue;
    final sameId = event.teamId != null && event.teamId == team.id;
    final sameName = event.team != null && event.team!.trim().toLowerCase() == team.name.trim().toLowerCase();
    if (sameId || sameName) result.add(event.minute);
  }
  result.sort();
  return result;
}

class MatchCard extends StatelessWidget {
  final LiveMatch match;
  final bool compact;
  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback onTap;
  final bool favoriteHome;
  final bool favoriteAway;
  final VoidCallback? onFavoriteHome;
  final VoidCallback? onFavoriteAway;

  const MatchCard({
    super.key,
    required this.match,
    this.compact = false,
    required this.favorite,
    required this.onFavorite,
    required this.onTap,
    this.favoriteHome = false,
    this.favoriteAway = false,
    this.onFavoriteHome,
    this.onFavoriteAway,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final live = match.isLive;
    final scoreColor = live
        ? Colors.red
        : match.isFinished
            ? cs.onSurface
            : cs.onSurfaceVariant;

    if (compact) {
      return Material(
        color: cs.surface,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Column(
              children: [
                _compactTeamRow(
                  context: context,
                  team: match.home,
                  score: match.homeScore,
                  scoreColor: scoreColor,
                  live: live,
                  home: true,
                ),
                _compactTeamRow(
                  context: context,
                  team: match.away,
                  score: match.awayScore,
                  scoreColor: scoreColor,
                  live: live,
                  home: false,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: Text(match.league, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12))),
                    Text(match.isLive ? (match.minute != null ? "${match.minute}'" : 'AO VIVO') : _statusLabel(match), style: TextStyle(color: live ? Colors.red : cs.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.bold)),
                    IconButton(visualDensity: VisualDensity.compact, onPressed: onFavorite, icon: Icon(favorite ? Icons.star : Icons.star_border, color: favorite ? Colors.amber : cs.onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(child: _TeamColumn(team: match.home, score: match.homeScore, align: CrossAxisAlignment.end)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        children: [
                          Text(match.isScheduled ? 'x' : '${match.homeScore ?? 0} - ${match.awayScore ?? 0}', style: TextStyle(color: scoreColor, fontSize: 20, fontWeight: FontWeight.w900)),
                          if (live) _LiveClock(match: match),
                          if (match.startTime != null && match.isScheduled) Text(_formatTime(match.startTime!), style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
                        ],
                      ),
                    ),
                    Expanded(child: _TeamColumn(team: match.away, score: match.awayScore, align: CrossAxisAlignment.start)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<MatchEvent> _goalsForTeam(TeamInfo team) {
    return match.events.where((e) {
      if (e.type != 'goal') return false;
      if (e.teamId != null && team.id != 0) return e.teamId == team.id;
      return e.team != null && e.team!.toLowerCase() == team.name.toLowerCase();
    }).toList()..sort((a,b) => a.minute.compareTo(b.minute));
  }

  Widget _goalLabels(TeamInfo team, ColorScheme cs) {
    final goals = _goalsForTeam(team);
    if (goals.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: goals.map((g) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Text('⚽${g.minute}\'', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: cs.onSurfaceVariant)),
      )).toList(),
    );
  }

  Widget _compactTeamRow({
    required BuildContext context,
    required TeamInfo team,
    required int? score,
    required Color scoreColor,
    required bool live,
    required bool home,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isFavorite = home ? favoriteHome : favoriteAway;
    final callback = home ? (onFavoriteHome ?? onFavorite) : (onFavoriteAway ?? onFavorite);
    return SizedBox(
      height: 29,
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 25, minHeight: 25),
              visualDensity: VisualDensity.compact,
              onPressed: callback,
              icon: Icon(isFavorite ? Icons.star : Icons.star_border, size: 18, color: isFavorite ? Colors.amber : cs.onSurfaceVariant),
            ),
          ),
          ClubShield(team: team, size: 23),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              children: [
                Flexible(child: Text(team.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: cs.onSurface))),
                _goalLabels(team, cs),
              ],
            ),
          ),
          if (live && home) ...[
            Text(match.minute != null ? "${match.minute}'" : '•', style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w800)),
            const SizedBox(width: 7),
          ],
          SizedBox(
            width: 26,
            child: Text(match.isScheduled ? '-' : '${score ?? 0}', textAlign: TextAlign.center, style: TextStyle(color: scoreColor, fontSize: 16, fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }
}

class _TeamColumn
    extends StatelessWidget {
  final TeamInfo team;
  final int? score;
  final CrossAxisAlignment align;
  final bool compact;

  const _TeamColumn({
    required this.team,
    required this.score,
    required this.align,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: align,
      children: [
        ClubShield(
          team: team,
          size: compact ? 28 : 44,
        ),
        SizedBox(height: compact ? 4 : 7),
        Text(
          team.name,
          textAlign:
              align == CrossAxisAlignment.end
                  ? TextAlign.end
                  : TextAlign.start,
          maxLines: 2,
          overflow:
              TextOverflow.ellipsis,
          style:
              TextStyle(
            fontWeight:
                FontWeight.w700,
            fontSize: compact ? 11 : 13,
          ),
        ),
      ],
    );
  }
}

// ============================================================
// CLUB SHIELD
// ============================================================

class ClubShield extends StatelessWidget {
  final TeamInfo team;
  final double size;

  const ClubShield({
    super.key,
    required this.team,
    this.size = 46,
  });

  @override
  Widget build(BuildContext context) {
    if (team.logo == null ||
        team.logo!.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration:
            BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius:
              BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.shield,
          size: size * .55,
          color:
              Colors.white54,
        ),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: Image.network(
        team.logo!,
        fit: BoxFit.contain,
        errorBuilder:
            (_, __, ___) {
          return Container(
            decoration:
                BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius:
                  BorderRadius.circular(
                12,
              ),
            ),
            child: Icon(
              Icons.shield,
              size: size * .55,
              color:
                  Colors.white54,
            ),
          );
        },
      ),
    );
  }
}

// ============================================================
// MATCH DETAILS
// ============================================================

class MatchDetailsPage extends StatefulWidget {
  final LiveMatch match;
  final KickoffApiService api;
  final Set<int> favorites;
  final Future<void> Function(int teamId) onToggleFavorite;

  const MatchDetailsPage({
    super.key,
    required this.match,
    required this.api,
    required this.favorites,
    required this.onToggleFavorite,
  });

  @override
  State<MatchDetailsPage> createState() => _MatchDetailsPageState();
}

class _MatchDetailsPageState extends State<MatchDetailsPage>
    with SingleTickerProviderStateMixin {
  late TabController tabs;
  MatchDetails? details;
  List<dynamic> h2h = [];
  bool loading = true;
  bool h2hLoading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 5, vsync: this);
    _load();
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final raw = await widget.api.getFixtureDetails(widget.match.apiId);
      final parsed = _parseDetails(raw);
      if (!mounted) return;
      setState(() {
        details = parsed;
        loading = false;
      });
      _loadH2H(parsed.home.apiId, parsed.away.apiId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  Future<void> _loadH2H(String homeId, String awayId) async {
    if (homeId.isEmpty || awayId.isEmpty) return;
    setState(() => h2hLoading = true);
    try {
      final result = await widget.api.getHeadToHead(homeId, awayId);
      if (!mounted) return;
      setState(() {
        h2h = result;
        h2hLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => h2hLoading = false);
    }
  }

  bool _isHomeEvent(MatchEvent event, MatchDetails match) {
    return event.teamId != null && event.teamId == match.home.id;
  }

  String _periodLabel(MatchEvent event) {
    if (event.minute <= 45) return '1º TEMPO';
    return '2º TEMPO';
  }

  String _eventIcon(MatchEvent event) {
    switch (event.type) {
      case 'goal':
        return '⚽';
      case 'yellow':
        return '🟨';
      case 'red':
        return '🟥';
      case 'substitution':
        return '🔄';
      default:
        return '•';
    }
  }

  Widget _timelineEvent({
    required MatchEvent event,
    required bool home,
  }) {
    final minute = event.minute > 0 ? "${event.minute}'" : '';
    final icon = _eventIcon(event);
    final detail = event.assist == null || event.assist!.trim().isEmpty
        ? event.player
        : '${event.player} (${event.assist})';

    // Sumário no estilo solicitado: todos os eventos alinhados à esquerda.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 38,
          child: Text(minute, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ),
        SizedBox(width: 22, child: Text(icon, style: const TextStyle(fontSize: 15))),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            detail,
            textAlign: TextAlign.left,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeline(MatchDetails match) {
    final firstHalf = match.events.where((e) => e.minute <= 45).toList();
    final secondHalf = match.events.where((e) => e.minute > 45).toList();

    Widget section(String title, List<MatchEvent> events, int? homeScore, int? awayScore) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                Text(
                  '${homeScore ?? 0} - ${awayScore ?? 0}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text('Nenhum evento', style: TextStyle(fontSize: 12)),
            )
          else
            ...events.map((event) {
              final isHome = _isHomeEvent(event, match);
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: .35))),
                ),
                child: _timelineEvent(event: event, home: isHome),
              );
            }),
        ],
      );
    }

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        section('1º TEMPO', firstHalf, firstHalf.isNotEmpty ? match.homeScore : null, firstHalf.isNotEmpty ? match.awayScore : null),
        section('2º TEMPO', secondHalf, match.homeScore, match.awayScore),
        _buildOddsPlaceholder(),
      ],
    );
  }

  Widget _buildOddsPlaceholder() {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ODDS AO VIVO', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: const [
                _MiniDetailChip('1X2'),
                _MiniDetailChip('PRÓXIMO GOL'),
                _MiniDetailChip('ACIMA/ABAIXO'),
                _MiniDetailChip('HANDICAP ASIÁTICO'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Text(
            'Odds ao vivo não disponíveis no plano atual da API.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MatchDetails current = details ?? MatchDetails(
      id: widget.match.id,
      apiId: widget.match.apiId,
      home: widget.match.home,
      away: widget.match.away,
      homeScore: widget.match.homeScore,
      awayScore: widget.match.awayScore,
      status: widget.match.status,
      league: widget.match.league,
      venue: '',
      startTime: widget.match.startTime,
      events: widget.match.events,
    );

    final favorite = widget.favorites.contains(current.home.id) || widget.favorites.contains(current.away.id);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            const Icon(Icons.sports_soccer, size: 19),
            const SizedBox(width: 6),
            const Text('Futebol', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const Icon(Icons.keyboard_arrow_down, size: 18),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Compartilhar',
            icon: const Icon(Icons.ios_share, size: 19),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link da partida pronto para compartilhar.')),
              );
            },
          ),
          IconButton(
            tooltip: 'Favoritar time',
            icon: Icon(favorite ? Icons.star : Icons.star_border, size: 21),
            color: favorite ? Colors.amber : null,
            onPressed: () => widget.onToggleFavorite(current.home.id),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                const Icon(Icons.shield, size: 17),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '${widget.match.country}: ${current.league}'.trim(),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
          _buildMatchHero(current),
          Material(
            color: theme.colorScheme.surface,
            child: TabBar(
              controller: tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
              tabs: const [
                Tab(text: 'SUMÁRIO'),
                Tab(text: 'ESTATÍSTICAS'),
                Tab(text: 'FORMAÇÕES'),
                Tab(text: 'ESTATÍSTICAS DE JOGADOR'),
                Tab(text: 'H2H'),
              ],
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text('Erro ao carregar partida.\n\n$error', textAlign: TextAlign.center),
                        ),
                      )
                    : TabBarView(
                        controller: tabs,
                        children: [
                          _buildTimeline(current),
                          _buildStats(current),
                          _buildLineups(current),
                          _buildPlayerStatsPlaceholder(current),
                          _buildH2H(),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildMatchHero(MatchDetails match) {
    final live = _isLiveStatus(match.status);
    final scoreColor = live ? Colors.red : Theme.of(context).colorScheme.onSurface;
    final dateText = match.startTime == null ? '' : '${_formatDate(match.startTime!)} ${_formatTime(match.startTime!)}';
    final period = _periodText(match.status, widget.match.minute);

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: live ? Colors.red.withValues(alpha: .055) : Theme.of(context).colorScheme.surface,
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: _heroTeam(match.home, true)),
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Text(dateText, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text(
                  '${match.homeScore ?? 0} - ${match.awayScore ?? 0}',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: scoreColor),
                ),
                const SizedBox(height: 2),
                if (live)
                  _LiveClock(match: widget.match)
                else
                  Text(period, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(child: _heroTeam(match.away, false)),
        ],
      ),
    );
  }

  Widget _heroTeam(TeamInfo team, bool home) {
    final favorite = widget.favorites.contains(team.id);
    return Column(
      children: [
        ClubShield(team: team, size: 42),
        const SizedBox(height: 4),
        Text(
          team.name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 1),
        Icon(favorite ? Icons.star : Icons.star_border, size: 14, color: favorite ? Colors.amber : Theme.of(context).colorScheme.onSurfaceVariant),
      ],
    );
  }

  Widget _buildPlayerStatsPlaceholder(MatchDetails match) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Estatísticas individuais dos jogadores ainda não estão disponíveis para esta partida.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _buildStats(MatchDetails match) {
    if (match.stats.isEmpty) {
      return Center(
        child: Text(
          'Estatísticas ainda não disponíveis.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: match.stats.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final stat = match.stats[index];
        return Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(child: Text(stat.home, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
              Expanded(flex: 2, child: Text(stat.label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
              Expanded(child: Text(stat.away, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLineups(MatchDetails match) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _LineupSection(title: match.home.name, players: match.homeLineup),
        const SizedBox(height: 12),
        _LineupSection(title: match.away.name, players: match.awayLineup),
      ],
    );
  }

  Widget _buildH2H() {
    if (h2hLoading) return const Center(child: CircularProgressIndicator());
    if (h2h.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Text(
            'Histórico H2H não disponível para esta partida.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: h2h.length,
      itemBuilder: (context, index) => H2HCard(fixture: h2h[index]),
    );
  }

  bool _isLiveStatus(String status) {
    final s = status.toLowerCase();
    return s.contains('live') || s.contains('inplay') || s.contains('1h') || s.contains('2h') || s.contains('halftime');
  }

  String _periodText(String status, int? minute) {
    final s = status.toLowerCase();
    if (s.contains('finished') || s.contains('ft') || s.contains('ended')) return 'Finalizado';
    if (s.contains('halftime') || s.contains('ht')) return 'Intervalo';
    if (minute != null && minute > 45) return '2º tempo';
    if (minute != null && minute > 0) return '1º tempo';
    return 'A iniciar';
  }
}

class _MiniDetailChip extends StatelessWidget {
  final String label;
  const _MiniDetailChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800)),
    );
  }
}

// ============================================================
// DETAIL COMPONENTS
// ============================================================

class _DetailTeam
    extends StatelessWidget {
  final TeamInfo team;
  final CrossAxisAlignment alignment;

  const _DetailTeam({
    required this.team,
    required this.alignment,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          alignment,
      children: [
        ClubShield(
          team: team,
          size: 62,
        ),
        const SizedBox(
          height: 8,
        ),
        Text(
          team.name,
          textAlign:
              TextAlign.center,
          maxLines: 2,
          overflow:
              TextOverflow.ellipsis,
          style:
              TextStyle(
            fontWeight:
                FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ],
    );
  }
}

class _InfoTile
    extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _InfoTile({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 10,
      ),
      padding:
          const EdgeInsets.all(14),
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF10231A),
        borderRadius:
            BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color:
                const Color(
              0xFF18C96E,
            ),
          ),
          const SizedBox(
            width: 12,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment
                      .start,
              children: [
                Text(
                  title,
                  style:
                      const TextStyle(
                    color:
                        Colors.white54,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(
                  height: 2,
                ),
                Text(
                  value,
                  style:
                      const TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EventRow
    extends StatelessWidget {
  final MatchEvent event;

  const _EventRow({
    required this.event,
  });

  @override
  Widget build(BuildContext context) {
    IconData icon;

    switch (event.type) {
      case 'goal':
        icon = Icons.sports_soccer;
        break;
      case 'yellow':
        icon = Icons.square;
        break;
      case 'red':
        icon = Icons.square;
        break;
      case 'substitution':
        icon =
            Icons.swap_vert;
        break;
      default:
        icon = Icons.circle;
    }

    return Container(
      padding:
          const EdgeInsets.all(13),
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF10231A),
        borderRadius:
            BorderRadius.circular(15),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              event.minute > 0
                  ? "${event.minute}'"
                  : '-',
              style:
                  const TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
          Icon(
            icon,
            size: 20,
            color: event.type ==
                    'goal'
                ? const Color(
                    0xFF18C96E,
                  )
                : event.type ==
                        'yellow'
                    ? Colors.amber
                    : event.type ==
                            'red'
                        ? Colors.red
                        : Colors.white54,
          ),
          const SizedBox(
            width: 12,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment
                      .start,
              children: [
                Text(
                  _eventTitle(
                    event.type,
                  ),
                  style:
                      const TextStyle(
                    color:
                        Colors.white54,
                    fontSize: 12,
                  ),
                ),
                Text(
                  event.player,
                  style:
                      const TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                if (event.assist != null)
                  Text(
                    'Assistência: ${event.assist}',
                    style:
                        const TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _eventTitle(
    String type,
  ) {
    switch (type) {
      case 'goal':
        return 'GOL';
      case 'yellow':
        return 'CARTÃO AMARELO';
      case 'red':
        return 'CARTÃO VERMELHO';
      case 'substitution':
        return 'SUBSTITUIÇÃO';
      default:
        return 'EVENTO';
    }
  }
}

class _LineupSection
    extends StatelessWidget {
  final String title;
  final List<MatchLineup> players;

  const _LineupSection({
    required this.title,
    required this.players,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style:
              const TextStyle(
            fontSize: 19,
            fontWeight:
                FontWeight.w900,
          ),
        ),
        const SizedBox(
          height: 10,
        ),
        if (players.isEmpty)
          const Text(
            'Escalação não disponível.',
            style:
                TextStyle(
              color:
                  Colors.white54,
            ),
          )
        else
          ...players.map(
            (player) => Container(
              margin:
                  const EdgeInsets
                      .only(
                bottom: 5,
              ),
              padding:
                  const EdgeInsets
                      .symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration:
                  BoxDecoration(
                color:
                    const Color(
                  0xFF10231A,
                ),
                borderRadius:
                    BorderRadius
                        .circular(
                  12,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      player.number,
                      style:
                          const TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      player.player,
                      style:
                          const TextStyle(
                        fontWeight:
                            FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    player.position,
                    style:
                        const TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ============================================================
// H2H
// ============================================================

Map<String, dynamic> _normalizeH2HFixture(dynamic raw) {
  final original = _asMap(raw) ?? <String, dynamic>{};
  final nestedFixture = _asMap(original['fixture']);
  final nestedTeams = _asMap(original['teams']);
  final nestedGoals = _asMap(original['goals']);

  final source = <String, dynamic>{
    ...?nestedFixture,
    ...original,
  };

  // KickoffAPI H2H can return teams.home/away and goals.home/away.
  final teams = _asMap(source['teams']) ?? nestedTeams;
  final goals = _asMap(source['goals']) ?? nestedGoals;

  if (teams != null) {
    source['home'] ??= teams['home'];
    source['away'] ??= teams['away'];
  }

  if (goals != null) {
    final currentScore = _asMap(source['score']) ?? <String, dynamic>{};
    currentScore['home'] ??= goals['home'];
    currentScore['away'] ??= goals['away'];
    source['score'] = currentScore;
  }

  // Some responses keep the date inside fixture.date.
  if (source['date'] == null && nestedFixture?['date'] != null) {
    source['date'] = nestedFixture?['date'];
  }

  return source;
}

class H2HCard
    extends StatelessWidget {
  final dynamic fixture;

  const H2HCard({
    super.key,
    required this.fixture,
  });

  @override
  Widget build(BuildContext context) {
    final data = _normalizeH2HFixture(fixture);
    final home =
        _findHomeTeam(data);

    final away =
        _findAwayTeam(data);

    final homeScore =
        _scoreForTeam(
      data,
      home.id,
    );

    final awayScore =
        _scoreForTeam(
      data,
      away.id,
    );

    final events =
        _parseEvents(data);

    final goals = events
        .where(
          (e) => e.type == 'goal',
        )
        .toList();

    final date =
        _findStartTime(data);

    return Container(
      margin:
          const EdgeInsets.only(
        bottom: 12,
      ),
      padding:
          const EdgeInsets.all(16),
      decoration:
          BoxDecoration(
        color:
            const Color(0xFF10231A),
        borderRadius:
            BorderRadius.circular(
          18,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _H2HTeam(
                  team: home,
                  alignment:
                      CrossAxisAlignment
                          .end,
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal: 14,
                ),
                child: Column(
                  children: [
                    Text(
                      '${homeScore ?? 0} - ${awayScore ?? 0}',
                      style:
                          const TextStyle(
                        fontSize: 20,
                        fontWeight:
                            FontWeight.w900,
                      ),
                    ),
                    if (date != null)
                      Text(
                        _formatDate(
                          date,
                        ),
                        style:
                            const TextStyle(
                          color:
                              Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: _H2HTeam(
                  team: away,
                  alignment:
                      CrossAxisAlignment
                          .start,
                ),
              ),
            ],
          ),
          if (goals.isNotEmpty) ...[
            const SizedBox(
              height: 14,
            ),
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.all(
                12,
              ),
              decoration:
                  BoxDecoration(
                color:
                    const Color(
                  0xFF07130E,
                ),
                borderRadius:
                    BorderRadius.circular(
                  12,
                ),
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment
                        .start,
                children: [
                  const Text(
                    '⚽ Gols da partida',
                    style:
                        TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  const SizedBox(
                    height: 8,
                  ),
                  ...goals.map(
                    (goal) => Padding(
                      padding:
                          const EdgeInsets
                              .only(
                        bottom: 5,
                      ),
                      child: Row(
                        children: [
                          Text(
                            "⚽ ${goal.minute}'",
                            style:
                                const TextStyle(
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                          const SizedBox(
                            width: 8,
                          ),
                          Expanded(
                            child: Text(
                              goal.player,
                            ),
                          ),
                          if (goal.team !=
                              null)
                            Text(
                              goal.team!,
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white54,
                                fontSize:
                                    11,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _H2HTeam
    extends StatelessWidget {
  final TeamInfo team;
  final CrossAxisAlignment alignment;

  const _H2HTeam({
    required this.team,
    required this.alignment,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          alignment,
      children: [
        ClubShield(
          team: team,
          size: 40,
        ),
        const SizedBox(
          height: 5,
        ),
        Text(
          team.name,
          textAlign:
              TextAlign.center,
          maxLines: 2,
          overflow:
              TextOverflow.ellipsis,
          style:
              const TextStyle(
            fontSize: 13,
            fontWeight:
                FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

// ============================================================
// UTILITÁRIOS
// ============================================================

bool _isScheduledStatus(
  String status,
) {
  final s =
      status.toLowerCase();

  return s.contains('scheduled') ||
      s.contains('not_started') ||
      s.contains('ns') ||
      s.contains('upcoming');
}

String _detailStatus(
  String status,
) {
  if (_isScheduledStatus(status)) {
    return 'A iniciar';
  }

  final s =
      status.toLowerCase();

  if (s.contains('finished') ||
      s.contains('ft') ||
      s.contains('ended')) {
    return 'Finalizado';
  }

  if (s.contains('halftime') ||
      s.contains('ht')) {
    return 'Intervalo';
  }

  if (s.contains('live') ||
      s.contains('inplay') ||
      s.contains('1h') ||
      s.contains('2h')) {
    return 'Ao vivo';
  }

  return status;
}

String _statusLabel(
  LiveMatch match,
) {
  if (match.isFinished) {
    return 'FINAL';
  }

  if (match.isLive) {
    return match.minute != null
        ? "${match.minute}'"
        : 'AO VIVO';
  }

  if (match.startTime != null) {
    return _formatTime(
      match.startTime!,
    );
  }

  return 'A iniciar';
}

String _dateLabel(
  DateTime date,
) {
  final now = DateTime.now();

  final today = DateTime(
    now.year,
    now.month,
    now.day,
  );

  final target = DateTime(
    date.year,
    date.month,
    date.day,
  );

  final diff =
      target.difference(today).inDays;

  if (diff == 0) {
    return 'Hoje';
  }

  if (diff == 1) {
    return 'Amanhã';
  }

  if (diff == -1) {
    return 'Ontem';
  }

  return _formatDate(date);
}

String _formatTime(
  DateTime date,
) {
  final h =
      date.hour.toString().padLeft(
        2,
        '0',
      );

  final m =
      date.minute.toString().padLeft(
        2,
        '0',
      );

  return '$h:$m';
}

String _formatDate(
  DateTime date,
) {
  final d =
      date.day.toString().padLeft(
        2,
        '0',
      );

  final m =
      date.month.toString().padLeft(
        2,
        '0',
      );

  return '$d/$m/${date.year}';
}

String _formatDateTime(
  DateTime date,
) {
  return '${_formatDate(date)} às ${_formatTime(date)}';
}
