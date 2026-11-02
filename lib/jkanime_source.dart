import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:rolostream_core/rolostream_core.dart' as core;

/// Fuente JKAnime (jkanime.net) para RoloStream.
///
///  * Búsqueda y detalle: HTML.
///  * Episodios: `POST /ajax/episodes/{id}/{página}` con el token CSRF (16 por página).
///  * Servidores: arreglo JS `var servers = [...]` en la página del episodio, con la URL
///    de cada embed en Base64 (`remote`).
///  * Directorio (emisión y filtros): JSON incrustado en `var animes = {...}`.
class JKAnimeSource implements core.SourcePlugin {
  JKAnimeSource() {
    _dio = Dio(BaseOptions(
      headers: {
        'User-Agent': _userAgent,
        'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
      followRedirects: true,
      validateStatus: (status) => status != null && status < 500,
    ));
    _dio.interceptors.add(CookieManager(CookieJar()));
  }

  static const _baseUrl = 'https://jkanime.net';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';

  late final Dio _dio;

  @override
  String get id => 'jkanime';

  @override
  String get name => 'JKAnime';

  @override
  String? get iconAsset => null;

  @override
  core.FilterOptions get filterOptions => _filterOptions;

  // ----------------------------------------------------------
  // URLs
  // ----------------------------------------------------------

  /// https://jkanime.net/naruto/  →  naruto
  @override
  String slugFromUrl(String url) {
    final segs = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ?? [];
    return segs.isEmpty ? url : segs.first;
  }

  /// https://jkanime.net/naruto/12/  →  (naruto, 12)
  @override
  ({String slug, int numero})? parseEpisodeUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final m = RegExp(r'^/?([^/]+)/(\d+)/?$').firstMatch(path);
    if (m == null) return null;
    return (slug: m.group(1)!, numero: int.parse(m.group(2)!));
  }

  Future<String> _getHtml(String url, {Map<String, dynamic>? query}) async {
    final res = await _dio.get<String>(
      url,
      queryParameters: query,
      options: Options(responseType: ResponseType.plain),
    );
    return res.data ?? '';
  }

  String _abs(String href) {
    if (href.startsWith('http')) return href;
    return '$_baseUrl/${href.replaceFirst(RegExp(r'^/'), '')}';
  }

  // ----------------------------------------------------------
  // Búsqueda
  // ----------------------------------------------------------

  /// `/buscar?q=...` redirige a `/buscar/{q}` y devuelve el HTML con los resultados.
  @override
  Future<List<core.AnimeResult>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final doc = html_parser.parse(await _getHtml('$_baseUrl/buscar', query: {'q': query.trim()}));

