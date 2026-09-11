import 'package:flutter/widgets.dart';

import 'binding_utils.dart';
import 'helm_feature.dart';

/// [StatelessWidget], умеющий `feature.watch()`/`.select()`/`.effect()`
/// прямо в `build()` — без явного `HelmBuilder`/`HelmSelector`/`HelmListener`
/// вокруг.
///
/// Похоже на `HookWidget` из `flutter_hooks`, но без внешней зависимости и
/// без индексации по порядку вызова: биндинги ключуются по идентичности
/// самого [HelmFeature]-токена (см. [HelmReactiveElement]), поэтому
/// `feature.watch()` можно звать из `if`/цикла без риска "съехавшего"
/// состояния.
abstract class HelmWidget extends StatelessWidget {
  const HelmWidget({super.key});

  @override
  StatelessElement createElement() => _StatelessHelmElement(this);
}

class _StatelessHelmElement extends StatelessElement with HelmReactiveElement {
  _StatelessHelmElement(super.widget);
}

/// Как [HelmWidget], но со `State` — когда, помимо `feature.watch()`, нужен
/// собственный `setState`/`initState`/контроллеры анимации.
abstract class StatefulHelmWidget extends StatefulWidget {
  const StatefulHelmWidget({super.key});

  @override
  StatefulElement createElement() => _StatefulHelmElement(this);
}

class _StatefulHelmElement extends StatefulElement with HelmReactiveElement {
  _StatefulHelmElement(super.widget);
}

// ── Внутреннее: биндинги и их хранилище ─────────────────────────────────

enum _BindingKind { watch, select, effect }

typedef _BindingKey = (Object feature, _BindingKind kind);

abstract class _Binding {
  void dispose();
}

/// Общий framework-агностичный скелет "acquire → attach → пережить смену
/// контроллера → release" вынесен в `FeatureSubscription`
/// (`binding_utils.dart`) — используется и здесь, и `_FeatureBindingState`
/// в `helm_builder.dart`, устраняя дублирование, которое раньше
/// поддерживалось отдельно в двух местах. [_WatchBinding]/[_SelectBinding]/
/// [_EffectBinding] ниже — тонкие обёртки поверх [FeatureSubscription]:
/// каждая решает только, что именно вешать на контроллер ([attach]/
/// [detach], переданные в конструктор [FeatureSubscription]) и что делать
/// при смене контроллера (`onControllerSwapped`).
class _WatchBinding<S, E>(
  HelmFeature<S, E> feature,
  final VoidCallback _onChanged,
) implements _Binding {
  this {
    _sub = FeatureSubscription<S, E>(
      feature,
      attach: (c) => c.addListener(_onChanged),
      detach: (c) => c.removeListener(_onChanged),
      onControllerSwapped: _onChanged,
    );
  }

  late final FeatureSubscription<S, E> _sub;

  S get value => _sub.controller.state;

  @override
  void dispose() => _sub.dispose();
}

class _SelectBinding<S, E, R>(
  HelmFeature<S, E> feature,

  /// Переприсваивается на каждый вызов [HelmFeatureReactive.select], чтобы
  /// замыкание всегда было свежим.
  var R Function(S state) selector,
  final VoidCallback _onChanged,
) implements _Binding {
  this {
    _sub = FeatureSubscription<S, E>(
      feature,
      // attach сам инициализирует _value (тем же приёмом, что и
      // `_HelmSelectorState.onBind` в helm_builder.dart) — благодаря этому
      // не нужна отдельная фаза "доинициализировать поля до подписки":
      // attach вызывается синхронно из конструктора FeatureSubscription, и
      // _value гарантированно готово раньше, чем что-либо сможет вызвать
      // _listener.
      attach: (c) {
        _value = selector(c.state);
        c.addListener(_listener);
      },
      detach: (c) => c.removeListener(_listener),
      onControllerSwapped: _listener,
    );
  }

  late final FeatureSubscription<S, E> _sub;
  late R _value;

  R get value => _value;

  void _listener() {
    final next = selector(_sub.controller.state);
    if (next != _value) {
      _value = next;
      _onChanged();
    }
  }

  /// Синхронно пересчитывает значение по актуальному [selector] — вызывается
  /// сразу после переприсваивания `selector` в [HelmFeatureReactive.select],
  /// **до** возврата значения вызывающей стороне. Без этого, если `selector`
  /// поменялся между билдами (замкнул новую переменную из внешнего build),
  /// [_value] оставался бы устаревшим до следующего изменения состояния
  /// фичи. Не вызывает [_onChanged] — мы уже внутри текущего `build()`,
  /// повторный `markNeedsBuild()` здесь не нужен.
  void resync() {
    final next = selector(_sub.controller.state);
    if (next != _value) _value = next;
  }

  @override
  void dispose() => _sub.dispose();
}

