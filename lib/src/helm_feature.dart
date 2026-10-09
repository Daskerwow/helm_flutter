import 'package:flutter/foundation.dart';
import 'package:helm_core/helm_core.dart';

import 'binding_utils.dart';
import 'dispatch_proxy.dart';
import 'helm_controller.dart';

/// Непараметризованный контракт токена фичи — минимум, нужный
/// [HelmComputed], чтобы держать чужую фичу живой и слушать её изменения,
/// не зная её конкретных `S`/`E`.
///
/// [HelmController] и так уже [Listenable] — значит [acquireListenable]
/// лишь сужает тип до того, что реально нужно вызывающей стороне, без
/// `dynamic`/приведений типов.
abstract interface class HelmFeatureHandle {
  /// Как [HelmFeature.acquire], но суженный до [Listenable].
  Listenable acquireListenable();

  /// См. [HelmFeature.release].
  void release();

  /// Стабильный (не пересоздаётся) [Listenable], оповещающий о замене
  /// внутреннего контроллера — см. [HelmFeature.lifecycle].
  Listenable get lifecycle;

  /// Актуальный [Listenable] прямо сейчас, без изменения refCount — см.
  /// [HelmFeature.currentController].
  Listenable get currentListenable;

  void disposeIfUnretained();
}

/// Стек активных трекеров зависимостей для [HelmComputed]. Не для
/// использования в коде приложения — только через [trackHelmDependencies].
final _dependencyTrackers = <void Function(HelmFeatureHandle)>[];

/// Выполняет [body], сообщая через [onRead] о каждом обращении к
/// `feature.value` любой [HelmFeature] внутри [body] — так [HelmComputed]
/// узнаёт свои зависимости автоматически. Трекеры вкладываются стеком:
/// вложенный пересчёт отслеживается независимо от внешнего.
T trackHelmDependencies<T>(
  T Function() body,
  void Function(HelmFeatureHandle feature) onRead,
) {
  _dependencyTrackers.add(onRead);
  try {
    return body();
  } finally {
    _dependencyTrackers.removeLast();
  }
}

