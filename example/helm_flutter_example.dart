import 'package:flutter/widgets.dart';
import 'package:helm_flutter/helm_flutter.dart';

final counterFeature = HelmFeature<int, Never>(
  () => StateStore(initialState: 0),
);

final class Increment implements SyncCommand<int> {
  const Increment();

  @override
  int execute(int current) => current + 1;
}

void main() => runApp(const CounterApp());

final class CounterApp extends StatelessWidget {
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: HelmBuilder<int, Never>(
        counterFeature,
        builder: (context, count) => GestureDetector(
          onTap: () => counterFeature.dispatchSync(const Increment()),
          child: Text('Count: $count'),
        ),
      ),
    ),
  );
}
