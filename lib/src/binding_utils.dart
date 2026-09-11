import 'helm_controller.dart';
import 'helm_feature.dart';

/// Общий паттерн "переподключиться к новому контроллеру фичи после
/// `overrideWith`/принудительного `dispose`" — используется всеми
/// биндингами моста ([HelmBuilder]/[HelmSelector]/[HelmListener],
/// `feature.watch()`/`.select()`/`.effect()`, [HelmComputed]).
///
/// Спрашивает [HelmFeature.currentController], сравнивает `identical` со
/// старым и, если он реально сменился, снимает слушателя со старого и
/// вешает на новый. Что именно делать с "значением" после смены
/// (setState/пересчитать selector/дёрнуть effect) — решает вызывающий код.
HelmController<S, E>? swapController<S, E>({
  required HelmFeature<S, E> feature,
  required HelmController<S, E> current,
  required void Function(HelmController<S, E> controller) removeListener,
  required void Function(HelmController<S, E> controller) addListener,
}) {
  final fresh = feature.currentController;
  if (identical(fresh, current)) return null;

  removeListener(current);
  addListener(fresh);

  return fresh;
}

/// Общий, НЕ завязанный ни на `State`, ни на `Element` скелет "подписаться
/// на фичу, пережить `overrideWith`/принудительный `dispose`, отписаться" —
/// устраняет дублирование, которое иначе пришлось бы поддерживать отдельно
/// в `_FeatureBindingState` (`helm_builder.dart`, миксин на `State<W>`) и
/// биндингах `feature.watch()`/`.select()`/`.effect()` (`helm_reactive.dart`):
/// обе стороны делают ровно то же самое — `acquire()` при старте, подписка
/// на [HelmFeature.lifecycle], [swapController] при смене контроллера,
/// `release()` при уничтожении — отличаясь только тем, что именно
/// происходит после смены контроллера (`setState`/пересчитать
/// selector/дёрнуть effect).
///
/// ### Подписывается сразу в конструкторе — никакого отдельного `start()`
///
/// Первая версия этого класса требовала явного `..start()` после
/// конструктора (чтобы вызывающий код успел доинициализировать поля вроде
/// закэшированного значения selector'а до первого [attach]). На практике
/// это оказалось лишним источником ошибок: пропущенный `start()` не даёт
/// ошибки компиляции — просто тихо неработающую подписку. Вместо этого
/// [attach] сам отвечает за любую нужную инициализацию (см. `_SelectBinding`
/// в `helm_reactive.dart`, где `attach` теперь одним действием и вычисляет
/// исходное значение, и вешает слушатель — тот же приём, что уже
/// использовался в `_HelmSelectorState.onBind` из `helm_builder.dart`).
/// [attach] вызывается синхронно из конструктора, поэтому к моменту, когда
/// вызывающий код получает готовый объект, подписка уже полностью активна.
///
/// ### [onControllerSwapped]/[shouldSwap] — `final`, задаются только в
/// конструкторе
///
/// Не мутируются после создания: то, что должно произойти после смены
/// контроллера, известно вызывающему коду уже в момент создания подписки —
/// откладывать присвоение до "после конструктора" незачем и только даёт
/// лишнее окно для ошибки (забыть присвоить/присвоить не то).
class FeatureSubscription<S, E> {
  FeatureSubscription(
    this.feature, {
    required this.attach,
    required this.detach,
    this.onControllerSwapped,
    this.shouldSwap,
  }) : controller = feature.acquire() {
    attach(controller);
    feature.lifecycle.addListener(_onLifecycle);
  }

  final HelmFeature<S, E> feature;

  /// Вешает специфичный для потребителя слушатель на переданный контроллер
  /// — и, если нужно, инициализирует любое собственное состояние
  /// потребителя (например, закэшированное значение selector'а). Вызывается
  /// синхронно из конструктора и повторно при каждой смене контроллера.
  final void Function(HelmController<S, E> controller) attach;

  /// Снимает слушатель, навешенный [attach].
  final void Function(HelmController<S, E> controller) detach;

  /// Вызывается сразу после переподключения к новому контроллеру — `null`
  /// по умолчанию (ничего не делает).
  final void Function()? onControllerSwapped;

  /// Опциональный предохранитель, проверяемый в начале [_onLifecycle]. Если
  /// задан и возвращает `false` — обмен контроллером в этот раз полностью
  /// пропускается: ни [detach]/[attach], ни [onControllerSwapped] не
  /// вызываются, [controller] не меняется. Нужен `State`-биндингам
  /// (`helm_builder.dart`), где `feature.lifecycle` теоретически может
  /// сработать в узком окне, когда `State` уже не `mounted`, но
  /// собственный `dispose` ещё не успел снять подписку — трогать
  /// `onBind`/`onUnbind` немонтированного `State` небезопасно, поэтому весь
  /// обмен целиком пропускается, а не только реакция на него.
  final bool Function()? shouldSwap;

  /// Актуальный контроллер — переприсваивается в [_onLifecycle] при смене.
  HelmController<S, E> controller;

  void _onLifecycle() {
    if (shouldSwap?.call() == false) return;

    final fresh = swapController<S, E>(
      feature: feature,
      current: controller,
      removeListener: detach,
      addListener: attach,
    );
    if (fresh == null) return;

    controller = fresh;
    onControllerSwapped?.call();
  }

  /// Снимает слушатель, отписывается от [HelmFeature.lifecycle], освобождает
  /// фичу через [HelmFeature.release]. Безопасно вызывать ровно один раз —
  /// повторный вызов — ошибка использования (то же, что и раньше:
  /// `HelmFeature.release` бросает `StateError` на непарный вызов).
  void dispose() {
    detach(controller);
    feature.lifecycle.removeListener(_onLifecycle);
    feature.release();
  }
}
