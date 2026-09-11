import 'package:flutter/foundation.dart';
import 'package:helm_core/helm_core.dart';

import 'dispatch_proxy.dart';

/// Мост [StateStore] → «голое» Flutter-ядро: [ChangeNotifier] +
/// [ValueListenable], на которых построены [ListenableBuilder],
/// [ValueListenableBuilder], [AnimatedBuilder] и весь остальной core.
///
/// Подписка на Store сделана через `StateStore.addOnChanged` — прямой
/// синхронный слушатель, без `Stream`-подписки и без `dart:async`: та же
/// модель, что и у самого `ChangeNotifier.notifyListeners()`.
///
/// Не создаётся напрямую в обычном коде — управляется [HelmFeature],
/// который лениво создаёт и владеет им. Прямой доступ к [store] остаётся
/// как escape hatch (например, `store.isClosed`).
///
/// Весь dispatch-API (`dispatch`, `dispatchSync`, `cancel` и т.д.) даёт
/// миксин [DispatchProxy] — здесь достаточно указать, куда его пробрасывать.
final class HelmController<S, E>(
  /// Store текущей фичи. Для диспатча используй методы [HelmFeature] — они
  /// короче и не требуют явного `.store`.
  final StateStore<S, E> store,
) extends ChangeNotifier
    with DispatchProxy<S, E>
    implements ValueListenable<S> {
  /// Тело конструктора
  this {
    _unsubscribe = store.addOnChanged((_) => notifyListeners());
  }

  @override
  StateStore<S, E> get dispatchTarget => store;

  late final void Function() _unsubscribe;

  /// Текущее состояние — синхронное чтение без подписки.
  @override
  S get value => store.state;

  /// Алиас [value] для симметрии со старым API/докстрингами.
  S get state => store.state;

  /// Отписывается от [store] и закрывает его. Вызывается [HelmFeature] при
  /// последнем `release()` (если `autoDispose`) или при явном
  /// `HelmFeature.dispose()` — вручную звать не нужно.
  @override
  void dispose() {
    _unsubscribe();
    store.close();
    super.dispose();
  }
}
