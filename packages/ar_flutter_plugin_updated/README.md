# ar_flutter_plugin_updated
[![pub package](https://img.shields.io/pub/v/ar_flutter_plugin_updated.svg)](https://pub.dev/packages/ar_flutter_plugin_updated)



This version is a direct adaptation of the original ar_flutter_plugin (https://pub.dev/packages/ar_flutter_plugin), maintaining all its powerful features and capabilities.
This fork was created because the original plugin had not been updated since 2022. Changes include an update to the AR Core endpoint, a gradle upgrade, and compatibility with FlutterFlow.

Key Features:

This version has been specifically adjusted to ensure seamless integration with FlutterFlow, enabling developers to incorporate augmented reality features into their FlutterFlow projects without any compatibility issues.



## Original package

For details on how to use the plugin and its functionalities, please refer to the original documentation at https://pub.dev/packages/ar_flutter_plugin.

⚠️ If you are developing for iOS in Flutterflow, it's crucial to follow the procedure outlined for managing permissions, as detailed on the original AR Flutter Plugin page: https://pub.dev/packages/ar_flutter_plugin.
Unfortunately, at this stage, it is not possible to carry out this procedure within FlutterFlow. Therefore, it is necessary to publish your project with github and make the modifications manually. And then publish wih Github selected in Deployment Sources : https://docs.flutterflow.io/customizing-your-app/manage-custom-code-in-github#id-9.-deploy-from-the-main-branch

⚠️ If you're utilizing examples from the original plugin that involve the geoflutterfire package, please note that you'll need to use the geoflutterfire2 plugin instead, available at https://pub.dev/packages/geoflutterfire2.
Also, remember to replace 'Geoflutterfire()' with 'GeoFlutterFire()' in your code to ensure proper functionality with this updated package.



### Installing

Add the Flutter package to your project by running:

```bash
flutter pub add ar_flutter_plugin_updated
```

Or manually add this to your `pubspec.yaml` file (and run `flutter pub get`):
# ar_flutter_plugin_updated package extension

```yaml
dependencies:
  ar_flutter_plugin_updated: ^0.0.1
```

### Importing

Add this to your code:

```dart
import 'package:ar_flutter_plugin_updated/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_updated/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_updated/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_updated/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_updated/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_updated/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_updated/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_updated/models/ar_node.dart';
import 'package:ar_flutter_plugin_updated/widgets/ar_view.dart';
```