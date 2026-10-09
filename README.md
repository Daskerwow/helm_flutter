# helm_flutter

`helm_flutter` connects the framework-independent Helm state runtime to
Flutter's `Listenable` and widget lifecycle. It exposes `helm_core` and the
Flutter bindings from one import:

```dart
import 'package:helm_flutter/helm_flutter.dart';
```

## Core ideas

- `StateStore` executes synchronous, asynchronous and stream commands.
- `HelmFeature` owns a lazily created Store and provides a global state token.
- `HelmBuilder`, `HelmSelector` and `HelmListener` bind a feature to Flutter.
- `HelmComputed` derives a value from one or more feature states.
- `Loadable<T>` models idle, loading, data and error states.

## A minimal feature

```dart
final counterFeature = HelmFeature<int, Never>(
  () => StateStore(initialState: 0),
);

final class Increment implements SyncCommand<int> {
  const Increment();

  @override
  int execute(int current) => current + 1;
}
```

Render it with a binding:

```dart
HelmBuilder<int, Never>(
  counterFeature,
  builder: (context, count) => Text('$count'),
)
```

## Lifecycle invariant

A mounted binding always keeps the same `HelmFeature` object. This makes
ownership and automatic disposal deterministic. To intentionally switch to a
different feature, mount a new Element with a new key:

```dart
HelmBuilder<int, Never>(
  key: ObjectKey(feature),
  feature,
  builder: (context, state) => Text('$state'),
)
```

The same rule applies to the dependency set of `HelmWidget` and
`StatefulHelmWidget`. Keep it constant for the Element lifetime; model a
dynamic branch as a keyed child widget.

## Ownership

Use `autoDispose: true` for screen-scoped state. Flutter bindings, `listen()`
and `HelmComputed` retain the feature while they are alive. A family refuses to
remove a retained feature; `forceRemove` and `forceDisposeAll` are reserved for
explicit session-wide cleanup.
