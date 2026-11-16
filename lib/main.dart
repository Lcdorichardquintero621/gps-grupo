import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

const supabaseUrl = 'https://qmhmsqzbnlvpxpifwxvw.supabase.co';
const supabaseAnonKey = 'sb_publishable_komsbWhClsqyBL_QHkM-9w_9tMjYEz5';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const GeolocalizacionApp());
}

final db = Supabase.instance.client;

// Colores para los demás miembros (el tuyo siempre es verde azulado).
final List<Color> _paleta = [
  Colors.red,
  Colors.orange.shade800,
  Colors.purple,
  Colors.blue,
  Colors.pink,
  Colors.brown,
  Colors.indigo,
  Colors.deepOrange,
  Colors.cyan.shade700,
  Colors.blueGrey,
];

void aviso(BuildContext c, String t) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(t)));
}

Future<bool> confirmar(
    BuildContext c, String titulo, String texto, String boton) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(titulo),
      content: Text(texto),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(boton)),
      ],
    ),
  );
  return r == true;
}

// ---------------------------------------------------------------------------
// Datos locales
// ---------------------------------------------------------------------------

class Grupo {
  final String codigo;
  final String nombre;
  final bool dueno;
  const Grupo(this.codigo, this.nombre, this.dueno);

  Map<String, dynamic> toJson() => {'c': codigo, 'n': nombre, 'd': dueno};

  static Grupo fromJson(Map<String, dynamic> j) =>
      Grupo('${j['c']}', '${j['n']}', j['d'] == true);
}

class Almacen {
  static Future<List<Grupo>> leer() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList('grupos') ?? <String>[];
    final out = <Grupo>[];
    for (final s in raw) {
      try {
        out.add(Grupo.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    return out;
  }

  static Future<void> guardar(List<Grupo> g) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        'grupos', g.map((x) => jsonEncode(x.toJson())).toList());
  }

  static Future<void> quitar(String codigo) async {
    final g = await leer();
    await guardar(g.where((x) => x.codigo != codigo).toList());
  }

  static Future<String> deviceId() async {
    final p = await SharedPreferences.getInstance();
    var id = p.getString('device_id');
    if (id == null) {
      id =
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      await p.setString('device_id', id);
    }
    return id;
  }

  static Future<String> nombre() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('nombre') ?? '';
  }

  static Future<void> setNombre(String n) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('nombre', n);
  }
}

// ---------------------------------------------------------------------------
// Operaciones con el servidor
// ---------------------------------------------------------------------------

String _nuevoCodigo() {
  const c = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  return List.generate(6, (_) => c[r.nextInt(c.length)]).join();
}

Future<Grupo> crearGrupo(String nombre, String deviceId) async {
  for (var i = 0; i < 5; i++) {
    final codigo = _nuevoCodigo();
    try {
      await db.from('grupos').insert({
        'codigo': codigo,
        'nombre': nombre,
        'creador': deviceId,
      });
      return Grupo(codigo, nombre, true);
    } on PostgrestException catch (e) {
      if (e.code == '23505') continue; // código repetido, probar otro
      rethrow;
    }
  }
  throw Exception('No se pudo generar un código único');
}

Future<Grupo?> buscarGrupo(String codigo, String deviceId) async {
  final r =
      await db.from('grupos').select().eq('codigo', codigo).maybeSingle();
  if (r == null) return null;
  return Grupo(codigo, '${r['nombre']}', '${r['creador']}' == deviceId);
}

Future<void> quitarMiUbicacion(String codigo, String deviceId) async {
  try {
    // Primero la marco como "vieja" (los demás la ocultan al instante)...
    await db
        .from('ubicaciones')
        .update({'actualizado': '1970-01-01T00:00:00Z'})
        .eq('device_id', deviceId)
        .eq('grupo', codigo);
  } catch (_) {}
  try {
    // ...y luego la borro.
    await db
        .from('ubicaciones')
        .delete()
        .eq('device_id', deviceId)
        .eq('grupo', codigo);
  } catch (_) {}
}

Future<void> eliminarGrupoServidor(Grupo g, String deviceId) async {
  try {
    await db
        .from('ubicaciones')
        .update({'actualizado': '1970-01-01T00:00:00Z'}).eq('grupo', g.codigo);
  } catch (_) {}
  await db.from('ubicaciones').delete().eq('grupo', g.codigo);
  await db
      .from('grupos')
      .delete()
      .eq('codigo', g.codigo)
      .eq('creador', deviceId);
}