class _EffectBinding<S, E>(
  HelmFeature<S, E> feature,

  /// Переприсваивается на каждый вызов [HelmFeatureReactive.effect].
  var void Function(S state) effect,
) implements _Binding {
  this {
    _sub = FeatureSubscription<S, E>(
      feature,
      attach: (c) => c.addListener(_listener),
      detach: (c) => c.removeListener(_listener),
      onControllerSwapped: _handleControllerSwapped,
    );

    // Первый вызов — после текущего кадра, а не синхронно во время build(),
    // как и эффекты в hooks-библиотеках. [_disposed] защищает от вызова на
    // уже отвязанном биндинге, если виджет размонтирован до конца кадра
    // (например, навигация pop сразу после push) — без этой проверки
    // callback всё равно выполнился бы поверх уже освобождённых ресурсов.
    //
    // [_initialCallDone] защищает от ДВОЙНОГО вызова: если lifecycle фичи
    // сработал (overrideWith/принудительный dispose) раньше, чем успел
    // выполниться этот post-frame callback, [_handleControllerSwapped] уже
    // вызвал [effect] с актуальным состоянием нового контроллера — сам
    // post-frame callback в этом случае должен стать no-op, а не позвать
    // effect() второй раз тем же кадром с тем же (или уже следующим)
    // состоянием.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _initialCallDone) return;
      _initialCallDone = true;
      effect(_sub.controller.state);
    });
  }

  late final FeatureSubscription<S, E> _sub;
  bool _disposed = false;

  /// `true`, если начальный вызов [effect] уже случился — либо из
  /// post-frame callback конструктора, либо (раньше него) из
  /// [_handleControllerSwapped].
  bool _initialCallDone = false;

  void _listener() => effect(_sub.controller.state);

  /// Именованный метод, а не инлайн-замыкание прямо в аргументах
  /// конструктора — так явно видно, что `_sub`/`effect`/`_initialCallDone`
  /// читаются в момент ВЫЗОВА этого метода (когда `_sub` уже точно
  /// присвоено), а не в момент создания замыкания (когда `_sub` ещё не
  /// присвоено — мы всё ещё внутри вычисления аргументов конструктора,
  /// которому предстоит быть присвоенным в `_sub`). Технически инлайн-
  /// замыкание было бы так же корректно (Dart захватывает переменные по
  /// ссылке, а первый вызов колбэка в любом случае произойдёт не раньше,
  /// чем в следующем событии), но именованный метод не заставляет
  /// читающего код держать это рассуждение в голове.
  void _handleControllerSwapped() {
    _initialCallDone = true;
    effect(_sub.controller.state);
  }

  @override
  void dispose() {
    _disposed = true;
    _sub.dispose();
  }
}

/// [Element]-миксин, резолвящий `feature.watch()`/`.select()`/`.effect()`.
///
/// ### Почему без "порядка вызовов", в отличие от классических хуков
///
/// Классические хуки индексируют состояние по порядковому номеру вызова
/// внутри `build()` — `useState` внутри `if`/цикла ломает всё. Здесь этой
/// проблемы нет вообще, а не только частично: ключ биндинга — пара (сам
/// объект [HelmFeature], вид биндинга: watch/select/effect), она не
/// зависит ни от места вызова, ни от их количества за билд. Поэтому
/// `feature.watch()`/`.select()`/`.effect()` можно звать условно, в цикле,
/// в любом порядке между перестройками — без ключа и без индексации.
///
/// Если из ОДНОЙ фичи в одном виджете нужно несколько независимых срезов —
/// это не про порядок вызовов, а про то, что `select()` — один вызов на
/// (фича × вид биндинга): несколько срезов собираются в один селектор,
/// возвращающий `record` (структурное `==` по полям встроено в Dart 3) —
/// см. докстринг [HelmFeatureReactive.select].
///
/// Биндинги, не вызванные в очередном `build()`, автоматически
/// освобождаются сразу после него — без утечек и ручного управления.
mixin HelmReactiveElement on ComponentElement {
  static HelmReactiveElement? _current;

  final Map<_BindingKey, _Binding> _bindings = {};

  /// Стек наборов "увиденных в текущем build()" ключей — один элемент на
  /// каждый вложенный/повторный вызов [build] (устойчивость к
  /// `reassemble()`/hot reload, который может вызвать `build()` того же
  /// `Element` не строго последовательно).
  final List<Set<_BindingKey>> _seenStack = [];

  /// Пул уже использованных (очищенных) `Set`-ов для [_seenStack] — без
  /// него каждый [build] аллоцировал бы новый `<_BindingKey>{}`. Для
  /// виджета, перестраивающегося внутри анимации (60 раз в секунду), это
  /// 60 лишних аллокаций в секунду на виджет. Сет из пула переиспользуется
  /// между билдами; новый выделяется только при глубокой реентрантности
  /// (вложенный/повторный [build], например из hot reload), когда пул
  /// пуст.
  final List<Set<_BindingKey>> _setPool = [];

  B _bindingFor<B extends _Binding>(_BindingKey key, B Function() create) {
    assert(
      _seenStack.isNotEmpty,
      'feature.watch()/.select()/.effect() вызваны вне build()',
    );
    _seenStack.last.add(key);
    final existing = _bindings[key];
    if (existing != null) return existing as B;
    final created = create();
    _bindings[key] = created;
    return created;
  }

  @override
  Widget build() {
    final previousCurrent = _current;
    _current = this;
    final seen = _setPool.isNotEmpty ? _setPool.removeLast() : <_BindingKey>{};
    _seenStack.add(seen);
    try {
      return super.build();
    } finally {
      final finished = _seenStack.removeLast();
      _current = previousCurrent;
      _disposeUnseenBindings(finished);
      finished.clear();
      _setPool.add(finished);
    }
  }

  void _disposeUnseenBindings(Set<_BindingKey> seen) {
    _bindings.removeWhere((key, binding) {
      final stale = !seen.contains(key);
      if (stale) binding.dispose();
      return stale;
    });
  }

  @override
  void unmount() {
    for (final binding in _bindings.values) {
      binding.dispose();
    }
    _bindings.clear();
    super.unmount();
  }
}

