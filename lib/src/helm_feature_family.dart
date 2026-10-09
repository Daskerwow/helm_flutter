import 'package:helm_core/helm_core.dart';

import 'helm_feature.dart';

/// Параметризованный токен фичи — аналог Riverpod `family`-модификатора:
/// одна фабрика Store, ключуемая по произвольному [K], где каждый
/// уникальный ключ получает свой собственный [HelmFeature] — с
/// независимыми refCount/`autoDispose`/`overrideWith`/`lifecycle`, как у
/// любой обычной глобальной фичи.
///
/// ```dart
/// final userProfileFamily = HelmFeatureFamily<String, Loadable<UserProfile>, Never>(
///   (userId) => StateStore(initialState: const Loadable.idle())
///     ..load(() => api.fetchProfile(userId)),
///   autoDispose: true,
/// );
///
/// // где угодно в дереве, для конкретного пользователя:
/// HelmBuilder(userProfileFamily(userId), builder: (_, state) => ...);
/// ```
///
/// ### Family — это кэш "ключ → токен", НЕ новая lifecycle-концепция
/// [call] возвращает самый обычный [HelmFeature] — значит,
/// [HelmFeature.overrideWith] (моки в тестах), `.listen()`,
/// `.watch()`/`.select()`/`.effect()`, зависимости [HelmComputed] работают
/// без единого изменения и без отдельного API у family: получи токен через
/// `family(key)` и обращайся с ним как с любым другим [HelmFeature]. Здесь
/// не продублировано ни строчки lifecycle-логики — family лишь лениво
/// создаёт и кэширует объекты [HelmFeature].
///
/// ### Идентичность ключа — как у `Map`
/// [K] обязан иметь содержательные `==`/`hashCode` (как ключ обычной
/// `Map`), иначе одинаковые по смыслу, но разные по идентичности ключи
/// заведут разные токены с разными Store. Record-типы (`(String userId,
/// int page)`) обычно самый удобный [K] для составных ключей — структурное
/// `==` у record в Dart 3 уже встроено, отдельный класс-ключ не нужен.
///
/// ### Время жизни кэша — отдельно от `autoDispose` каждого токена
/// [autoDispose] управляет только Store конкретного [HelmFeature] по его
/// refCount, как обычно — сама запись "ключ → токен" из кэша family не
/// удаляется автоматически. Это осознанно: если убирать запись сразу же,
/// как только Store закрылся, два подряд идущих обращения `family(key)`
/// (например, виджет пересобирается быстрее, чем успевает подписаться)
/// заводили бы РАЗНЫЕ токены — то есть лишнее пересоздание Store вместо
/// экономии на него. Если кэш ключей всё же нужно ограничивать (много
/// одноразовых ключей за время жизни приложения) — убирай их явно через
/// [remove], когда точно известно, что ключ больше не понадобится, либо
/// [disposeAll] целиком (например, при логауте).
final class HelmFeatureFamily<K, S, E>(
  StateStore<S, E> Function(K key) create, {
  final void Function(K key, E effect)? _onEffect,

  /// См. [HelmFeature.autoDispose] — применяется одинаково к каждому
  /// токену, созданному этой family.
  final bool autoDispose = false,
}) {
  this : _create = create;

  final StateStore<S, E> Function(K key) _create;

  final _features = <K, HelmFeature<S, E>>{};

  /// Токен фичи для [key] — создаётся лениво при первом обращении и
  /// кэшируется: повторный вызов с тем же (по `==`) [key] всегда
  /// возвращает один и тот же объект.
  HelmFeature<S, E> call(K key) => _features.putIfAbsent(key, () {
    final onEffect = _onEffect;
    return HelmFeature<S, E>(
      () => _create(key),
      onEffect: onEffect == null ? null : (effect) => onEffect(key, effect),
      autoDispose: autoDispose,
    );
  });

  /// Уже созданный токен для [key] — `null`, если `family(key)` для этого
  /// ключа ещё ни разу не вызывался. В отличие от [call], сам не создаёт
  /// новую запись.
  HelmFeature<S, E>? peek(K key) => _features[key];

  /// Принудительно закрывает Store для [key] (если он был создан) и убирает
  /// запись из кэша — следующий `family(key)` заведёт полностью новый
  /// токен, а не переиспользует старый. Чтобы просто закрыть Store, сохранив
  /// идентичность токена (как [HelmFeature.dispose]), обращайся к
  /// `family(key).dispose()` напрямую.
  void remove(K key) {
    _features.remove(key)?.dispose();
  }

  /// Закрывает Store для всех когда-либо запрошенных ключей и полностью
  /// очищает кэш — например, при логауте. Каждый последующий `family(key)`
  /// заведёт токены заново, с нуля.
  void disposeAll() {
    for (final feature in _features.values) {
      feature.dispose();
    }
    _features.clear();
  }
}
