import 'package:flutter/widgets.dart';
import 'package:helm_core/helm_core.dart';

import 'helm_builder.dart';
import 'helm_feature.dart';

/// Готовый `.when()`-стиль ветвления для фич на `Loadable<T>` — аналог
/// `.when()` из `AsyncValue`, но подключённый к живому [HelmFeature].
///
/// `previous` в [loading]/[error] — последнее успешно загруженное значение:
/// можно показать старые данные поверх спиннера вместо пустого экрана.
///
/// ```dart
/// HelmLoadableBuilder<List<Todo>, Never>(
///   todosFeature,
///   data: (context, todos) => TodoList(todos),
///   loading: (context, previous) => previous == null
///       ? const CircularProgressIndicator()
///       : Stack(children: [TodoList(previous), const LinearProgressIndicator()]),
///   error: (context, e, st, previous) => ErrorView(e, retry: () => todosFeature.load(fetchTodos)),
/// )
/// ```
class HelmLoadableBuilder<T, E> extends StatelessWidget {
  const HelmLoadableBuilder(
    this.feature, {
    super.key,
    required this.data,
    required this.loading,
    required this.error,
    this.idle,
  });

  final HelmFeature<Loadable<T>, E> feature;

  final Widget Function(BuildContext context, T value) data;
  final Widget Function(BuildContext context, T? previous) loading;
  final Widget Function(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
    T? previous,
  )
  error;

  /// Ресурс ещё не запрашивался. По умолчанию рисуется как [loading] с
  /// `previous: null`.
  final Widget Function(BuildContext context)? idle;

  @override
  Widget build(BuildContext context) {
    return HelmBuilder<Loadable<T>, E>(
      feature,
      builder: (context, state) => state.when(
        idle: () => idle != null ? idle!(context) : loading(context, null),
        loading: (previous) => loading(context, previous),
        data: (value) => data(context, value),
        error: (e, st, previous) => error(context, e, st, previous),
      ),
    );
  }
}

/// Сахар для фич, где состояние — `Loadable<T>` целиком. Экономит
/// `feature.dispatch(LoadCommand(...))` на каждом экране со списком/деталями.
///
/// ```dart
/// final todosFeature = HelmFeature<Loadable<List<Todo>>, Never>(
///   () => StateStore(initialState: const Loadable.idle()),
///   autoDispose: true,
/// )..load(() => api.fetchTodos());
/// ```
///
/// Работает только когда `S` фичи — `Loadable<T>` (проверяется компилятором) —
/// для составных состояний, где `Loadable` лишь одно из полей, диспатчи
/// обычной командой, читающей/пишущей нужное поле через `copyWith`.
extension HelmFeatureLoadable<T, E> on HelmFeature<Loadable<T>, E> {
  /// Запускает `LoadCommand` — one-shot загрузка `loading → data / error`.
  Future<DispatchResult<Loadable<T>>> load(Future<T> Function() load) =>
      dispatchAsync(LoadableUse<T>(load));

  /// Подписывается на внешний `Stream<T>` через `WatchCommand` — каждое
  /// значение сразу становится `Loadable.data`.
  void watchStream(Stream<T> Function() source) =>
      dispatchStream(WatchLoadableUse<T>(source));
}