Future<void> compartirWhatsApp(BuildContext context, Grupo g) async {
  final texto = 'Únete a mi grupo "${g.nombre}" en Geolocalizacion.\n'
      'Código de invitación: ${g.codigo}';
  final enc = Uri.encodeComponent(texto);
  for (final u in ['whatsapp://send?text=$enc', 'https://wa.me/?text=$enc']) {
    try {
      if (await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {}
  }
  await Clipboard.setData(ClipboardData(text: texto));
  if (context.mounted) {
    aviso(context,
        'No se pudo abrir WhatsApp. Copié el mensaje para que lo pegues.');
  }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

class GeolocalizacionApp extends StatelessWidget {
  const GeolocalizacionApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Geolocalizacion',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const GruposPage(),
      );
}

// ---------------------------------------------------------------------------
// Pantalla 1: lista de grupos
// ---------------------------------------------------------------------------

class GruposPage extends StatefulWidget {
  const GruposPage({super.key});
  @override
  State<GruposPage> createState() => _GruposPageState();
}

class _GruposPageState extends State<GruposPage> {
  final _nombre = TextEditingController();
  List<Grupo> _grupos = [];
  String _deviceId = '';
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _nombre.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    _deviceId = await Almacen.deviceId();
    _nombre.text = await Almacen.nombre();
    _grupos = await Almacen.leer();
    if (mounted) setState(() => _cargando = false);
    _verificar();
  }

  // Quita de la lista los grupos que el creador ya eliminó.
  Future<void> _verificar() async {
    if (_grupos.isEmpty) return;
    try {
      final rows = await db
          .from('grupos')
          .select('codigo')
          .inFilter('codigo', _grupos.map((g) => g.codigo).toList());
      final vivos = rows.map((r) => '${r['codigo']}').toSet();
      final quitados = _grupos.where((g) => !vivos.contains(g.codigo)).toList();
      if (quitados.isEmpty) return;
      _grupos = _grupos.where((g) => vivos.contains(g.codigo)).toList();
      await Almacen.guardar(_grupos);
      if (!mounted) return;
      setState(() {});
      aviso(context,
          'Grupo eliminado por su creador: ${quitados.map((g) => g.nombre).join(', ')}');
    } catch (_) {}
  }

  bool _nombreOk() {
    if (_nombre.text.trim().isEmpty) {
      aviso(context, 'Escribe tu nombre arriba');
      return false;
    }
    return true;
  }

  Future<String?> _pedirTexto(String titulo, String etiqueta,
      {bool mayusculas = false}) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: mayusculas
              ? TextCapitalization.characters
              : TextCapitalization.sentences,
          decoration: InputDecoration(
              labelText: etiqueta, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Aceptar')),
        ],
      ),
    );
  }

  Future<void> _crear() async {
    if (!_nombreOk()) return;
    final nombre = await _pedirTexto('Nombre del grupo', 'Ej. Familia, Viaje');
    if (nombre == null || nombre.isEmpty) return;
    try {
      final g = await crearGrupo(nombre, _deviceId);
      _grupos = [..._grupos, g];
      await Almacen.guardar(_grupos);
      if (!mounted) return;
      setState(() {});
      _abrir(g);
    } catch (e) {
      if (mounted) aviso(context, 'No se pudo crear el grupo: $e');
    }
  }

  Future<void> _unirse() async {
    if (!_nombreOk()) return;
    final txt = await _pedirTexto('Unirme a un grupo', 'Código del grupo',
        mayusculas: true);
    if (txt == null) return;
    final codigo = txt.trim().toUpperCase();
    if (codigo.length < 4) {
      if (mounted) aviso(context, 'Escribe el código del grupo');
      return;
    }
    final ya = _grupos.where((g) => g.codigo == codigo).toList();
    if (ya.isNotEmpty) {
      _abrir(ya.first);
      return;
    }
    try {
      final g = await buscarGrupo(codigo, _deviceId);
      if (!mounted) return;
      if (g == null) {
        aviso(context, 'No existe un grupo con el código $codigo');
        return;
      }
      _grupos = [..._grupos, g];
      await Almacen.guardar(_grupos);
      if (!mounted) return;
      setState(() {});
      _abrir(g);
    } catch (e) {
      if (mounted) aviso(context, 'No se pudo unir al grupo: $e');
    }
  }

  void _menuNuevo() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.add_location_alt),
            title: const Text('Crear grupo nuevo'),
            onTap: () {
              Navigator.pop(ctx);
              _crear();
            },
          ),
          ListTile(
            leading: const Icon(Icons.login),
            title: const Text('Unirme con un código'),
            onTap: () {
              Navigator.pop(ctx);
              _unirse();
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _abrir(Grupo g) async {
    if (!_nombreOk()) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapaPage(
            grupo: g, nombre: _nombre.text.trim(), deviceId: _deviceId),
      ),
    );
    if (!mounted) return;
    _grupos = await Almacen.leer();
    if (mounted) setState(() {});
    _verificar();
  }

  Future<void> _salirDe(Grupo g) async {
    final ok = await confirmar(
        context,
        'Salir del grupo',
        '¿Salir de "${g.nombre}"? El grupo seguirá existiendo y podrás '
            'volver a entrar con el código ${g.codigo}.',
        'Salir');
    if (!ok) return;
    await quitarMiUbicacion(g.codigo, _deviceId);
    _grupos = _grupos.where((x) => x.codigo != g.codigo).toList();
    await Almacen.guardar(_grupos);
    if (mounted) setState(() {});
  }

  Future<void> _eliminar(Grupo g) async {
    final ok = await confirmar(
        context,
        'Eliminar grupo',
        '¿Eliminar "${g.nombre}" para todos? Esta acción no se puede deshacer.',
        'Eliminar');
    if (!ok) return;
    try {
      await eliminarGrupoServidor(g, _deviceId);
      _grupos = _grupos.where((x) => x.codigo != g.codigo).toList();
      await Almacen.guardar(_grupos);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) aviso(context, 'No se pudo eliminar: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child:
                Image.asset('assets/logo.png', width: 38, height: 38),
          ),
          const SizedBox(width: 10),
          const Text('Geolocalizacion'),
        ]),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _menuNuevo,
        icon: const Icon(Icons.add),
        label: const Text('Nuevo grupo'),
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: _nombre,
                  onChanged: (v) => Almacen.setNombre(v.trim()),
                  decoration: const InputDecoration(
                      labelText: 'Tu nombre',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder()),
                ),
              ),
              Expanded(
                child: _grupos.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.groups,
                                    size: 72, color: Colors.grey),
                                const SizedBox(height: 12),
                                const Text('Aún no tienes grupos',
                                    style: TextStyle(fontSize: 16)),
                                const SizedBox(height: 20),
                                FilledButton.icon(
                                    onPressed: _crear,
                                    icon: const Icon(Icons.add_location_alt),
                                    label: const Text('Crear grupo nuevo')),
                                const SizedBox(height: 10),
                                OutlinedButton.icon(
                                    onPressed: _unirse,
                                    icon: const Icon(Icons.login),
                                    label: const Text('Unirme con un código')),
                              ]),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                        itemCount: _grupos.length,
                        itemBuilder: (context, i) {
                          final g = _grupos[i];
                          return Card(
                            child: ListTile(
                              leading: const CircleAvatar(
                                  child: Icon(Icons.groups)),
                              title: Text(g.nombre),
                              subtitle: Text(
                                  'Código: ${g.codigo}${g.dueno ? '  ·  Lo creaste tú' : ''}'),
                              onTap: () => _abrir(g),
                              trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Invitar por WhatsApp',
                                      icon: const Icon(Icons.share),
                                      onPressed: () =>
                                          compartirWhatsApp(context, g),
                                    ),
                                    PopupMenuButton<String>(
                                      onSelected: (v) {
                                        if (v == 'salir') _salirDe(g);
                                        if (v == 'eliminar') _eliminar(g);
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                            value: 'salir',
                                            child: Text('Salir del grupo')),
                                        if (g.dueno)
                                          const PopupMenuItem(
                                              value: 'eliminar',
                                              child:
                                                  Text('Eliminar grupo')),
                                      ],
                                    ),
                                  ]),
                            ),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Pantalla 2: mapa del grupo