    final seen = <String>{};
    final out = <core.AnimeResult>[];
    for (final item in doc.querySelectorAll('div.anime__item')) {
      final link = item.querySelector('.anime__item__text h5 a') ?? item.querySelector('a');
      final href = link?.attributes['href'] ?? '';
      final titulo = link?.text.trim() ?? '';
      if (href.isEmpty || titulo.isEmpty || !seen.add(href)) continue;
      out.add(core.AnimeResult(
        nombre: titulo,
        url: _abs(href),
        imagen: item.querySelector('.anime__item__pic')?.attributes['data-setbg'] ?? '',
      ));
    }
    return out;
  }

  // ----------------------------------------------------------
  // Detalle
  // ----------------------------------------------------------

  @override
  Future<core.AnimeDetail> getAnime(String slug) async {
    final clean = slugFromUrl(slug);
    final html = await _getHtml('$_baseUrl/$clean/');
    final doc = html_parser.parse(html);

    final info = doc.querySelector('.anime_info');
    final titulo = info?.querySelector('h3')?.text.trim() ?? '';
    if (titulo.isEmpty) throw Exception('No se encontró el anime "$clean" en JKAnime');

    final generos = <String>[];
    for (final li in doc.querySelectorAll('li')) {
      if (li.querySelector('span')?.text.trim().startsWith('Generos') ?? false) {
        generos.addAll(li.querySelectorAll('a').map((a) => a.text.trim()).where((t) => t.isNotEmpty));
        break;
      }
    }

    return core.AnimeDetail(
      titulo: titulo,
      sinopsis: info?.querySelector('p.scroll')?.text.trim() ?? '',
      imagen: doc.querySelector('meta[property="og:image"]')?.attributes['content'] ?? '',
      estado: doc.querySelector('.enemision')?.text.trim() ?? '',
      generos: generos,
      episodios: await _getEpisodes(clean, html, doc),
    );
  }

  /// Episodios vía `POST /ajax/episodes/{id}/{página}` (Laravel: 16 por página).
  /// Si el endpoint falla, se generan de 1 a N con el "Episodios: N" de la ficha.
  Future<List<core.Episode>> _getEpisodes(String slug, String html, Document doc) async {
    core.Episode build(int n, [String? titulo]) => core.Episode(
          numero: n,
          url: '$_baseUrl/$slug/$n/',
          titulo: (titulo == null || titulo.isEmpty) ? 'Episodio $n' : titulo,
        );

    final token = RegExp(r'name="csrf-token" content="([^"]+)"').firstMatch(html)?.group(1);
    final animeId = doc.querySelector('[data-anime]')?.attributes['data-anime'];

    if (token != null && animeId != null) {
      try {
        final first = await _episodesPage(animeId, 1, token, slug);
        final lastPage = (first['last_page'] as num?)?.toInt() ?? 1;
        final pages = <Map<String, dynamic>>[first];
        // Por lotes, para no abrir decenas de conexiones a la vez.
        for (var start = 2; start <= lastPage; start += 5) {
          final end = (start + 4 < lastPage) ? start + 4 : lastPage;
          pages.addAll(await Future.wait([
            for (var p = start; p <= end; p++) _episodesPage(animeId, p, token, slug),
          ]));
        }
        final byNumber = <int, core.Episode>{};
        for (final page in pages) {
          for (final e in (page['data'] as List? ?? const [])) {
            final n = (e['number'] as num?)?.toInt();
            if (n != null) byNumber[n] = build(n, e['title'] as String?);
          }
        }
        if (byNumber.isNotEmpty) return byNumber.values.toList()..sort((a, b) => a.numero.compareTo(b.numero));
      } catch (_) {
        // cae al plan B
      }
    }

    final total = int.tryParse(
            RegExp(r'<span>Episodios:</span>\s*(\d+)').firstMatch(html)?.group(1) ?? '') ??
        0;
    return [for (var n = 1; n <= total; n++) build(n)];
  }

  Future<Map<String, dynamic>> _episodesPage(String animeId, int page, String token, String slug) async {
    final res = await _dio.post<String>(
      '$_baseUrl/ajax/episodes/$animeId/$page',
      data: {'_token': token},
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.plain,
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': '$_baseUrl/$slug/',
        },
      ),
    );
    final json = jsonDecode(res.data ?? '');
    if (json is! Map<String, dynamic>) throw const FormatException('respuesta inesperada');
    return json;
  }

  // ----------------------------------------------------------
  // Servidores
  // ----------------------------------------------------------

  /// La página del episodio trae `var servers = [{remote:"<base64>", server:"VOE", lang:1, ...}]`.
  @override
  Future<List<core.VideoServer>> getServers(String slug, int numero) async {
    final html = await _getHtml('$_baseUrl/${slugFromUrl(slug)}/$numero/');

    final match = RegExp(r'var\s+servers\s*=\s*(\[.*?\])\s*;', dotAll: true).firstMatch(html);
    if (match == null) return [];

    final List<dynamic> raw;
    try {
      raw = jsonDecode(match.group(1)!) as List<dynamic>;
    } on FormatException {
      return [];
    }

    // Idiomas disponibles (`#deflang`): solo se anotan si hay más de uno.
    final langLabels = <String, String>{
      for (final o in html_parser.parse(html).querySelectorAll('#deflang option'))
        o.attributes['value'] ?? '': o.text.trim(),
    };
    final langs = raw.map((e) => '${(e as Map)['lang']}').toSet();

    final out = <core.VideoServer>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final remote = (e['remote'] as String?) ?? '';
      final server = (e['server'] as String?)?.trim() ?? '';
      if (remote.isEmpty || server.isEmpty) continue;
      final String url;
      try {
        url = utf8.decode(base64.decode(base64.normalize(remote))).trim();
      } on FormatException {
        continue;
      }
      if (!url.startsWith('http')) continue;
      final lang = langLabels['${e['lang']}'];
      out.add(core.VideoServer(
        nombre: langs.length > 1 && lang != null && lang.isNotEmpty ? '$server ($lang)' : server,
        url: url,
      ));
    }
    // El reproductor abre el primero: los enlaces de descarga (Mediafire, Mega, 1Fichier) no se
    // pueden reproducir, así que van al final. `sort` de Dart no es estable: se separa.
    bool isDownload(core.VideoServer s) => _downloadHosts.any(s.nombre.toLowerCase().startsWith);
    return [...out.where((s) => !isDownload(s)), ...out.where(isDownload)];
  }

  static const _downloadHosts = ['mediafire', 'mega', '1fichier'];

  // ----------------------------------------------------------
  // Directorio (JSON incrustado en la página)
  // ----------------------------------------------------------

  Future<List<Map<String, dynamic>>> _directory(Map<String, String> query, int page) async {
    final html = await _getHtml('$_baseUrl/directorio', query: {
      ...query,
      if (page > 1) 'p': '$page',
    });
    final m = RegExp(r'var\s+animes\s*=\s*(\{.*?\})\s*;\s*\n', dotAll: true).firstMatch(html);
    if (m == null) return [];
    try {
      final data = (jsonDecode(m.group(1)!) as Map<String, dynamic>)['data'] as List? ?? const [];
      return [for (final e in data) Map<String, dynamic>.from(e as Map)];
    } on FormatException {
      return [];
    }
  }

  /// JKAnime no ofrece una lista de "series recientes": el directorio, ordenado por
  /// fecha (su orden por defecto), es lo más parecido.
  @override
  Future<List<core.RecentSerie>> getRecentSeries() async => [
        for (final a in await _directory(const {}, 1))
          core.RecentSerie(
              titulo: '${a['title']}', url: '${a['url']}', imagen: '${a['image']}'),
      ];

  /// Últimos episodios: la portada los trae ya renderizados en la pestaña `#animes`
  /// (enlace al episodio, miniatura, "Ep 5" y "Ayer"). La lista "recientes" que carga
  /// main.js por AJAX es el historial del usuario y requiere sesión, así que no se usa.
  @override
  Future<List<core.RecentEpisode>> getLatestEpisodes() async {
    final doc = html_parser.parse(await _getHtml('$_baseUrl/'));

    final seen = <String>{};
    final out = <core.RecentEpisode>[];
    for (final card in doc.querySelectorAll('#animes .dir1')) {
      final href = card.querySelector('a')?.attributes['href'] ?? '';
      final titulo = card.querySelector('h5')?.text.trim() ?? '';
      if (titulo.isEmpty || parseEpisodeUrl(href) == null || !seen.add(href)) continue;
      final img = card.querySelector('img');
      out.add(core.RecentEpisode(
        titulo: titulo,
        url: _abs(href),
        imagen: img?.attributes['src'] ?? img?.attributes['data-animepic'] ?? '',
        fecha: card.querySelector('.badge-secondary')?.text.trim() ?? '',
      ));
    }
    return out;
  }

  @override
  Future<List<core.AiringAnime>> getAiringAnimes({int page = 1}) async => [
        for (final a in await _directory(const {'estado': 'emision'}, page))
          core.AiringAnime(
            titulo: '${a['title']}',
            url: '${a['url']}',
            imagen: '${a['image']}',
            tipo: '${a['tipo'] ?? ''}',
            anio: '',
          ),
      ];

  /// `categoria` puede ser `tipo:ovas` o `categoria:latino` (ver [_categorias]).
  @override
  Future<List<core.FilterAnime>> getAnimesByFilter({
    String genero = 'false',
    String fecha = 'false',
    String letra = 'false',
    String categoria = 'false',
    int page = 1,
  }) async {
    final query = <String, String>{
      if (genero != 'false') 'genero': genero,
      if (fecha != 'false') 'fecha': fecha,
      if (letra != 'false') 'letra': letra,
    };
    if (categoria != 'false') {
      final i = categoria.indexOf(':');
      if (i > 0) {
        query[categoria.substring(0, i)] = categoria.substring(i + 1);
      } else {
        query['categoria'] = categoria;
      }
    }
    return [
      for (final a in await _directory(query, page))
        core.FilterAnime(
          titulo: '${a['title']}',
          url: '${a['url']}',
          imagen: '${a['image']}',
          tipo: '${a['tipo'] ?? ''}',
          anio: '',
        ),
    ];
  }
}