/// Внутренний стабильный уведомитель о замене контроллера фичи. Живёт всё
/// время жизни [HelmFeature] (в отличие от самого [HelmController], который
/// пересоздаётся) — безопасно подписаться один раз в `initState`/
/// конструкторе и не переподписываться заново.
final class _FeatureLifecycle extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// Глобально адресуемый токен фичи — состояние доступно откуда угодно без
/// обхода дерева виджетов, `InheritedWidget` и кодогенерации.
///
/// [Store] создаётся лениво при первом обращении и живёт синглтоном на
/// время жизни приложения — либо до последнего снятого слушателя, если
/// [autoDispose].
///
/// ```dart
/// final counterFeature = HelmFeature<CounterState, CounterEffect>(
///   () => StateStore(initialState: const CounterState.initial()),
/// );
///
/// counterFeature.dispatchSync(const IncrementCommand(limit: 5));
/// print(counterFeature.value.count);
///
/// HelmBuilder(counterFeature, builder: (context, s) => Text('${s.count}'));
/// ```
///
/// ### `autoDispose`
/// По умолчанию `false` — фича живёт как глобальный singleton (корзина,
/// авторизация, кэш). `true` — Store закрывается автоматически, когда не
/// осталось ни одного `HelmBuilder`/`HelmSelector`/`HelmListener`/[listen]
/// слушателя — для состояния одного экрана.
///
/// Забытый вызов функции отписки [listen] (или непарный [acquire]/
/// [release]) держит Store живым — это осознанный предохранитель от
/// use-after-dispose, а не "тихая" утечка: см. [debugActiveFeatures], чтобы
/// находить такие фичи в тестах (например, `tearDown` с проверкой, что
/// список пуст после каждого теста, ловит забытый `dispose()`/`release()`
/// раньше, чем это станет проблемой в проде).
///
/// ### Внедрение зависимостей
/// Единственный официальный механизм подмены реализации — [overrideWith]
/// прямо на токене: подходит и для тестов (мок вместо реального API), и
/// для конфигурации по окружениям. Подмены образуют настоящий стек — см.
/// докстринг [overrideWith].
///
/// ### Dispatch-API
/// `dispatch`, `dispatchSync`, `cancel` и другие даёт миксин [DispatchProxy]
/// — он же используется [HelmController], поэтому набор методов определён
/// один раз, а не дублируется на каждом уровне обёртки.
final class HelmFeature<S, E>
    with DispatchProxy<S, E>
    implements HelmFeatureHandle {
  HelmFeature(
    StateStore<S, E> Function() create, {
    this.onEffect,
    this.autoDispose = false,
  }) : _factory = create;

  /// Текущая активная фабрика Store — временно подменяется [overrideWith].
  StateStore<S, E> Function() _factory;

  /// Стек фабрик, вытесненных активными [overrideWith] — см. его докстринг.
  /// Debug-режим дополнительно использует длину стека, чтобы предупредить
  /// о восстановлении не в порядке LIFO.
  final _overrideStack = <StateStore<S, E> Function()>[];

  /// Реакция на side-эффекты на уровне всей фичи (навигация/аналитика,
  /// актуальная независимо от того, какой экран сейчас активен). Для
  /// локальной реакции в части дерева используй [HelmListener].
  final void Function(E effect)? onEffect;

  /// См. докстринг класса, раздел "autoDispose".
  final bool autoDispose;

  HelmController<S, E>? _controller;
  int _refCount = 0;
  void Function()? _effectUnsubscribe;

  final _lifecycle = _FeatureLifecycle();

  /// Реестр всех [HelmFeature] с активным (созданным) Store — только в
  /// debug-режиме (мутации обёрнуты в `assert`, поэтому в release не стоят
  /// ничего). Инструмент диагностики утечек: фича, которая должна была
  /// закрыться (`autoDispose: true`, последний `release()` вызван), но
  /// осталась в этом множестве — сигнал забытого `acquire()`/`listen()`
  /// без парного снятия.
  ///
  /// ```dart
  /// tearDown(() {
  ///   expect(HelmFeature.debugActiveFeatures, isEmpty,
  ///       reason: 'Фича осталась активной между тестами — забыт release()');
  /// });
  /// ```
  static final _debugActiveFeatures = <HelmFeature>{};

  /// См. докстринг поля [_debugActiveFeatures]. Возвращает снимок —
  /// изменения реестра после вызова на него не влияют.
  static Set<HelmFeature> get debugActiveFeatures =>
      Set<HelmFeature>.unmodifiable(_debugActiveFeatures);

  HelmController<S, E> get _ctrl {
    final existing = _controller;
    if (existing != null) return existing;
    final created = HelmController<S, E>(_factory());
    _controller = created;
    final callback = onEffect;
    if (callback != null) {
      _effectUnsubscribe = created.store.addOnEffect(callback);
    }

    assert(() {
      _debugActiveFeatures.add(this);
      return true;
    }());

    return created;
  }

  @override
  @protected
  StateStore<S, E> get dispatchTarget => _ctrl.store;

  /// Текущее состояние — синхронное чтение без подписки и без context.
  /// Создаёт Store при первом обращении.
  ///
  /// Вызванный внутри compute-функции [HelmComputed], дополнительно
  /// регистрирует эту фичу как её зависимость.
  S get value {
    if (_dependencyTrackers.isNotEmpty) _dependencyTrackers.last(this);
    return _ctrl.state;
  }

  /// `true`, если Store фичи создан и активен.
  bool get isActive => _controller != null;

  /// Есть ли у фичи активные владельцы: Flutter-виджеты, `listen()` или
  /// [HelmComputed]. Нужен владельцам коллекций фич, чтобы не уничтожать
  /// запись, которая ещё используется живым UI.
  bool get hasRetainers => _refCount > 0;

  /// Уведомляет о замене внутреннего [HelmController] — срабатывает на
  /// [overrideWith] и на принудительный [dispose]. В отличие от самого
  /// [HelmController], не пересоздаётся — безопасно подписаться один раз.
  ///
  /// [HelmBuilder]/[HelmSelector]/[HelmListener] и `feature.watch()`/
  /// `.select()`/`.effect()` подписываются на него автоматически: уже
  /// смонтированные виджеты сами переподключаются к новому контроллеру.
  @override
  Listenable get lifecycle => _lifecycle;

  /// Актуальный контроллер прямо сейчас, без изменения refCount. Создаёт
  /// Store, если он ещё не создан.
  HelmController<S, E> get currentController => _ctrl;

  @override
  Listenable get currentListenable => _ctrl;

  @override
  void disposeIfUnretained() {
    if (autoDispose && _refCount == 0) _disposeInternal();
  }

  /// Подписка на изменения состояния в обход виджетов — участвует в том же
  /// подсчёте ссылок, что и `HelmBuilder`/`HelmSelector`/`HelmListener`.
  /// Реализован через [FeatureSubscription] (`binding_utils.dart`) — тот же
  /// общий скелет "acquire → attach → пережить смену контроллера →
  /// release", которым пользуются все остальные биндинги; парность
  /// `acquire()`/`release()` тем самым гарантирована в одном месте, а не
  /// повторена здесь вручную. Для фичи с `autoDispose: true` достаточно
  /// честно вызвать возвращённую функцию — Store закроется, если больше
  /// никто его не держит; забытый вызов, как и раньше, держит Store живым
  /// (предохранитель от use-after-dispose, а не утечка — но см.
  /// [debugActiveFeatures], чтобы такие случаи не оставались незамеченными
  /// в тестах).
  ///
  /// Переподключается к новому [HelmController] после `overrideWith`/
  /// принудительного [dispose] так же, как `HelmBuilder`/`feature.watch()`.
  ///
  /// Возвращает функцию отписки, безопасную к повторному вызову (idempotent)
  /// — в отличие от [FeatureSubscription.dispose] самой по себе, которая
  /// бросает на повторный вызов; идемпотентность здесь добавлена поверх неё
  /// явным флагом, а не изменением контракта [FeatureSubscription].
  void Function() listen(void Function(S state) onChange) {
    late final FeatureSubscription<S, E> subscription;
    void listener() => onChange(subscription.controller.state);

    subscription = FeatureSubscription<S, E>(
      this,
      attach: (controller) => controller.addListener(listener),
      detach: (controller) => controller.removeListener(listener),
    );

    var released = false;
    return () {
      if (released) return;
      released = true;
      subscription.dispose();
    };
  }

  // ── Внутреннее: используется HelmBuilder/HelmSelector/HelmListener/HelmComputed ──

  /// Регистрирует нового слушателя и возвращает актуальный контроллер. Не
  /// для вызова в коде команд/сервисов — используй [value]/`dispatch`/[listen].
  HelmController<S, E> acquire() {
    final controller = _ctrl;
    _refCount++;
    return controller;
  }

  @override
  Listenable acquireListenable() => acquire();

  /// Снимает регистрацию слушателя. При `autoDispose: true` и обнулении
  /// счётчика — закрывает Store.
  ///
  /// Счётчик независим от того, сколько раз пересоздавался [HelmController]
  /// (см. [lifecycle]) — принудительный [dispose]/[overrideWith] его не
  /// сбрасывает.
  ///
  /// Вызов без парного [acquire]/[acquireListenable]/[listen] — ошибка
  /// использования. Бросает [StateError] **во всех сборках**, включая
  /// release: тихий no-op здесь означал бы, что счётчик рефов молча ушёл в
  /// рассинхрон, а следующий, уже корректный `release()` закроет Store
  /// раньше времени — use-after-dispose где-то в проде, который на порядок
  /// сложнее диагностировать постфактум, чем громкое падение в момент самой
  /// ошибки использования.
  @override
  void release() {
    if (_refCount <= 0) {
      throw StateError(
        'Helm: HelmFeature.release() вызван без соответствующего '
        'acquire()/acquireListenable()/listen(). Проверь парность вызовов — '
        'частые причины: забытый unsubscribe от listen(), двойной '
        'dispose() виджета, release() в неверном месте жизненного цикла.',
      );
    }

    _refCount--;
    if (_refCount <= 0 && autoDispose) _disposeInternal();
  }

  /// Принудительно закрывает Store прямо сейчас, независимо от
  /// `autoDispose`/refCount (например, при логауте для фичи-синглтона).
  /// Следующее обращение пересоздаст Store через текущую фабрику.
  ///
  /// Уже смонтированные биндинги узнают об этом через [lifecycle] и сами
  /// переподключатся к новому контроллеру при следующем обращении.
  void dispose() => _disposeInternal();

  /// Единственный официальный способ внедрения зависимостей: временно
  /// подменяет фабрику, из которой [HelmFeature] лениво создаёт свой
  /// [StateStore].
  ///
  /// ```dart
  /// test('shows loaded todos', () {
  ///   final restore = todosFeature.overrideWith(
  ///     () => StateStore(initialState: Loadable.data(fakeTodos)),
  ///   );
  ///   addTearDown(restore);
  ///   expect(todosFeature.value.valueOrNull, fakeTodos);
  /// });
  /// ```
  ///
  /// Возвращает функцию восстановления, **идемпотентную для успешного
  /// восстановления**: повторный вызов после того, как оно уже прошло
  /// (например, случайно и в `tearDown`, и вручную) — no-op, а не лишнее
  /// пересоздание Store и повторный [lifecycle]-`bump()` для всех
  /// биндингов. Восстановление, упавшее из-за нарушения LIFO (см. ниже),
  /// идемпотентным не считается: стек подмен в этом случае не тронут,
  /// поэтому повторный вызов — не no-op, а новая попытка, и она
  /// корректно завершится успехом, если к этому моменту порядок
  /// восстановления снаружи уже исправлен.
  ///
  /// ### Настоящий стек подмен
  ///
  /// Вложенные `overrideWith` образуют настоящий стек (см. [_overrideStack]):
  /// каждый вызов кладёт текущую фабрику наверх стека перед подменой, а
  /// восстановление снимает её обратно. Пока восстановления вызываются в
  /// порядке LIFO (обычный случай — `addTearDown` в обратном порядке
  /// регистрации), поведение то же, что и при простом "запомнить
  /// предыдущую фабрику". Восстановление НЕ в порядке LIFO (например,
  /// внешний `overrideWith` восстановлен раньше вложенного) — ошибка
  /// использования, и функция восстановления бросает [StateError] **во
  /// всех сборках**: молчаливое восстановление верхушки стека в этом случае
  /// подставило бы не ту фабрику, которую вызывающий код ожидал, и без
  /// явного падения это осталось бы незамеченным до первого странного бага
  /// в проде.
  void Function() overrideWith(StateStore<S, E> Function() create) {
    _overrideStack.add(_factory);
    final expectedStackLength = _overrideStack.length;

    _factory = create;
    if (isActive) _disposeInternal();

    var restored = false;
    return () {
      if (restored) return;

      if (_overrideStack.length != expectedStackLength) {
        throw StateError(
          'Helm: overrideWith() восстановлен не в порядке LIFO — между '
          'подменой и восстановлением этого overrideWith кто-то ещё не '
          'восстановил свой. Оборачивай overrideWith/restore строго парами '
          '(например, через addTearDown сразу после каждого overrideWith). '
          'Стек подмен не тронут — почини порядок восстановления снаружи и '
          'вызови restore() ещё раз.',
        );
      }

      restored = true;
      final previous = _overrideStack.removeLast();
      _factory = previous;
      if (isActive) _disposeInternal();
    };
  }

  void _disposeInternal() {
    final controller = _controller;
    if (controller == null) return;

    _effectUnsubscribe?.call();
    _effectUnsubscribe = null;
    _controller = null;

    assert(() {
      _debugActiveFeatures.remove(this);
      return true;
    }());

    // Порядок принципиален: сначала bump() — держатели (swapController в
    // HelmBuilder/watch/select/effect/listen/HelmComputed) переподключаются
    // к новому контроллеру и снимают listener со старого, пока тот ЕЩЁ жив.
    // dispose() старого HelmController выполняется только после этого. В
    // обратном порядке держатели вызывали бы removeListener() на уже
    // disposed ChangeNotifier — в debug-режиме Flutter это ассерт
    // (_debugAssertNotDisposed) при каждом overrideWith()/принудительном
    // dispose() на смонтированном биндинге.
    _lifecycle.bump();
    controller.dispose();
  }
}
