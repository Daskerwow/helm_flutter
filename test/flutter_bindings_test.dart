import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:helm_core/helm_core.dart';
import 'package:helm_flutter/helm_flutter.dart';

Widget _host(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

final class _ReactiveProbe extends HelmWidget {
  const _ReactiveProbe(this.feature, this.effects);

  final HelmFeature<int, String> feature;
  final List<int> effects;

  @override
  Widget build(BuildContext context) {
    final value = feature.watch();
    final parity = feature.select((state) => state.isEven);
    feature.effect(effects.add);
    return Text('$value:$parity');
  }
}

final class _StatefulReactiveProbe extends StatefulHelmWidget {
  const _StatefulReactiveProbe(this.feature);

  final HelmFeature<int, Never> feature;

  @override
  State<_StatefulReactiveProbe> createState() => _StatefulReactiveProbeState();
}

final class _StatefulReactiveProbeState extends State<_StatefulReactiveProbe> {
  @override
  Widget build(BuildContext context) =>
      Text('stateful:${widget.feature.watch()}');
}

void main() {
  group('Flutter bindings', () {
    testWidgets('HelmBuilder читает initial state и перестраивается', (
      tester,
    ) async {
      final feature = HelmFeature<int, Never>(
        () => StateStore(initialState: 0),
      );

      await tester.pumpWidget(
        _host(HelmBuilder(feature, builder: (_, state) => Text('$state'))),
      );
      expect(find.text('0'), findsOneWidget);

      feature.dispatchSync(const SetUse(1));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      await tester.pumpWidget(_host(const SizedBox()));
      feature.dispose();
    });

    testWidgets('HelmSelector не rebuild-ит при изменении другого среза', (
      tester,
    ) async {
      final feature = HelmFeature<(int, String), Never>(
        () => StateStore(initialState: (0, 'first')),
      );
      var builds = 0;

      await tester.pumpWidget(
        _host(
          HelmSelector<(int, String), Never, int>(
            feature,
            selector: (state) => state.$1,
            builder: (_, value) {
              builds++;
              return Text('$value');
            },
          ),
        ),
      );
      expect(builds, 1);

      feature.dispatchSync(const SetUse((0, 'second')));
      await tester.pump();
      expect(builds, 1);

      feature.dispatchSync(const SetUse((1, 'second')));
      await tester.pump();
      expect(builds, 2);

      await tester.pumpWidget(_host(const SizedBox()));
      feature.dispose();
    });

    testWidgets('HelmListener доставляет effect без rebuild child', (
      tester,
    ) async {
      final feature = HelmFeature<int, String>(
        () => StateStore(initialState: 0),
      );
      final effects = <String>[];
      var childBuilds = 0;

      await tester.pumpWidget(
        _host(
          HelmListener(
            feature,
            listener: (_, effect) => effects.add(effect),
            child: Builder(
              builder: (_) {
                childBuilds++;
                return const Text('child');
              },
            ),
          ),
        ),
      );

      feature.dispatchSyncWithEffect(
        const SetWithEffectUse<int, String>(1, effect: 'saved'),
      );
      await tester.pump();

      expect(effects, ['saved']);
      expect(childBuilds, 1);

      await tester.pumpWidget(_host(const SizedBox()));
      feature.dispose();
    });

    testWidgets('HelmConsumer сочетает state и side-effect', (tester) async {
      final feature = HelmFeature<int, String>(
        () => StateStore(initialState: 0),
      );
      final effects = <String>[];

      await tester.pumpWidget(
        _host(
          HelmConsumer(
            feature,
            listener: (_, effect) => effects.add(effect),
            builder: (_, state) => Text('state:$state'),
          ),
        ),
      );

      feature.dispatchSyncWithEffect(
        const SetWithEffectUse<int, String>(3, effect: 'done'),
      );
      await tester.pump();

      expect(find.text('state:3'), findsOneWidget);
      expect(effects, ['done']);

      await tester.pumpWidget(_host(const SizedBox()));
      feature.dispose();
    });

    testWidgets('reactive API watch/select/effect соблюдает lifecycle', (
      tester,
    ) async {
      final feature = HelmFeature<int, String>(
        () => StateStore(initialState: 0),
      );
      final effects = <int>[];

      await tester.pumpWidget(_host(_ReactiveProbe(feature, effects)));
      await tester.pump();
      expect(find.text('0:true'), findsOneWidget);
      expect(effects, [0]);

      feature.dispatchSync(const SetUse(1));
      await tester.pump();
      expect(find.text('1:false'), findsOneWidget);
      expect(effects, [0, 1]);

      await tester.pumpWidget(_host(const SizedBox()));
      feature.dispose();
    });

    testWidgets('overrideWith и autoDispose корректны в Element lifecycle', (
      tester,
    ) async {
      final feature = HelmFeature<int, Never>(
        () => StateStore(initialState: 0),
        autoDispose: true,
      );

      await tester.pumpWidget(
        _host(HelmBuilder(feature, builder: (_, state) => Text('$state'))),
      );
      final restore = feature.overrideWith(() => StateStore(initialState: 99));
      await tester.pump();
      expect(find.text('99'), findsOneWidget);

      restore();
      await tester.pump();
      expect(find.text('0'), findsOneWidget);

      await tester.pumpWidget(_host(const SizedBox()));
      expect(feature.isActive, isFalse);
    });

    testWidgets('HelmLoadableBuilder обрабатывает все состояния Loadable', (
      tester,
    ) async {
      final feature = HelmFeature<Loadable<int>, Never>(
        () => StateStore(initialState: const Loadable<int>.idle()),
      );

      await tester.pumpWidget(
        _host(
          HelmLoadableBuilder<int, Never>(
            feature,
            idle: (_) => const Text('idle'),
            loading: (_, previous) => Text('loading:$previous'),
            data: (_, value) => Text('data:$value'),
            error: (_, error, stackTrace, previous) =>
                Text('error:$error:$previous'),
          ),
        ),
      );
      expect(find.text('idle'), findsOneWidget);

      feature.dispatchSync(const SetUse(Loadable<int>.loading(3)));
      await tester.pump();
      expect(find.text('loading:3'), findsOneWidget);

      feature.dispatchSync(const SetUse(Loadable<int>.data(7)));
      await tester.pump();
      expect(find.text('data:7'), findsOneWidget);

      feature.dispatchSync(
        const SetUse(Loadable<int>.error('network', previous: 7)),
      );
      await tester.pump();
      expect(find.text('error:network:7'), findsOneWidget);

      await tester.pumpWidget(_host(const SizedBox()));
      feature.dispose();
    });

    testWidgets('StatefulHelmWidget подписывается и освобождает binding', (
      tester,
    ) async {
      final feature = HelmFeature<int, Never>(
        () => StateStore(initialState: 0),
        autoDispose: true,
      );

      await tester.pumpWidget(_host(_StatefulReactiveProbe(feature)));
      expect(find.text('stateful:0'), findsOneWidget);

      feature.dispatchSync(const SetUse(5));
      await tester.pump();
      expect(find.text('stateful:5'), findsOneWidget);

      await tester.pumpWidget(_host(const SizedBox()));
      expect(feature.isActive, isFalse);
    });

    testWidgets('HelmBuilder переподключается при замене HelmFeature', (
      tester,
    ) async {
      final first = HelmFeature<int, Never>(() => StateStore(initialState: 1));
      final second = HelmFeature<int, Never>(() => StateStore(initialState: 2));

      Future<void> pump(HelmFeature<int, Never> feature) => tester.pumpWidget(
        _host(HelmBuilder(feature, builder: (_, state) => Text('$state'))),
      );

      await pump(first);
      expect(find.text('1'), findsOneWidget);
      await pump(second);
      expect(find.text('2'), findsOneWidget);

      first.dispatchSync(const SetUse(10));
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      second.dispatchSync(const SetUse(20));
      await tester.pump();
      expect(find.text('20'), findsOneWidget);

      await tester.pumpWidget(_host(const SizedBox()));
      first.dispose();
      second.dispose();
    });

    testWidgets('HelmController совместим с ValueListenableBuilder', (
      tester,
    ) async {
      final feature = HelmFeature<int, Never>(
        () => StateStore(initialState: 0),
      );
      final controller = feature.currentController;

      await tester.pumpWidget(
        _host(
          ValueListenableBuilder<int>(
            valueListenable: controller,
            builder: (_, value, child) => Text('controller:$value'),
          ),
        ),
      );
      feature.dispatchSync(const SetUse(4));
      await tester.pump();
      expect(find.text('controller:4'), findsOneWidget);

      await tester.pumpWidget(_host(const SizedBox()));
      feature.dispose();
    });

    testWidgets('HelmComputed обновляет Flutter UI от нескольких фич', (
      tester,
    ) async {
      final left = HelmFeature<int, Never>(() => StateStore(initialState: 1));
      final right = HelmFeature<int, Never>(() => StateStore(initialState: 2));
      final total = helmCompute(() => left.value + right.value);

      await tester.pumpWidget(
        _host(
          ListenableBuilder(
            listenable: total,
            builder: (_, child) => Text('total:${total.value}'),
          ),
        ),
      );
      expect(find.text('total:3'), findsOneWidget);

      left.dispatchSync(const SetUse(10));
      await tester.pump();
      expect(find.text('total:12'), findsOneWidget);

      right.dispatchSync(const SetUse(20));
      await tester.pump();
      expect(find.text('total:30'), findsOneWidget);

      await tester.pumpWidget(_host(const SizedBox()));
      total.dispose();
      left.dispose();
      right.dispose();
    });
  });
}
