import 'package:material_ui/material_ui.dart';

import 'src/app.dart';
import 'src/controller.dart';
import 'src/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(
    store: LocalStore(),
    gateway: GrpcGateway(),
    runtime: LocalRuntime(),
    helper: LocalHelper(),
  );
  runApp(LastOrderApp(controller: controller));
  controller.initialize();
}
