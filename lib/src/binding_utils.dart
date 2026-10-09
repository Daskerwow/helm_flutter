import 'package:flutter/foundation.dart';

import 'helm_controller.dart';
import 'helm_feature.dart';

Never throwFeatureIdentityChanged(String owner) {
  throw FlutterError.fromParts([
    ErrorSummary('$owner не может сменить HelmFeature в существующем Element.'),
    ErrorDescription(
      'Набор фич — часть жизненного цикла Element и должен быть неизменяемым.',
    ),
    ErrorHint(
      'Чтобы переключить фичу, создай новый Element с новым Key, например '
      'ObjectKey(feature).',
    ),
  ]);
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
/// ### Подписывается сразу в конструкторе
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
    try {
      _attach(controller);
      feature.lifecycle.addListener(_onLifecycle);
      _listensToLifecycle = true;
    } catch (_) {
      dispose();
      rethrow;
    }
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
  bool _attached = false;
  bool _listensToLifecycle = false;
  bool _disposed = false;

  void _attach(HelmController<S, E> target) {
    // `detach` безопасен и при частично выполнившемся `attach`: обычные
    // реализации снимают listener no-op-ом. Флаг ставится заранее, чтобы
    // rollback гарантированно освободил даже частично подключённый ресурс.
    _attached = true;
    attach(target);
  }

  void _onLifecycle() {
    if (_disposed || shouldSwap?.call() == false) return;

    final fresh = feature.currentController;
    if (identical(fresh, controller)) return;

    try {
      detach(controller);
      _attached = false;
      controller = fresh;
      _attach(fresh);
    } catch (_) {
      // Старый controller вскоре будет уничтожен владельцем фичи, поэтому
      // откат к нему небезопасен. Завершаем подписку целиком и не оставляем
      // непарный acquire/refCount.
      dispose();
      rethrow;
    }

    onControllerSwapped?.call();
  }

  /// Снимает слушатель, отписывается от [HelmFeature.lifecycle], освобождает
  /// фичу через [HelmFeature.release]. Безопасно вызывать ровно один раз —
  /// повторный вызов — ошибка использования (то же, что и раньше:
  /// `HelmFeature.release` бросает `StateError` на непарный вызов).
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    if (_listensToLifecycle) {
      feature.lifecycle.removeListener(_onLifecycle);
      _listensToLifecycle = false;
    }

    try {
      if (_attached) detach(controller);
    } finally {
      _attached = false;
      feature.release();
    }
  }
}