// ---------------------------------------------------------------------------

class MapaPage extends StatefulWidget {
  final Grupo grupo;
  final String nombre, deviceId;
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
  Timer? _vigia;
  Position? _pos;
  List<LatLng> _pts = [];
  bool _mapaListo = false;
  bool _ajustado = false;
  bool _ajustadoConmigo = false;
  bool _centrado = false;
  bool _compartiendo = true;
  bool _cerrando = false;
  String _estado = 'Iniciando…';
  bool _estadoError = false;

  late final Stream<List<Map<String, dynamic>>> _stream = db
      .from('ubicaciones')
      .stream(primaryKey: ['device_id']).eq('grupo', widget.grupo.codigo);

  @override
  void initState() {
    super.initState();
    _iniciarGps();
    // Reenvía tu posición cada 20 s aunque no te muevas.
    _latido = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_compartiendo && _pos != null) _enviar(_pos!);
    });
    // Revisa cada 30 s que el grupo no haya sido eliminado.
    _vigia = Timer.periodic(
        const Duration(seconds: 30), (_) => _revisarGrupo());
    _revisarGrupo();
  }

  void _setEstado(String t, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _estado = t;
      _estadoError = error;
    });
  }

  Future<void> _revisarGrupo() async {
    if (_cerrando) return;
    try {
      final r = await db
          .from('grupos')
          .select('codigo')
          .eq('codigo', widget.grupo.codigo)
          .maybeSingle();
      if (r == null && !_cerrando) _grupoEliminado();
    } catch (_) {}
  }

  Future<void> _grupoEliminado() async {
    _cerrando = true;
    _gps?.cancel();
    _latido?.cancel();
    _vigia?.cancel();
    await Almacen.quitar(widget.grupo.codigo);
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    m.showSnackBar(SnackBar(
        content: Text('El grupo "${widget.grupo.nombre}" fue eliminado')));
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
          'Permiso de ubicación bloqueado. Actívalo en Ajustes > Apps > Geolocalizacion.',
          error: true);
      await Geolocator.openAppSettings();
      return;
    }

    _setEstado('Buscando tu ubicación…');

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
          notificationTitle: 'Geolocalizacion activo',
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
    if (_centrado || _ajustado || !_mapaListo || _pos == null) return;
    _centrado = true;
    try {
      _map.move(LatLng(_pos!.latitude, _pos!.longitude), 15);
    } catch (_) {
      _centrado = false;
    }
  }

  Future<void> _enviar(Position p) async {
    if (_cerrando) return;
    try {
      await db.from('ubicaciones').upsert({
        'device_id': widget.deviceId,
        'grupo': widget.grupo.codigo,
        'nombre': widget.nombre,
        'lat': p.latitude,
        'lng': p.longitude,
        'actualizado': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'device_id');
      if (!mounted) return;
      final t = TimeOfDay.now().format(context);
      _setEstado('Compartiendo ubicación ✓  (último envío $t)');
    } catch (e) {
      _setEstado('No se pudo enviar tu ubicación: $e', error: true);
    }
  }

  void _alternarCompartir() {
    setState(() => _compartiendo = !_compartiendo);
    if (_compartiendo) {
      if (_pos != null) _enviar(_pos!);
    } else {
      quitarMiUbicacion(widget.grupo.codigo, widget.deviceId);
      _setEstado('Dejaste de compartir tu ubicación');
    }
  }

  Future<void> _salirDelGrupo() async {
    final ok = await confirmar(
        context,
        'Salir del grupo',
        '¿Salir de "${widget.grupo.nombre}"? El grupo seguirá existiendo y '
            'podrás volver a entrar con el código ${widget.grupo.codigo}.',
        'Salir');
    if (!ok) return;
    _cerrando = true;
    _gps?.cancel();
    _latido?.cancel();
    _vigia?.cancel();
    await quitarMiUbicacion(widget.grupo.codigo, widget.deviceId);
    await Almacen.quitar(widget.grupo.codigo);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _eliminarGrupo() async {
    final ok = await confirmar(
        context,
        'Eliminar grupo',
        '¿Eliminar "${widget.grupo.nombre}" para todos? Esta acción no se puede deshacer.',
        'Eliminar');
    if (!ok) return;
    _cerrando = true;
    try {
      await eliminarGrupoServidor(widget.grupo, widget.deviceId);
    } catch (e) {
      _cerrando = false;
      if (mounted) aviso(context, 'No se pudo eliminar: $e');
      return;
    }
    _gps?.cancel();
    _latido?.cancel();
    _vigia?.cancel();
    await Almacen.quitar(widget.grupo.codigo);
    if (mounted) Navigator.pop(context);
  }

  void _verTodos(List<LatLng> pts) {
    if (pts.isEmpty) return;
    try {
      if (pts.length == 1) {
        _map.move(pts.first, 16);
      } else {
        _map.fitCamera(CameraFit.coordinates(
            coordinates: pts,
            padding: const EdgeInsets.all(70),
            maxZoom: 17));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _gps?.cancel();
    _latido?.cancel();
    _vigia?.cancel();
    // Al volver a la lista dejas de compartir, pero sigues en el grupo.
    quitarMiUbicacion(widget.grupo.codigo, widget.deviceId);
    super.dispose();
  }

  // Ignora a quien lleva más de 5 minutos sin actualizar.
  bool _reciente(Map<String, dynamic> u) {
    final t = DateTime.tryParse('${u['actualizado']}');
    if (t == null) return true;
    return DateTime.now().toUtc().difference(t.toUtc()).inMinutes < 5;
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.grupo;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(g.nombre, style: const TextStyle(fontSize: 18)),
          Text('Código ${g.codigo}', style: const TextStyle(fontSize: 12)),
        ]),
        actions: [
          IconButton(
            tooltip: 'Invitar por WhatsApp',
            icon: const Icon(Icons.share),
            onPressed: () => compartirWhatsApp(context, g),
          ),
          IconButton(
            tooltip: _compartiendo ? 'Dejar de compartir' : 'Compartir',
            icon: Icon(_compartiendo ? Icons.location_on : Icons.location_off),
            onPressed: _alternarCompartir,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'salir') _salirDelGrupo();
              if (v == 'eliminar') _eliminarGrupo();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'salir', child: Text('Salir del grupo')),
              if (g.dueno)
                const PopupMenuItem(
                    value: 'eliminar', child: Text('Eliminar grupo')),
            ],
          ),
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
          final otros = gente
              .map((u) => '${u['device_id']}')
              .where((id) => id != widget.deviceId)
              .toList()
            ..sort();
          Color colorDe(String id) {
            if (id == widget.deviceId) return Colors.teal;
            final i = otros.indexOf(id);
            return _paleta[(i < 0 ? 0 : i) % _paleta.length];
          }

          _pts = pts;

          // Ajusta el mapa para que se vea a todo el grupo (una vez, y otra
          // vez cuando aparece tu propia ubicación).
          final tengoMio =
              gente.any((u) => u['device_id'] == widget.deviceId);
          if (_mapaListo &&
              gente.isNotEmpty &&
              (!_ajustado || (!_ajustadoConmigo && tengoMio))) {
            _ajustado = true;
            if (tengoMio) _ajustadoConmigo = true;
            final copia = List<LatLng>.from(pts);
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _verTodos(copia));
          }

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
                maxZoom: 19,
                onMapReady: () {
                  _mapaListo = true;
                  _moverPrimeraVez();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() {});
                  });
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.gps_grupo',
                ),
                MarkerLayer(
                  markers: gente.map((u) {
                    final id = '${u['device_id']}';
                    final yo = id == widget.deviceId;
                    final color = colorDe(id);
                    return Marker(
                      point: LatLng((u['lat'] as num).toDouble(),
                          (u['lng'] as num).toDouble()),
                      width: 90,
                      height: 64,
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(8)),
                          child: Text(yo ? 'Tú' : '${u['nombre'] ?? '?'}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12)),
                        ),
                        Icon(Icons.location_pin,
                            color: color, size: yo ? 38 : 32),
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
                onPressed: () => _verTodos(_pts),
                child: const Icon(Icons.zoom_out_map),
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
                          children: gente.map((u) {
                            final id = '${u['device_id']}';
                            final yo = id == widget.deviceId;
                            return Padding(
                              padding: const EdgeInsets.all(8),
                              child: ActionChip(
                                avatar: CircleAvatar(
                                  radius: 12,
                                  backgroundColor: colorDe(id),
                                  child: const Icon(Icons.person,
                                      size: 14, color: Colors.white),
                                ),
                                label: Text(yo ? 'Tú' : '${u['nombre'] ?? '?'}'),
                                onPressed: () => _map.move(
                                    LatLng((u['lat'] as num).toDouble(),
                                        (u['lng'] as num).toDouble()),
                                    17),
                              ),
                            );
                          }).toList(),
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
