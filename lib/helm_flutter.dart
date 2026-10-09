/// Flutter-facing entry point for Helm.
///
/// Framework-independent runtime lives in `package:helm_core/helm_core.dart`.
/// This package re-exports it together with the Flutter bridge. Use
/// `package:helm_flutter/helm_flutter.dart` as the single public import.
///
/// ### Три принципа
/// - **Явность** — каждый исход диспатча типизирован через [DispatchResult].
/// - **Разделение прав** — команды получают ровно то, что им нужно:
///   [StateReader] или [StateWriter], редко оба сразу.
/// - **Отменяемость** — асинхронные команды прерываются через [CancelToken],
///   исключая race condition при повторных запросах.
///
/// ### Быстрый старт
///
/// ```dart
/// import 'package:helm_flutter/helm_flutter.dart';
///
/// final store = StoreBuilder<MyState, MyEffect>(MyState.initial())
///     .onChanged((s) => print(s))
///     .onEffect((e) => router.handle(e))
///     .onDispatch((event) => logger.debug(event.toLogString()))
///     .build();
///
/// await store.dispatchAsync(FetchDataCommand(_api));
/// store.close();
/// ```
///
/// ### Ключевые типы
/// - [StateStore] — центральный Store.
/// - [StoreBuilder] — fluent-построитель Store.
/// - [DispatchResult] — [DispatchSuccess] / [DispatchFailure] / [DispatchCancelled].
/// - [CancelToken] — токен отмены асинхронных команд.
/// - [Loadable] — готовое состояние одного асинхронного ресурса + команды
///   [LoadCommand]/[WatchCommand], закрывающие типовой `loading/data/error`.
/// - [StoreMiddleware] — именованная альтернатива `addDispatchListener` для
///   кросс-катаных забот (логирование, аналитика, DevTools-мост).
///
/// ### Сравнение состояний для мутируемых коллекций
///
/// Если `S` (или срез, с которым работает `equals`/`selector`) — `List`/
/// `Set`/`Map`, готовые компараторы `listEquals`/`setEquals`/`mapEquals`/
/// `deepEquals` из `equality.dart` избавляют от ручной реализации
/// содержательного сравнения — см. их докстринги.
library;

export 'package:helm_core/helm_core.dart';

export './src/flutter.dart';
