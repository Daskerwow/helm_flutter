import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm_core/helm_core.dart';

final class const _CounterState(final int count);

final class const _Increment() implements SyncCommand<_CounterState> {
  @override
  _CounterState execute(_CounterState current) =>
      _CounterState(current.count + 1);
}

final class _Fail implements AsyncCommand<_CounterState> {
  const _Fail();
  @override
  Future<void> execute(reader, writer, cancel) async {
    throw StateError('boom');
  }
}

final class _RetainedStream implements StreamCommand<int> {
  _RetainedStream(this.source);

  final Stream<void> source;
  StateWriter<int>? writer;

  @override
  Stream<void> execute(reader, nextWriter, cancel) {
    writer = nextWriter;
    return source;
  }
}

final class _ThrowingStream implements StreamCommand<int> {
  StateWriter<int>? writer;

  @override
  Stream<void> execute(reader, nextWriter, cancel) {
    writer = nextWriter;
    throw StateError('stream setup failed');
  }
}

/// Generic-команда — используется, чтобы проверить, что разные
/// инстанциации `_Load<T>` не отменяют друг друга (реифицированные дженерики).
final class const _Load<T>(
  final T value, {
  final Duration delay = Duration.zero,
}) implements AsyncCommand<Loadable<T>> {
  @override
  Future<void> execute(reader, writer, cancel) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (cancel.isCancelled) return;
    writer.commit(Loadable.data(value));
  }
}

/// Команда с явным dispatchKey — параллельные запуски с разным userId не
/// должны вытеснять друг друга.
final class const _FetchUser(final String userId, final Duration delay)
    implements AsyncCommand<String>, DispatchKeyed {
  @override
  Object get dispatchKey => (_FetchUser, userId);

  @override
  Future<void> execute(reader, writer, cancel) async {
    await Future<void>.delayed(delay);
    if (cancel.isCancelled) return;
    writer.commit(userId);
  }
}

