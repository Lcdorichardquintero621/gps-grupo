import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = 'https://qmhmsqzbnlvpxpifwxvw.supabase.co';
const supabaseAnonKey = 'sb_publishable_komsbWhClsqyBL_QHkM-9w_9tMjYEz5';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const GpsGrupoApp());
}

final db = Supabase.instance.client;

class GpsGrupoApp extends StatelessWidget {
  const GpsGrupoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'GPS Grupo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const InicioPage(),
      );
}

class InicioPage extends StatefulWidget {
  const InicioPage({super.key});
  @override
  State<InicioPage> createState() => _InicioPageState();
}

class _InicioPageState extends State<InicioPage> {
  final _nombre = TextEditingController();
  final _codigo = TextEditingController();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _nombre.text = p.getString('nombre') ?? '';
    });
  }

  String _nuevoCodigo() {
    const c = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(6, (_) => c[r.nextInt(c.length)]).join();
  }

  Future<void> _entrar(String codigo) async {
    final nombre = _nombre.text.trim();
    if (nombre.isEmpty || codigo.trim().length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escribe tu nombre y un código')));
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setString('nombre', nombre);
    var id = p.getString('device_id');
    if (id == null) {
      id =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      await p.setString('device_id', id);
    }
    if (!mounted) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => MapaPage(
                grupo: codigo.trim().toUpperCase(),
                nombre: nombre,
                deviceId: id!)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('GPS Grupo')),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(children: [
            TextField(
                controller: _nombre,
                decoration: const InputDecoration(
                    labelText: 'Tu nombre', border: OutlineInputBorder())),
            const SizedBox(height: 20),
            FilledButton.icon(
                onPressed: () => _entrar(_nuevoCodigo()),
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Crear grupo nuevo')),
            const Divider(height: 40),
            TextField(
                controller: _codigo,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                    labelText: 'Código del grupo',
                    border: OutlineInputBorder())),
            const SizedBox(height: 12),
            OutlinedButton.icon(
                onPressed: () => _entrar(_codigo.text),
                icon: const Icon(Icons.login),
                label: const Text('Unirme al grupo')),
            const SizedBox(height: 24),
            const Text(
                'Al entrar, este teléfono compartirá su ubicación con las '
                'personas del grupo mientras la app esté activa.',
                style: TextStyle(color: Colors.grey)),
          ]),
        ),
      );
}

class MapaPage extends StatefulWidget {
  final String grupo, nombre, deviceId;
  const MapaPage(
      {super.key,
      required this.grupo,
      required this.nombre,
      required this.deviceId});
  @override
  State<MapaPage> createState() => _MapaPageState();
}

class _MapaPageState extends State<MapaPage> {
  final _map = MapController();
  StreamSubscription<Position>? _gps;
  Timer? _latido;
  Position? _pos;
  bool _mapaListo = false;
  bool _centrado = false;
  bool _compartiendo = true;
  String _estado = 'Iniciando…';
  bool _estadoError = false;

  // El stream se crea UNA sola vez (antes se recreaba en cada rebuild).
  late final Stream<List<Map<String, dynamic>>> _stream = db
      .from('ubicaciones')
      .stream(primaryKey: ['device_id']).eq('grupo', widget.grupo);

