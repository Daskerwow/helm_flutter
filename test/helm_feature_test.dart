import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:helm_core/helm_core.dart';
import 'package:helm_flutter/helm_flutter.dart';

void main() {
  test('overrideWith: повторный вызов restore — no-op', () {
    final feature = HelmFeature<int, Never>(() => StateStore(initialState: 0));
    feature.value; // создаёт исходный Store

    var bumpCount = 0;
    feature.lifecycle.addListener(() => bumpCount++);

    final restore = feature.overrideWith(() => StateStore(initialState: 99));
    expect(feature.value, 99);
    expect(bumpCount, 1);

    restore();
    expect(bumpCount, 2);

    // Повторный вызов restore — не должен ещё раз пересоздавать Store и
    // бампать lifecycle (регрессия на баг "двойной restore").
    restore();
    expect(bumpCount, 2);
    feature.dispose();
  });

  test('overrideWith заменяет Store при активном подписчике', () {
    final feature = HelmFeature<int, Never>(() => StateStore(initialState: 0));
    final unsubscribe = feature.listen((_) {});

    final restore = feature.overrideWith(() => StateStore(initialState: 99));
    expect(feature.value, 99);

    restore();
    expect(feature.value, 0);
    unsubscribe();
    feature.dispose();
  });

  test('autoDispose закрывает Store, когда refCount уходит в ноль', () {
    final feature = HelmFeature<int, Never>(
      () => StateStore(initialState: 0),
      autoDispose: true,
    );

    final unsubscribe = feature.listen((_) {});
    expect(feature.isActive, isTrue);

    unsubscribe();
    expect(feature.isActive, isFalse);
  });

  test('listen(): вызов disposer дважды безопасен (idempotent)', () {
    final feature = HelmFeature<int, Never>(() => StateStore(initialState: 0));
    final unsubscribe = feature.listen((_) {});

    expect(unsubscribe, returnsNormally);
    expect(unsubscribe, returnsNormally);

    feature.dispose();
  });

  test('неудачный HelmComputed не оставляет autoDispose фичу активной', () {
    final feature = HelmFeature<int, Never>(
      () => StateStore(initialState: 0),
      autoDispose: true,
    );

    expect(
      () => HelmComputed<int>(() {
        feature.value;
        throw StateError('compute failed');
      }),
      throwsStateError,
    );
    expect(feature.isActive, isFalse);
  });

  test('HelmComputed повторяет вычисление после реентрантного обновления', () {
    final feature = HelmFeature<int, Never>(() => StateStore(initialState: 0));
    final computed = HelmComputed<int>(() => feature.value);
    computed.addListener(() {
      if (feature.value == 1) {
        feature.dispatchSync(const SetUse(2));
      }
    });

    feature.dispatchSync(const SetUse(1));

    expect(computed.value, 2);
    computed.dispose();
    feature.dispose();
  });

  test('DispatchProxy пробрасывает cancelKey', () async {
    final feature = HelmFeature<int, Never>(() => StateStore(initialState: 0));
    final started = Completer<void>();
    final finish = Completer<void>();

    final result = feature.dispatchAsync(_KeyedWait(started, finish));
    await started.future;
    feature.cancelKey('request');
    finish.complete();

    expect(await result, isA<DispatchCancelled<int>>());
    expect(feature.value, 0);
    feature.dispose();
  });
}

final class _KeyedWait implements AsyncCommand<int>, DispatchKeyed {
  _KeyedWait(this._started, this._finish);

  final Completer<void> _started;
  final Completer<void> _finish;

  @override
  Object get dispatchKey => 'request';

  @override
  Future<void> execute(reader, writer, cancel) async {
    _started.complete();
    await _finish.future;
    if (!cancel.isCancelled) writer.commit(1);
  }
}
