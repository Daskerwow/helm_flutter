import 'package:flutter/foundation.dart';
import 'package:helm_core/helm_core.dart';

import 'helm_feature.dart';

/// Реактивно пересчитываемое значение из произвольного числа фич — аналог
/// нескольких `ref.watch(...)` в одном Riverpod-провайдере, но как обычный
/// [Listenable], без `ref`/`context`/кодогенерации.
///
/// Зависимости не перечисляются вручную — определяются автоматически по
/// факту обращения к `feature.value` внутри [compute]:
/// - лишняя зависимость — это просто ещё один `feature.value` в той же
///   функции, без фабрики под конкретное число фич;
/// - зависимости могут быть динамическими/условными — набор подписок
///   пересчитывается на каждый re-run;
/// - `acquire`/`release` зависимых фич полностью автоматизированы.
///
/// Отслеживается только чтение через `feature.value` (в т.ч. косвенно —
/// `feature.read()` — алиас на тот же геттер). Если код внутри [compute]
/// как-то иначе достаёт состояние фичи в обход `value` (что штатным API
/// Helm не предусмотрено), такая зависимость трекером не увидится.
///
/// В частности, [HelmComputed] сам не реализует [HelmFeatureHandle] и не
/// участвует в автотрекинге: чтение `.value` **другого** [HelmComputed]
/// внутри [compute] не станет отслеженной зависимостью — этот вложенный
/// `HelmComputed` не будет ни `acquire()`-нут, ни переподключен на
/// изменения. Компонуй несколько фич напрямую в одном [compute] вместо
/// вложенности `HelmComputed` в `HelmComputed`.
///
/// ### Сравнение значений — [equals]
/// По умолчанию новое значение сравнивается со старым через `==`. Если `T`
/// — мутируемая коллекция без содержательного `==`, передай свой компаратор
/// — например, готовый `listEquals`/`setEquals`/`mapEquals` из
/// `equality.dart`:
///
/// ```dart
/// final visibleIds = helmCompute(
///   () => todosFeature.value.items.map((t) => t.id).toSet(),
///   equals: setEquals,
/// );
/// ```
///
/// Не предназначен для создания вручную в `build()` — используй [helmCompute]
/// и держи результат в `late final` поле состояния либо top-level:
///
/// ```dart
/// final cartTotal = helmCompute(
///   () => cartFeature.value.items.fold(0.0, (sum, item) => sum + pricingFeature.value.priceOf(item)),
/// );
///
/// ListenableBuilder(
///   listenable: cartTotal,
///   builder: (context, _) => Text('${cartTotal.value}'),
/// )
/// ```
///
/// ### Переживает `overrideWith`/принудительный `dispose` зависимости
/// Если у зависимой фичи подменили/закрыли Store, [HelmComputed] сам
/// переподключится к новому контроллеру через `HelmFeatureHandle.lifecycle`.
///
/// ### Диагностика забытого `dispose()` — [debugActiveComputed]
/// Симметрично `HelmFeature.debugActiveFeatures`: каждый живой (не
/// задиспозенный) [HelmComputed] регистрируется здесь только в debug-режиме
/// (мутации обёрнуты в `assert`, в release ничего не стоят). Забытый
/// `dispose()` держит зависимые фичи `acquire()`-нутыми — этот реестр
/// позволяет ловить такие утечки в тестах тем же приёмом, что и для
/// `HelmFeature`:
///
/// ```dart
/// tearDown(() {
///   expect(HelmComputed.debugActiveComputed, isEmpty,
///       reason: 'HelmComputed остался активным между тестами — забыт dispose()');
/// });
/// ```
///
/// ### Почему [_evaluate] и [_recompute] не объединены в один метод
/// Оба делают "track + sync зависимостей", но с разной семантикой ошибок:
/// [_evaluate] (вызывается только из конструктора) НЕ синхронизирует
/// зависимости, если [_compute] бросил исключение — иначе частично
/// отслеженные фичи оказались бы `acquire()`-нуты без единого шанса на
/// `release()` (конструктор не вернул объект → [dispose] никогда не
/// вызовется → утечка refCount). [_recompute] же обязан синхронизировать
/// зависимости даже при ошибке — объект уже живёт, и дальнейшие изменения
/// уже отслеженных зависимостей не должны потеряться. Общий хелпер скрыл бы
/// эту разницу и был бы либо неверен для конструктора, либо для recompute.
class HelmComputed<T>(
  final T Function() _compute, {
  bool Function(T a, T b)? equals,

  /// Обработчик исключений из [_compute]. Без него исключение из [_compute]
  /// пробрасывается наружу как обычно (конструктор бросает; [_recompute]
  /// бросает из колбэка `addListener`). Если задан — [_recompute] его
  /// вызывает и оставляет [value] равным последнему успешному значению
  /// вместо падения; зависимости, отслеженные до точки исключения, всё
  /// равно синхронизируются — реакция на дальнейшие изменения не теряется.
  final void Function(Object error, StackTrace stackTrace)? onError,

  /// Наследуемся от ChangeNotifier()
}) extends ChangeNotifier {
  this : _equals = equals ?? (defaultEquals<T>) {
    _value = _evaluate();

    assert(() {
      _debugActiveComputed.add(this);
      return true;
    }());
  }

  final bool Function(T a, T b) _equals;
  late T _value;

  /// Активные зависимости: непараметризованный токен фичи → её [Listenable]
  /// (в реальности `HelmController<S, E>`, суженный через
  /// [HelmFeatureHandle.acquireListenable]).
  final _deps = <HelmFeatureHandle, Listenable>{};

  /// Защита от реентрантного вызова [_recompute] изнутри самого себя —
  /// например, если [_compute] синхронно триггерит изменение одной из
  /// собственных зависимостей. Без гарда это стек-оверфлоу; с ним —
  /// внутренний вызов просто не выполняет вложенный пересчёт (внешний
  /// вызов и так пересчитает актуальное значение по завершении).
  bool _recomputing = false;
  bool _recomputeRequested = false;
  bool _disposed = false;

  /// См. докстринг класса, раздел "Диагностика забытого dispose()" — только
  /// debug-режим, мутации обёрнуты в `assert`.
  static final _debugActiveComputed = <HelmComputed>{};

  /// См. докстринг поля [_debugActiveComputed]. Возвращает снимок —
  /// изменения реестра после вызова на него не влияют.
  static Set<HelmComputed> get debugActiveComputed =>
      Set<HelmComputed>.unmodifiable(_debugActiveComputed);

  /// Текущее вычисленное значение — синхронное чтение без подписки.
  T get value => _value;

  T _evaluate() {
    final tracked = <HelmFeatureHandle>{};
    try {
      final result = trackHelmDependencies(_compute, tracked.add);
      _syncDependencies(tracked);
      return result;
    } catch (_) {
      _releaseDependencies();
      for (final feature in tracked) {
        feature.disposeIfUnretained();
      }
      rethrow;
    }
  }

  void _syncDependencies(Set<HelmFeatureHandle> tracked) {
    // Сначала присоединяем новые зависимости. Если их фабрика или подписка
    // бросит исключение, старый граф остаётся рабочим и может инициировать
    // следующую попытку вычисления.
    for (final feature in tracked) {
      if (_deps.containsKey(feature)) continue;
      _attachDependency(feature);
    }

    _deps.removeWhere((feature, listenable) {
      if (tracked.contains(feature)) return false;

      listenable.removeListener(_recompute);
      feature.lifecycle.removeListener(_onDependencyLifecycle);
      feature.release();

      return true;
    });
  }

  void _attachDependency(HelmFeatureHandle feature) {
    final listenable = feature.acquireListenable();
    try {
      listenable.addListener(_recompute);
      feature.lifecycle.addListener(_onDependencyLifecycle);
      _deps[feature] = listenable;
    } catch (_) {
      listenable.removeListener(_recompute);
      feature.lifecycle.removeListener(_onDependencyLifecycle);
      feature.release();
      rethrow;
    }
  }

  void _releaseDependencies() {
    for (final entry in _deps.entries) {
      entry.value.removeListener(_recompute);
      entry.key.lifecycle.removeListener(_onDependencyLifecycle);
      entry.key.release();
    }
    _deps.clear();
  }

  /// Срабатывает, когда у одной из зависимостей заменился внутренний
  /// контроллер — переподписываемся на актуальный [Listenable] той же фичи
  /// и пересчитываем: новый Store мог стартовать с другого состояния.
  void _onDependencyLifecycle() {
    if (_disposed) return;
    for (final feature in _deps.keys.toList(growable: false)) {
      final old = _deps[feature];

      if (old == null) continue;

      final fresh = feature.currentListenable;
      if (identical(old, fresh)) continue;

      old.removeListener(_recompute);
      fresh.addListener(_recompute);

      _deps[feature] = fresh;
    }

    _recompute();
  }

  void _recompute() {
    if (_disposed) return;
    if (_recomputing) {
      _recomputeRequested = true;
      return;
    }
    _recomputing = true;

    try {
      do {
        _recomputeRequested = false;
        final tracked = <HelmFeatureHandle>{};
        late final T next;

        try {
          next = trackHelmDependencies(_compute, tracked.add);
        } catch (e, st) {
          // Не удаляем прежние зависимости после неудачного вычисления.
          // Иначе фича, которую код ещё не успел прочитать до ошибки, больше
          // не сможет инициировать восстановление computed. Новые фичи,
          // прочитанные до ошибки, добавляются: их изменение тоже может
          // сделать следующую попытку успешной. Только успешный проход имеет
          // право сузить граф зависимостей.
          _syncDependencies({..._deps.keys, ...tracked});
          final handler = onError;
          if (handler == null) rethrow;
          handler(e, st);
          // Обработчик ошибки может синхронно обновить зависимость. Такой
          // update уже пометил _recomputeRequested, поэтому не выходим из
          // цикла и даём следующей итерации вычислить актуальное значение.
          continue;
        }
        _syncDependencies(tracked);

        if (!_equals(next, _value)) {
          _value = next;
          notifyListeners();
        }
      } while (_recomputeRequested);
    } finally {
      _recomputing = false;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    _releaseDependencies();

    assert(() {
      _debugActiveComputed.remove(this);
      return true;
    }());

    super.dispose();
  }
}

/// Короткая фабрика [HelmComputed] — без явного `HelmComputed<T>(...)`.
///
/// ```dart
/// final total = helmCompute(() => a.value.x + b.value.y + c.value.z);
/// ```
HelmComputed<T> helmCompute<T>(
  T Function() compute, {
  bool Function(T a, T b)? equals,
  void Function(Object error, StackTrace stackTrace)? onError,
}) => HelmComputed<T>(compute, equals: equals, onError: onError);