  @override
  void initState() {
    super.initState();
    _iniciarGps();
    // Reenvía la posición cada 20 s aunque no te muevas.
    _latido = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_compartiendo && _pos != null) _enviar(_pos!);
    });
  }

  void _setEstado(String t, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _estado = t;
      _estadoError = error;
    });
  }

  Future<void> _iniciarGps() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _setEstado('El GPS del teléfono está apagado. Actívalo.', error: true);
      await Geolocator.openLocationSettings();
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      _setEstado('Sin permiso de ubicación. Vuelve a entrar y acepta.',
          error: true);
      return;
    }
    if (perm == LocationPermission.deniedForever) {
      _setEstado(
          'Permiso de ubicación bloqueado. Actívalo en Ajustes > Apps > GPS Grupo.',
          error: true);
      await Geolocator.openAppSettings();
      return;
    }

    _setEstado('Buscando tu ubicación…');

    // Última posición conocida: centra el mapa y comparte casi al instante.
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) _alRecibir(last);
    } catch (_) {}

    _gps = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'GPS Grupo activo',
          notificationText: 'Compartiendo tu ubicación con el grupo',
          enableWakeLock: true,
        ),
      ),
    ).listen(
      _alRecibir,
      onError: (e) => _setEstado('Error de GPS: $e', error: true),
    );
  }

  void _alRecibir(Position pos) {
    _pos = pos;
    _moverPrimeraVez();
    if (_compartiendo) _enviar(pos);
  }

  void _moverPrimeraVez() {
    if (_centrado || !_mapaListo || _pos == null) return;
    _centrado = true;
    try {
      _map.move(LatLng(_pos!.latitude, _pos!.longitude), 16);
    } catch (_) {
      _centrado = false;
    }
  }

  Future<void> _enviar(Position p) async {
    try {
      await db.from('ubicaciones').upsert({
        'device_id': widget.deviceId,
        'grupo': widget.grupo,
        'nombre': widget.nombre,
        'lat': p.latitude,
        'lng': p.longitude,
        'actualizado': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'device_id');
      final t = TimeOfDay.now().format(context);
      _setEstado('Compartiendo ubicación ✓  (último envío $t)');
    } catch (e) {
      _setEstado('No se pudo enviar tu ubicación: $e', error: true);
    }
  }

  Future<void> _borrarMiFila() async {
    try {
      await db.from('ubicaciones').delete().eq('device_id', widget.deviceId);
    } catch (_) {}
  }

  void _alternarCompartir() {
    setState(() => _compartiendo = !_compartiendo);
    if (_compartiendo) {
      if (_pos != null) _enviar(_pos!);
    } else {
      _borrarMiFila();
      _setEstado('Dejaste de compartir tu ubicación');
    }
  }

  Future<void> _salir() async {
    _gps?.cancel();
    _latido?.cancel();
    await _borrarMiFila();
    if (mounted) Navigator.pop(context);
  }

  void _verTodos(List<LatLng> pts) {
    if (pts.isEmpty) return;
    try {
      if (pts.length == 1) {
        _map.move(pts.first, 16);
      } else {
        _map.fitCamera(CameraFit.coordinates(
            coordinates: pts, padding: const EdgeInsets.all(70)));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _gps?.cancel();
    _latido?.cancel();
    _borrarMiFila();
    super.dispose();
  }

  bool _reciente(Map<String, dynamic> u) {
    final t = DateTime.tryParse('${u['actualizado']}');
    if (t == null) return true;
    return DateTime.now().toUtc().difference(t.toUtc()).inMinutes < 15;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Grupo ${widget.grupo}'),
        actions: [
          IconButton(
            tooltip: _compartiendo ? 'Dejar de compartir' : 'Compartir',
            icon: Icon(_compartiendo ? Icons.location_on : Icons.location_off),
            onPressed: _alternarCompartir,
          ),
          IconButton(icon: const Icon(Icons.logout), onPressed: _salir),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _stream,
        builder: (context, snap) {
          final gente = (snap.data ?? [])
              .where((u) => u['lat'] != null && u['lng'] != null)
              .where(_reciente)
              .toList();
          final pts = gente
              .map((u) => LatLng((u['lat'] as num).toDouble(),
                  (u['lng'] as num).toDouble()))
              .toList();

          String estado = _estado;
          bool error = _estadoError;
          if (snap.hasError) {
            estado = 'Error al leer el grupo: ${snap.error}';
            error = true;
          }

          return Stack(children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: const LatLng(0, 0),
                initialZoom: 2,
                onMapReady: () {
                  _mapaListo = true;
                  _moverPrimeraVez();
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.gps_grupo',
                ),
                MarkerLayer(
                  markers: gente.map((u) {
                    final yo = u['device_id'] == widget.deviceId;
                    return Marker(
                      point: LatLng((u['lat'] as num).toDouble(),
                          (u['lng'] as num).toDouble()),
                      width: 90,
                      height: 60,
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: yo ? Colors.teal : Colors.black87,
                              borderRadius: BorderRadius.circular(8)),
                          child: Text('${u['nombre'] ?? '?'}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12)),
                        ),
                        Icon(Icons.location_pin,
                            color: yo ? Colors.teal : Colors.red, size: 32),
                      ]),
                    );
                  }).toList(),
                ),
                const RichAttributionWidget(attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ]),
              ],
            ),
            // Mensaje de estado (muestra errores en vez de ocultarlos)
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: Card(
                color: error ? Colors.red.shade100 : null,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(estado, style: const TextStyle(fontSize: 13)),
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 96,
              child: FloatingActionButton.small(
                tooltip: 'Ver a todos',
                onPressed: () => _verTodos(pts),
                child: const Icon(Icons.group),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Card(
                child: SizedBox(
                  height: 64,
                  child: gente.isEmpty
                      ? const Center(child: Text('Nadie compartiendo todavía'))
                      : ListView(
                          scrollDirection: Axis.horizontal,
                          children: gente
                              .map((u) => Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: ActionChip(
                                      avatar:
                                          const Icon(Icons.person, size: 18),
                                      label: Text('${u['nombre'] ?? '?'}'),
                                      onPressed: () => _map.move(
                                          LatLng((u['lat'] as num).toDouble(),
                                              (u['lng'] as num).toDouble()),
                                          17),
                                    ),
                                  ))
                              .toList(),
                        ),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