HelmReactiveElement _requireElement() {
  final element = HelmReactiveElement._current;
  assert(element != null, '''
feature.watch()/.select()/.effect() можно вызывать только внутри build()
виджета, унаследованного от HelmWidget или StatefulHelmWidget. Вне build()
используй feature.value/.read()/.listen() напрямую.
''');
  return element!;
}

/// Короткий реактивный синтаксис прямо на токене фичи — `feature.watch()`
/// вместо ручного `HelmBuilder`. Работает только внутри `build()`
/// [HelmWidget]/[StatefulHelmWidget].
///
/// ```dart
/// class Example extends HelmWidget {
///   const Example({super.key});
///
///   @override
///   Widget build(BuildContext context) {
///     final state = counterFeature.watch();
///     final isEven = counterFeature.select((s) => s.count.isEven);
///     counterFeature.effect((s) => debugPrint('count: ${s.count}'));
///
///     return Scaffold(
///       body: Center(child: Text('Count: ${state.count}')),
///       floatingActionButton: FloatingActionButton(
///         onPressed: () => counterFeature.dispatchSync(const IncrementCommand()),
///         child: const Icon(Icons.add),
///       ),
///     );
///   }
/// }
/// ```
extension HelmFeatureReactive<S, E> on HelmFeature<S, E> {
  /// Подписка на весь `S` + ребилд при каждом изменении — аналог [HelmBuilder].
  S watch() {
    final element = _requireElement();
    final key = (this, _BindingKind.watch);
    return element
        ._bindingFor(
          key,
          () => _WatchBinding<S, E>(this, element.markNeedsBuild),
        )
        .value;
  }

  /// Точечная подписка по срезу состояния — аналог [HelmSelector].
  ///
  /// Если из ОДНОЙ фичи в одном виджете нужно несколько независимых срезов —
  /// не зови `select()` повторно, а верни из одного селектора `record`:
  /// сравнение "не изменилось" у `record` в Dart 3 уже структурное
  /// (`(a, b) == (a, b)`), поэтому это работает без какого-либо
  /// дополнительного API и без ключа:
  ///
  /// ```dart
  /// final (status, ticker) = marketFeature.select(
  ///   (s) => (s.status, s.tickerOf(selectedSymbol)),
  /// );
  /// ```
  R select<R>(R Function(S state) selector) {
    final element = _requireElement();
    final key = (this, _BindingKind.select);
    final binding = element._bindingFor(
      key,
      () => _SelectBinding<S, E, R>(this, selector, element.markNeedsBuild),
    );
    binding.selector = selector;
    // Пересчитываем немедленно: если selector изменился между билдами
    // (захватил новую переменную), значение не должно оставаться
    // устаревшим до следующего изменения состояния фичи.
    binding.resync();
    return binding.value;
  }

  /// Побочный эффект на каждое изменение состояния — аналог [HelmListener].
  /// Несколько независимых реакций на одну фичу — не отдельные вызовы,
  /// а ветвления внутри одного колбэка:
  ///
  /// ```dart
  /// marketFeature.effect((s) {
  ///   _logStatusChange(s.status);
  ///   _syncTitle(s.title);
  /// });
  /// ```
  void effect(void Function(S state) callback) {
    final element = _requireElement();
    final key = (this, _BindingKind.effect);
    final binding = element._bindingFor(
      key,
      () => _EffectBinding<S, E>(this, callback),
    );
    binding.effect = callback;
  }

  /// Синхронное чтение без подписки.
  S read() => value;
}