void main() {
  group('dispatchSync', () {
    test('коммитит и публикует изменение', () {
      final store = StateStore<_CounterState, Never>(
        initialState: const _CounterState(0),
      );
      final seen = <int>[];
      store.addOnChanged((s) => seen.add(s.count));

      store.dispatchSync(const _Increment());

      expect(store.state.count, 1);
      expect(seen, [1]);
      store.close();
    });

    test('не публикует, если состояние не изменилось (equals)', () {
      final store = StateStore<int, Never>(initialState: 0);
      final seen = <int>[];
      store.addOnChanged(seen.add);

      store.dispatchSync(const SetUse(0));

      expect(seen, isEmpty);
      store.close();
    });
  });

  group('dispatch (async)', () {
    test('DispatchFailure при исключении, error-слушатель вызван', () async {
      final store = StateStore<_CounterState, Never>(
        initialState: const _CounterState(0),
      );
      Object? capturedError;
      store.addErrorListener((e, st) => capturedError = e);

      final result = await store.dispatchAsync(const _Fail());

      expect(result, isA<DispatchFailure<_CounterState>>());
      expect(capturedError, isA<StateError>());
      store.close();
    });

    test('повторный dispatch того же типа отменяет предыдущий', () async {
      final store = StateStore<Loadable<int>, Never>(
        initialState: const Loadable.idle(),
      );

      final first = store.dispatchAsync(
        _Load(1, delay: const Duration(milliseconds: 50)),
      );
      final second = store.dispatchAsync(_Load(2, delay: Duration.zero));

      final firstResult = await first;
      final secondResult = await second;

      expect(firstResult, isA<DispatchCancelled<Loadable<int>>>());
      expect(
        (firstResult as DispatchCancelled).reason,
        CancelReason.superseded,
      );
      expect(secondResult, isA<DispatchSuccess<Loadable<int>>>());
      expect(store.state.valueOrNull, 2);
      store.close();
    });

    test(
      'реификация дженериков: сторы с разными T друг другу не мешают',
      () async {
        final intStore = StateStore<Loadable<int>, Never>(
          initialState: const Loadable.idle(),
        );
        final stringStore = StateStore<Loadable<String>, Never>(
          initialState: const Loadable.idle(),
        );

        final r1 = await intStore.dispatchAsync(_Load<int>(42));
        final r2 = await stringStore.dispatchAsync(_Load<String>('42'));

        expect(r1, isA<DispatchSuccess<Loadable<int>>>());
        expect(r2, isA<DispatchSuccess<Loadable<String>>>());
        expect(intStore.state.valueOrNull, 42);
        expect(stringStore.state.valueOrNull, '42');

        intStore.close();
        stringStore.close();
      },
    );

    test('DispatchKeyed: параллельные запросы с разным ключом не вытесняют друг друга', () async {
      final store = StateStore<String, Never>(initialState: '');

      final a = store.dispatchAsync(
        _FetchUser('alice', const Duration(milliseconds: 30)),
      );
      final b = store.dispatchAsync(
        _FetchUser('bob', const Duration(milliseconds: 10)),
      );

      final resultA = await a;
      final resultB = await b;

      expect(resultA, isA<DispatchSuccess<String>>());
      expect(resultB, isA<DispatchSuccess<String>>());
      store.close();
    });
  });

  group('close', () {
    test(
      'после close все dispatch* методы отдают storeClosed, без исключений',
      () async {
        final store = StateStore<_CounterState, Never>(
          initialState: const _CounterState(0),
        );
        store.close();

        final syncResult = store.dispatchSync(const _Increment());
        final asyncResult = await store.dispatchAsync(const _Fail());

        expect(
          (syncResult as DispatchCancelled).reason,
          CancelReason.storeClosed,
        );
        expect(
          (asyncResult as DispatchCancelled).reason,
          CancelReason.storeClosed,
        );
      },
    );

    test('повторный close — no-op', () {
      final store = StateStore<int, Never>(initialState: 0);
      store.close();
      expect(store.close, returnsNormally);
    });
  });

  group('addOnChanged/addDispatchListener', () {
    test('поддерживает несколько независимых слушателей одновременно', () {
      final store = StateStore<_CounterState, Never>(
        initialState: const _CounterState(0),
      );
      final a = <int>[];
      final b = <int>[];
      store.addOnChanged((s) => a.add(s.count));
      store.addOnChanged((s) => b.add(s.count));

      store.dispatchSync(const _Increment());

      expect(a, [1]);
      expect(b, [1]);
      store.close();
    });

    test('отписка через возвращённую функцию работает', () {
      final store = StateStore<_CounterState, Never>(
        initialState: const _CounterState(0),
      );
      final seen = <int>[];
      final unsubscribe = store.addOnChanged((s) => seen.add(s.count));

      store.dispatchSync(const _Increment());
      unsubscribe();
      store.dispatchSync(const _Increment());

      expect(seen, [1]);
      store.close();
    });
  });

  group('streams', () {
    test('states и effects завершаются при close', () async {
      final store = StateStore<int, String>(initialState: 0);
      var statesDone = false;
      var effectsDone = false;
      final states = store.states.listen(
        (_) {},
        onDone: () => statesDone = true,
      );
      final effects = store.effects.listen(
        (_) {},
        onDone: () => effectsDone = true,
      );

      store.close();
      await Future<void>.delayed(Duration.zero);

      expect(statesDone, isTrue);
      expect(effectsDone, isTrue);
      await states.cancel();
      await effects.cancel();
    });

    test('effects Stream получает side-эффекты', () async {
      final store = StateStore<int, String>(initialState: 0);
      final received = <String>[];
      final subscription = store.effects.listen(received.add);

      store.dispatchSyncWithEffect(
        const SetWithEffectUse<int, String>(1, effect: 'saved'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, ['saved']);
      await subscription.cancel();
      store.close();
    });

    test('завершённая stream-команда не отменяется повторно', () async {
      final source = StreamController<void>();
      final store = StateStore<int, Never>(initialState: 0);
      final events = <DispatchEvent<int>>[];
      store.addDispatchListener(events.add);

      store.dispatchStream(_RetainedStream(source.stream));
      await source.close();
      await Future<void>.delayed(Duration.zero);
      store.cancelStream<_RetainedStream>();

      expect(events.where((event) => event.isCancelled), isEmpty);
      store.close();
    });

    test('writer stream-команды не принимает commit после отмены', () async {
      final source = StreamController<void>();
      final command = _RetainedStream(source.stream);
      final store = StateStore<int, Never>(initialState: 0);

      store.dispatchStream(command);
      store.cancelStream<_RetainedStream>();
      command.writer!.commit(42);

      expect(store.state, 0);
      await source.close();
      store.close();
    });

    test('writer неактивен, если Stream-команда упала при создании', () {
      final command = _ThrowingStream();
      final store = StateStore<int, Never>(initialState: 0);
      final errors = <Object>[];
      store.addErrorListener((error, _) => errors.add(error));

      store.dispatchStream(command);
      command.writer!.commit(42);

      expect(errors.single, isA<StateError>());
      expect(store.state, 0);
      store.close();
    });
  });
}
