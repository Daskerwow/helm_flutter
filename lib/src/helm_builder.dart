import 'package:flutter/widgets.dart';

import 'binding_utils.dart';
import 'helm_controller.dart';
import 'helm_feature.dart';

/// Общая часть привязки `State` к [HelmFeature]: acquire в `initState`,
/// подписка на [HelmFeature.lifecycle], смена фичи в `didUpdateWidget`
/// ([rebindFeature]), release в `dispose`. Устраняет дублирование этого
/// скелета между [HelmBuilder]/[HelmSelector]/[HelmListener] — они
/// отличаются только тем, что вешают на контроллер поверх него ([onBind]/
/// [onUnbind]).
///
/// `didUpdateWidget` реализован здесь один раз: каждому конкретному `State`
/// достаточно сообщить, как достать [HelmFeature] из старого виджета (см.
/// [featureOf]) — раньше идентичный `didUpdateWidget` (сравнить `feature` на
/// `identical`, при смене вызвать [rebindFeature]) был дословно продублирован
/// в каждом из трёх `State`.
///
/// Сам скелет "acquire → attach → пережить смену контроллера → release"
/// вынесен в `FeatureSubscription` (`binding_utils.dart`) — тот же класс
/// используют биндинги `feature.watch()`/`.select()`/`.effect()` в
/// `helm_reactive.dart`. Здесь остаётся только специфика `State`:
/// `initState`/`didUpdateWidget`/`dispose` и опциональный `setState` на
/// смену контроллера.
mixin _FeatureBindingState<S, E, W extends StatefulWidget> on State<W> {
  /// Токен фичи, к которому привязан этот `State` — обычно `widget.feature`.
  HelmFeature<S, E> get feature;

  /// Достаёт [HelmFeature] из произвольного экземпляра виджета — нужен для
  /// единого [didUpdateWidget] ниже, чтобы сравнить `oldWidget.feature` с
  /// актуальным [feature] без дублирования этого сравнения в каждом `State`.
  HelmFeature<S, E> featureOf(W widget);

  /// `true` (по умолчанию) — смена контроллера вызывает `setState`.
  /// [HelmListener] переопределяет в `false`: его `build()` не зависит от
  /// состояния фичи.
  bool get rebuildsOnControllerSwap => true;

  late FeatureSubscription<S, E> _subscription;

  /// Переподключается на новый контроллер после `overrideWith`/`dispose`
  /// фичи — управляется [_subscription].
  HelmController<S, E> get controller => _subscription.controller;

  FeatureSubscription<S, E> _createSubscription() => FeatureSubscription<S, E>(
    feature,
    attach: onBind,
    detach: onUnbind,
    // Если State уже не mounted, весь обмен контроллером (а значит и
    // onBind/onUnbind) пропускается целиком, а не только реакция setState
    // на него — тот же гейт, что и в оригинальном _onLifecycle
    // (`if (!mounted) return;` ДО swapController).
    shouldSwap: () => mounted,
    onControllerSwapped: () {
      if (rebuildsOnControllerSwap) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    _subscription = _createSubscription();
  }

  @override
  void didUpdateWidget(covariant W oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldFeature = featureOf(oldWidget);
    if (!identical(oldFeature, feature)) rebindFeature(oldFeature);
  }

  /// Вызывается из [didUpdateWidget], когда сам токен [HelmFeature]
  /// сменился на другой объект — например, виджету передали другую фичу.
  void rebindFeature(HelmFeature<S, E> oldFeature) {
    _subscription.dispose();
    _subscription = _createSubscription();
  }

  @override
  void dispose() {
    _subscription.dispose();
    super.dispose();
  }

  /// Навесить то, что нужно этому виджету, на [controller].
  void onBind(HelmController<S, E> controller);

  /// Снять то, что навесил [onBind].
  void onUnbind(HelmController<S, E> controller);
}

/// Аналог `BlocBuilder`/`Consumer` — перестраивает `builder` при каждом
/// изменении состояния через штатный [ValueListenableBuilder] ([HelmController]
/// реализует [ValueListenable]).
///
/// Подписывается на *весь* `S` — для ребилда по части состояния используй
/// [HelmSelector]; для `S == Loadable<T>` — `HelmLoadableBuilder`.
///
/// Переподключается к новому контроллеру автоматически после
/// `overrideWith`/принудительного `dispose` фичи.
///
/// ```dart
/// HelmBuilder(counterFeature, builder: (context, state) => Text('${state.count}'))
/// ```
class HelmBuilder<S, E> extends StatefulWidget {
  const HelmBuilder(this.feature, {super.key, required this.builder});

  final HelmFeature<S, E> feature;
  final Widget Function(BuildContext context, S state) builder;

  @override
  State<HelmBuilder<S, E>> createState() => _HelmBuilderState<S, E>();
}

class _HelmBuilderState<S, E> extends State<HelmBuilder<S, E>>
    with _FeatureBindingState<S, E, HelmBuilder<S, E>> {
  @override
  HelmFeature<S, E> get feature => widget.feature;

  @override
  HelmFeature<S, E> featureOf(HelmBuilder<S, E> widget) => widget.feature;

  // ValueListenableBuilder ниже сам управляет подпиской при смене
  // listenable — навешивать/снимать здесь нечего.
  @override
  void onBind(HelmController<S, E> controller) {}

  @override
  void onUnbind(HelmController<S, E> controller) {}

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<S>(
    valueListenable: controller,
    builder: (context, state, _) => widget.builder(context, state),
  );
}

/// Аналог `BlocSelector`/`Selector` — подписывается на [feature], но
/// перестраивается только когда результат [selector] реально изменился
/// (`==`). Переподключается к новому контроллеру так же, как [HelmBuilder].
///
/// ```dart
/// HelmSelector<DocumentState, Never, String>(
///   documentFeature,
///   selector: (state) => state.title,
///   builder: (context, title) => Text(title),
/// )
/// ```
class HelmSelector<S, E, R> extends StatefulWidget {
  const HelmSelector(
    this.feature, {
    super.key,
    required this.selector,
    required this.builder,
  });

  final HelmFeature<S, E> feature;
  final R Function(S state) selector;
  final Widget Function(BuildContext context, R value) builder;

  @override
  State<HelmSelector<S, E, R>> createState() => _HelmSelectorState<S, E, R>();
}

class _HelmSelectorState<S, E, R> extends State<HelmSelector<S, E, R>>
    with _FeatureBindingState<S, E, HelmSelector<S, E, R>> {
  late R _value;

  @override
  HelmFeature<S, E> get feature => widget.feature;

  @override
  HelmFeature<S, E> featureOf(HelmSelector<S, E, R> widget) => widget.feature;

  @override
  void onBind(HelmController<S, E> controller) {
    controller.addListener(_onChange);
    _value = widget.selector(controller.state);
  }

  @override
  void onUnbind(HelmController<S, E> controller) {
    controller.removeListener(_onChange);
  }

  void _onChange() {
    final next = widget.selector(controller.state);
    if (next != _value && mounted) setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) {
    // widget.selector мог измениться между билдами (например, замкнул
    // новую переменную из внешнего build()), даже если ни feature, ни
    // state с прошлого раза не менялись — без этого пересчёта UI показывал
    // бы устаревшее _value вплоть до следующего изменения состояния фичи.
    // Тот же приём, что и в HelmFeatureReactive.select → resync().
    final next = widget.selector(controller.state);
    if (next != _value) _value = next;

    return widget.builder(context, _value);
  }
}

/// Аналог `BlocListener` — подписывается на side-эффекты фичи и вызывает
/// [listener] при каждом, ничего не перестраивая (эффект — событие, а не
/// часть UI-состояния).
///
/// Предпочтительнее, чем `HelmFeature.onEffect`, когда реакция актуальна
/// только для части дерева.
///
/// ```dart
/// HelmListener<UserState, UserEffect>(
///   userFeature,
///   listener: (context, effect) {
///     if (effect is NavigateToHome) Navigator.of(context).pushNamed('/home');
///   },
///   child: const LoginForm(),
/// )
/// ```
class HelmListener<S, E> extends StatefulWidget {
  const HelmListener(
    this.feature, {
    super.key,
    required this.listener,
    required this.child,
  });

  final HelmFeature<S, E> feature;
  final void Function(BuildContext context, E effect) listener;
  final Widget child;

  @override
  State<HelmListener<S, E>> createState() => _HelmListenerState<S, E>();
}

class _HelmListenerState<S, E> extends State<HelmListener<S, E>>
    with _FeatureBindingState<S, E, HelmListener<S, E>> {
  void Function()? _unsubscribeEffects;

  @override
  HelmFeature<S, E> get feature => widget.feature;

  @override
  HelmFeature<S, E> featureOf(HelmListener<S, E> widget) => widget.feature;

  // build() не читает состояние фичи — смена контроллера не требует
  // ребилда, только переподписки на эффекты.
  @override
  bool get rebuildsOnControllerSwap => false;

  @override
  void onBind(HelmController<S, E> controller) {
    _unsubscribeEffects = controller.store.addOnEffect(
      (effect) => widget.listener(context, effect),
    );
  }

  @override
  void onUnbind(HelmController<S, E> controller) {
    _unsubscribeEffects?.call();
    _unsubscribeEffects = null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Комбинация [HelmListener] + [HelmBuilder] — как `BlocConsumer`: один
/// виджет реагирует и на эффекты, и на состояние, без ручной вложенности.
class HelmConsumer<S, E> extends StatelessWidget {
  const HelmConsumer(
    this.feature, {
    super.key,
    required this.listener,
    required this.builder,
  });

  final HelmFeature<S, E> feature;
  final void Function(BuildContext context, E effect) listener;
  final Widget Function(BuildContext context, S state) builder;

  @override
  Widget build(BuildContext context) => HelmListener<S, E>(
    feature,
    listener: listener,
    child: HelmBuilder<S, E>(feature, builder: builder),
  );
}