final _filterOptions = core.FilterOptions(
  generos: _generos,
  anios: _anios,
  letras: _letras,
  categorias: _categorias,
);

final _letras = <core.FilterOption>[
  for (final c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) core.FilterOption(c, c),
];

// Valores tal como los usa jkanime.net/directorio (select de géneros, años y letras).
const _generos = <core.FilterOption>[
  core.FilterOption('accion', 'Acción'),
  core.FilterOption('aventura', 'Aventura'),
  core.FilterOption('autos', 'Autos'),
  core.FilterOption('comedia', 'Comedia'),
  core.FilterOption('dementia', 'Dementia'),
  core.FilterOption('demonios', 'Demonios'),
  core.FilterOption('misterio', 'Misterio'),
  core.FilterOption('drama', 'Drama'),
  core.FilterOption('ecchi', 'Ecchi'),
  core.FilterOption('fantasia', 'Fantasia'),
  core.FilterOption('juegos', 'Juegos'),
  core.FilterOption('hentai', 'Hentai'),
  core.FilterOption('historico', 'Historico'),
  core.FilterOption('terror', 'Terror'),
  core.FilterOption('nios', 'Niños'),
  core.FilterOption('magia', 'Magia'),
  core.FilterOption('artes-marciales', 'Artes Marciales'),
  core.FilterOption('mecha', 'Mecha'),
  core.FilterOption('musica', 'Musica'),
  core.FilterOption('parodia', 'Parodia'),
  core.FilterOption('samurai', 'Samurai'),
  core.FilterOption('romance', 'Romance'),
  core.FilterOption('colegial', 'Colegial'),
  core.FilterOption('sci-fi', 'Sci-Fi'),
  core.FilterOption('shoujo', 'Shoujo'),
  core.FilterOption('shoujo-ai', 'Shoujo Ai'),
  core.FilterOption('shounen', 'Shounen'),
  core.FilterOption('shounen-ai', 'Shounen Ai'),
  core.FilterOption('space', 'Space'),
  core.FilterOption('deportes', 'Deportes'),
  core.FilterOption('super-poderes', 'Super Poderes'),
  core.FilterOption('vampiros', 'Vampiros'),
  core.FilterOption('yaoi', 'Yaoi'),
  core.FilterOption('yuri', 'Yuri'),
  core.FilterOption('harem', 'Harem'),
  core.FilterOption('cosas-de-la-vida', 'Cosas de la vida'),
  core.FilterOption('sobrenatural', 'Sobrenatural'),
  core.FilterOption('militar', 'Militar'),
  core.FilterOption('policial', 'Policial'),
  core.FilterOption('psicologico', 'Psicologico'),
  core.FilterOption('thriller', 'Thriller'),
  core.FilterOption('seinen', 'Seinen'),
  core.FilterOption('josei', 'Josei'),
  core.FilterOption('latino', 'Español Latino'),
  core.FilterOption('isekai', 'Isekai'),
];

