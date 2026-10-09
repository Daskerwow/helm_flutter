## 0.3.0

- `HelmBuilder`, `HelmSelector`, `HelmListener`, `HelmConsumer`, `HelmWidget`
  and `StatefulHelmWidget` now require a stable `HelmFeature` identity for the
  lifetime of an Element. Use a new `Key` to intentionally mount a new feature.
- Added the local `helm_core` package and re-exported its public API from the
  canonical `helm_flutter` entry point.
- Hardened computed dependencies, subscriptions, stream dispatch and family
  lifecycle ownership.
