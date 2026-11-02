import 'package:jkanime_plugin/jkanime_source.dart';
import 'package:test/test.dart';

void main() {
  final s = JKAnimeSource();

  test('id, nombre y opciones de filtro', () {
    expect(s.id, 'jkanime');
    expect(s.name, 'JKAnime');
    expect(s.filterOptions.generos, isNotEmpty);
    expect(s.filterOptions.anios.first.value, '2026');
    expect(s.filterOptions.categorias.map((o) => o.value), containsAll(['tipo:ovas', 'categoria:latino']));
  });

  test('slugFromUrl', () {
    expect(s.slugFromUrl('https://jkanime.net/naruto/'), 'naruto');
    expect(s.slugFromUrl('https://jkanime.net/naruto/12/'), 'naruto');
    expect(s.slugFromUrl('naruto'), 'naruto');
  });

  test('parseEpisodeUrl', () {
    final ep = s.parseEpisodeUrl('https://jkanime.net/naruto/12/')!;
    expect(ep.slug, 'naruto');
    expect(ep.numero, 12);
    expect(s.parseEpisodeUrl('https://jkanime.net/naruto/'), isNull);
    expect(s.parseEpisodeUrl('https://jkanime.net/'), isNull);
  });
}