// El directorio separa "tipo" y "categoría"; el contrato solo tiene una lista,
// así que el valor lleva el parámetro delante (`tipo:ovas`, `categoria:latino`).
const _categorias = <core.FilterOption>[
  core.FilterOption('tipo:animes', 'Animes'),
  core.FilterOption('tipo:peliculas', 'Películas'),
  core.FilterOption('tipo:especiales', 'Especiales'),
  core.FilterOption('tipo:ovas', 'OVAs'),
  core.FilterOption('tipo:onas', 'ONAs'),
  core.FilterOption('categoria:donghua', 'Donghua'),
  core.FilterOption('categoria:latino', 'Latino'),
];

final _anios = <core.FilterOption>[
  core.FilterOption('2026', '2026'),
  core.FilterOption('2025', '2025'),
  core.FilterOption('2024', '2024'),
  core.FilterOption('2023', '2023'),
  core.FilterOption('2022', '2022'),
  core.FilterOption('2021', '2021'),
  core.FilterOption('2020', '2020'),
  core.FilterOption('2019', '2019'),
  core.FilterOption('2018', '2018'),
  core.FilterOption('2017', '2017'),
  core.FilterOption('2016', '2016'),
  core.FilterOption('2015', '2015'),
  core.FilterOption('2014', '2014'),
  core.FilterOption('2013', '2013'),
  core.FilterOption('2012', '2012'),
  core.FilterOption('2011', '2011'),
  core.FilterOption('2010', '2010'),
  core.FilterOption('2009', '2009'),
  core.FilterOption('2008', '2008'),
  core.FilterOption('2007', '2007'),
  core.FilterOption('2006', '2006'),
  core.FilterOption('2005', '2005'),
  core.FilterOption('2004', '2004'),
  core.FilterOption('2003', '2003'),
  core.FilterOption('2002', '2002'),
  core.FilterOption('2001', '2001'),
  core.FilterOption('2000', '2000'),
  core.FilterOption('1999', '1999'),
  core.FilterOption('1998', '1998'),
  core.FilterOption('1997', '1997'),
  core.FilterOption('1996', '1996'),
  core.FilterOption('1995', '1995'),
  core.FilterOption('1994', '1994'),
  core.FilterOption('1993', '1993'),
  core.FilterOption('1992', '1992'),
  core.FilterOption('1991', '1991'),
  core.FilterOption('1990', '1990'),
  core.FilterOption('1989', '1989'),
  core.FilterOption('1988', '1988'),
  core.FilterOption('1987', '1987'),
  core.FilterOption('1986', '1986'),
  core.FilterOption('1985', '1985'),
  core.FilterOption('1984', '1984'),
  core.FilterOption('1983', '1983'),
  core.FilterOption('1982', '1982'),
  core.FilterOption('1981', '1981'),
];
