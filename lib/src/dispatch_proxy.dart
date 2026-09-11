import 'package:flutter/foundation.dart';
import 'package:helm_core/helm_core.dart';

/// Пробрасывает весь dispatch-API `StateStore` на объект, который знает,
/// как добраться до актуального `StateStore` (через геттер [dispatchTarget]).
///
/// Композиция вместо наследования: и `HelmController`, и `HelmFeature`
/// подмешивают этот миксин, не становясь при этом друг для друга ни
/// родителем, ни потомком — у них просто общий фрагмент поведения.
///
/// [dispatchTarget] помечен [protected]: это внутренний контракт между
/// миксином и его двумя потребителями, а не часть публичного API, которым
/// пользуется код приложения. Обычный `_`-приватный член здесь не подошёл
/// бы: приватные имена в Dart видны только внутри одного файла-библиотеки,
/// а `HelmController` и `HelmFeature` реализуют этот геттер каждый в своём
/// файле.
mixin DispatchProxy<S, E> {
  /// Store, на который пробрасываются вызовы. У [HelmController] это его
  /// собственное поле `store`; у `HelmFeature` — `store` актуального
  /// контроллера (`currentController.store`).
  @protected
  StateStore<S, E> get dispatchTarget;

  Future<DispatchResult<S>> dispatchAsync(AsyncCommand<S> command) =>
      dispatchTarget.dispatchAsync(command);

  Future<DispatchResult<S>> dispatchAsyncWithEffect(
    AsyncSideEffect<S, E> command,
  ) => dispatchTarget.dispatchAsyncWithEffect(command);

  DispatchResult<S> dispatchSync(SyncCommand<S> command) =>
      dispatchTarget.dispatchSync(command);

  DispatchResult<S> dispatchSyncWithEffect(SyncSideEffect<S, E> command) =>
      dispatchTarget.dispatchSyncWithEffect(command);

  void dispatchStream(StreamCommand<S> command) =>
      dispatchTarget.dispatchStream(command);

  void dispatchStreamWithEffect(StreamSideEffect<S, E> command) =>
      dispatchTarget.dispatchStreamWithEffect(command);

  void cancel<U>() => dispatchTarget.cancel<U>();

  /// Отменяет async-команду с явным [DispatchKeyed.dispatchKey].
  void cancelKey(Object key) => dispatchTarget.cancelKey(key);

  void cancelAll() => dispatchTarget.cancelAll();

  void cancelStream<U>() => dispatchTarget.cancelStream<U>();

  /// Отменяет Stream-команду с явным [DispatchKeyed.dispatchKey].
  void cancelStreamKey(Object key) => dispatchTarget.cancelStreamKey(key);
}
