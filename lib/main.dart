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
      id = '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
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
  bool _centrado = false;
  bool _compartiendo = true;

  @override
  void initState() {
    super.initState();
    _iniciarGps();
  }

  Future<void> _iniciarGps() async {
    if (!await Geolocator.isLocationServiceEnabled()) return;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) return;

    _gps = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'GPS Grupo activo',
          notificationText: 'Compartiendo tu ubicación con el grupo',
          enableWakeLock: true,
        ),
      ),
    ).listen((pos) {
      if (!_centrado) {
        _centrado = true;
        _map.move(LatLng(pos.latitude, pos.longitude), 16);
      }
      if (_compartiendo) _enviar(pos);
    });
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
      });
    } catch (_) {}
  }

  Future<void> _salir() async {
    _gps?.cancel();
    try {
      await db.from('ubicaciones').delete().eq('device_id', widget.deviceId);
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _gps?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stream = db
        .from('ubicaciones')
        .stream(primaryKey: ['device_id'])
        .eq('grupo', widget.grupo);

    return Scaffold(
      appBar: AppBar(
        title: Text('Grupo ${widget.grupo}'),
        actions: [
          IconButton(
            tooltip: _compartiendo ? 'Dejar de compartir' : 'Compartir',
            icon: Icon(_compartiendo ? Icons.location_on : Icons.location_off),
            onPressed: () => setState(() => _compartiendo = !_compartiendo),
          ),
          IconButton(icon: const Icon(Icons.logout), onPressed: _salir),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snap) {
          final gente = snap.data ?? [];
          return Stack(children: [
            FlutterMap(
              mapController: _map,
              options: const MapOptions(
                  initialCenter: LatLng(0, 0), initialZoom: 2),
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
                          child: Text(u['nombre'] ?? '?',
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
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Card(
                child: SizedBox(
                  height: 64,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: gente
                        .map((u) => Padding(
                              padding: const EdgeInsets.all(8),
                              child: ActionChip(
                                avatar: const Icon(Icons.person, size: 18),
                                label: Text(u['nombre'] ?? '?'),
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
