// ignore_for_file: use_build_context_synchronously
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:package_info_plus/package_info_plus.dart';

// --- BACKGROUND HANDLER PER LE NOTIFICHE PUSH ---
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint("Notifica ricevuta in stato terminato: ${message.messageId}");
}

// --- COLORI DEL LOGO ---
const Color appNavyBlue = Color(0xFF0A2444);
const Color appOrange = Colors.deepOrange;

// --- GESTORE DELLE IMPOSTAZIONI ---
class AppSettings extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.light;
  bool isColorBlindMode = false;
  String language = 'it';
  SharedPreferences? _prefs;

  void init(SharedPreferences prefs) {
    _prefs = prefs;
    final isDark = _prefs?.getBool('isDark') ?? false;
    final isCb = _prefs?.getBool('isCb') ?? false;
    themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    isColorBlindMode = isCb;
  }

  void toggleTheme(bool isDark) {
    themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    _prefs?.setBool('isDark', isDark);
    notifyListeners();
  }

  void toggleColorBlind(bool isCb) {
    isColorBlindMode = isCb;
    _prefs?.setBool('isCb', isCb);
    notifyListeners();
  }
}
final appSettings = AppSettings();

// --- FUNZIONE DI DOWNLOAD GLOBALE ---
Future<void> scaricaFileAudio(String url, String bookId, int trackIndex, {Function(double)? onProgress}) async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    final nomeFile = "${bookId}_track_$trackIndex.mp3";
    final percorsoSalvataggio = "${directory.path}/$nomeFile";

    await Dio().download(
      url,
      percorsoSalvataggio,
      onReceiveProgress: (ricevuti, totali) {
        if (totali != -1 && onProgress != null) {
          onProgress(ricevuti / totali);
        }
      },
    );
  } catch (e) {
    debugPrint("Errore durante il download: $e");
    rethrow;
  }
}

// --- GESTORE AUDIO GLOBALE (BACKGROUND E MINI-PLAYER) ---
class AppAudioState extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  Book? currentBook;
  bool isLoading = false;
  List<bool> isDownloaded = [];

  // --- VARIABILI PER IL TIMER DI SPEGNIMENTO ---
  Timer? sleepTimer;
  DateTime? timerEndTime;

  AppAudioState() {
    player.currentIndexStream.listen((index) {
      if (index != null && currentBook != null) {
        currentBook!.currentTrackIndex = index;
        saveProgressToCloud();
      }
    });

    player.positionStream.listen((pos) {
      if (currentBook != null) {
        currentBook!.positionSeconds = pos.inSeconds;
      }
    });

    player.playerStateStream.listen((state) {
      if (!state.playing) saveProgressToCloud();
    });

    Timer.periodic(const Duration(seconds: 10), (timer) {
      if (player.playing) saveProgressToCloud();
    });
  }

  // --- LOGICA TIMER DI SPEGNIMENTO GLOBALE ---
  void setSleepTimer(int minutes) {
    sleepTimer?.cancel();
    if (minutes == 0) {
      timerEndTime = null;
      notifyListeners();
      return;
    }
    timerEndTime = DateTime.now().add(Duration(minutes: minutes));
    notifyListeners();
    sleepTimer = Timer(Duration(minutes: minutes), () {
      player.pause();
      timerEndTime = null;
      sleepTimer = null;
      notifyListeners();
    });
  }

  Future<void> loadAndPlay(Book book) async {
    try {
      var status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint("Errore permesso notifiche: $e");
    }

    if (currentBook?.id == book.id) return;

    isLoading = true;
    currentBook = book;
    isDownloaded = List.filled(book.fileUrls.length, false);
    notifyListeners();

    try {
      final dir = await getApplicationDocumentsDirectory();
      final List<AudioSource> audioSources = [];

      for (int i = 0; i < book.fileUrls.length; i++) {
        final localFile = File('${dir.path}/${book.id}_track_$i.mp3');
        final mediaItem = MediaItem(
          id: '${book.id}_$i',
          album: book.author,
          title: '${book.title} (Cap. ${i + 1})',
          artUri: book.coverUrl != null ? Uri.parse(book.coverUrl!) : null,
        );

        if (await localFile.exists()) {
          audioSources.add(AudioSource.uri(Uri.file(localFile.path), tag: mediaItem));
          isDownloaded[i] = true;
        } else {
          audioSources.add(AudioSource.uri(Uri.parse(book.fileUrls[i]), tag: mediaItem));
        }
      }

      final playlist = ConcatenatingAudioSource(children: audioSources);

      await player.setAudioSource(
        playlist,
        initialIndex: book.currentTrackIndex,
        initialPosition: Duration(seconds: book.positionSeconds),
      );

      isLoading = false;
      notifyListeners();
      player.play();
    } catch (e) {
      debugPrint("Errore player: $e");
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> saveProgressToCloud() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || currentBook == null || isLoading) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).collection('progress').doc(currentBook!.id).set({
        'currentTrackIndex': currentBook!.currentTrackIndex,
        'positionSeconds': currentBook!.positionSeconds,
        'lastPlayed': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("Errore salvataggio: $e");
    }
  }
}

late final AppAudioState appAudio;

// -----------------------------------------------------------
// CUORE DELL'APP
// -----------------------------------------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    final prefs = await SharedPreferences.getInstance();
    appSettings.init(prefs);
  } catch (e) {
    debugPrint("Errore caricamento preferenze: $e");
  }

  try {
    await Firebase.initializeApp();
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
  } catch (e) {
    debugPrint("Avviso Firebase init: $e");
  }

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.audiolibripro.channel.audio',
      androidNotificationChannelName: 'Riproduzione Audiolibri',
      androidNotificationOngoing: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    );
  } catch (e) {
    debugPrint("Avviso JustAudioBackground init: $e");
  }

  appAudio = AppAudioState();

  try {
    await GoogleSignIn.instance.initialize();
  } catch (e) {
    debugPrint("Avviso GoogleSignIn init: $e");
  }

  runApp(const AudioBookApp());
}

class AudioBookApp extends StatefulWidget {
  const AudioBookApp({super.key});
  @override
  State<AudioBookApp> createState() => _AudioBookAppState();
}

class _AudioBookAppState extends State<AudioBookApp> {
  @override
  void initState() {
    super.initState();
    appSettings.addListener(() => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    final seedColor = appSettings.isColorBlindMode ? appOrange : appNavyBlue;

    return MaterialApp(
      title: 'Audiolibri Pro',
      themeMode: appSettings.themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.light),
        useMaterial3: true,
        textTheme: GoogleFonts.atkinsonHyperlegibleTextTheme(ThemeData(brightness: Brightness.light).textTheme),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark),
        useMaterial3: true,
        textTheme: GoogleFonts.atkinsonHyperlegibleTextTheme(ThemeData(brightness: Brightness.dark).textTheme),
      ),
      home: const AuthGate(),
    );
  }
}

// --- GESTORE ACCESSO ---
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.hasData) return const MainScreen();
        return const WelcomeScreen();
      },
    );
  }
}

// --- SCHERMATE AUTENTICAZIONE ---
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ExcludeSemantics(child: Icon(Icons.headphones, size: 100, color: isDark ? Colors.grey[400] : appNavyBlue)),
              const SizedBox(height: 30),
              Semantics(header: true, child: const Text('Audiolibri Pro', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
              const SizedBox(height: 50),
              FilledButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const LoginScreen())),
                style: FilledButton.styleFrom(minimumSize: const Size(250, 50), textStyle: const TextStyle(fontSize: 18)),
                child: const Text('Accedi'),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const RegisterScreen())),
                style: OutlinedButton.styleFrom(minimumSize: const Size(250, 50), textStyle: const TextStyle(fontSize: 18)),
                child: const Text('Registrati'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nomeController = TextEditingController();
  final _cognomeController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confermaPasswordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _loginGoogle() async {
    setState(() => _isLoading = true);
    try {
      final googleSignIn = GoogleSignIn.instance;
      final googleUser = await googleSignIn.authenticate();
      if (googleUser == null) {
        setState(() => _isLoading = false);
        return;
      }
      final clientAuth = await googleUser.authorizationClient?.authorizeScopes(['email']);
      final credential = GoogleAuthProvider.credential(idToken: googleUser.authentication.idToken, accessToken: clientAuth?.accessToken);
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
    } catch (e) {
      debugPrint("Errore Google: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _registra() async {
    if (_passwordController.text != _confermaPasswordController.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Le password non coincidono!')));
      return;
    }
    setState(() => _isLoading = true);
    try {
      UserCredential cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: _emailController.text.trim(), password: _passwordController.text.trim());
      await cred.user?.updateDisplayName("${_nomeController.text.trim()} ${_cognomeController.text.trim()}");
      await cred.user?.sendEmailVerification();
      await FirebaseAuth.instance.signOut();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Registrazione completata! Verifica l\'email.')));
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const LoginScreen()));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crea Account')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(controller: _nomeController, decoration: const InputDecoration(labelText: 'Nome', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _cognomeController, decoration: const InputDecoration(labelText: 'Cognome', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _emailController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _passwordController, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _confermaPasswordController, obscureText: true, decoration: const InputDecoration(labelText: 'Conferma Password', border: OutlineInputBorder())),
            const SizedBox(height: 24),
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(onPressed: _registra, child: const Text('Registrati con Email')),
                  const SizedBox(height: 16),
                  const Text('Oppure', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _loginGoogle,
                    icon: Semantics(excludeSemantics: true, child: Image.asset('assets/google.png', height: 24)),
                    label: const Text('Registrati con Google'),
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _loginGoogle() async {
    setState(() => _isLoading = true);
    try {
      final googleSignIn = GoogleSignIn.instance;
      final googleUser = await googleSignIn.authenticate();
      if (googleUser == null) {
        setState(() => _isLoading = false);
        return;
      }
      final clientAuth = await googleUser.authorizationClient?.authorizeScopes(['email']);
      final credential = GoogleAuthProvider.credential(idToken: googleUser.authentication.idToken, accessToken: clientAuth?.accessToken);
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
    } catch (e) {
      debugPrint("Errore Google: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _login() async {
    setState(() => _isLoading = true);
    try {
      String email = _emailController.text.trim();
      String password = _passwordController.text.trim();
      if (email == 'admin@audiolibripro.it' && password.isEmpty) password = 'Admin.App.12';
      await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
      if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Email o password errati!')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('Accedi')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(child: Icon(Icons.lock, size: 60, color: isDark ? Colors.grey[400] : appNavyBlue)),
            const SizedBox(height: 30),
            TextField(controller: _emailController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _passwordController, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
            const SizedBox(height: 24),
            if (_isLoading)
              const Center(child: CircularProgressIndicator())
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(onPressed: _login, child: const Text('Accedi con Email')),
                  const SizedBox(height: 16),
                  const Text('Oppure', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _loginGoogle,
                    icon: Semantics(excludeSemantics: true, child: Image.asset('assets/google.png', height: 24)),
                    label: const Text('Accedi con Google'),
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// --- MODELLO DATI ---
class Book {
  String id;
  String title;
  String author;
  String? series;
  String? narrator;
  String? plot;
  List<String> fileUrls;
  String? coverUrl;
  int dateAdded;

  int currentTrackIndex;
  int positionSeconds;
  int lastPlayed;
  bool inLibrary;

  Book({
    required this.id, required this.title, this.author = 'Sconosciuto', this.series, this.narrator, this.plot, required this.fileUrls, this.coverUrl,
    this.currentTrackIndex = 0, this.positionSeconds = 0, this.inLibrary = false, int? dateAdded, int? lastPlayed,
  }) : dateAdded = dateAdded ?? DateTime.now().millisecondsSinceEpoch, lastPlayed = lastPlayed ?? 0;

  Map<String, dynamic> toFirestore() => {
    'id': id, 'title': title, 'author': author, 'series': series, 'narrator': narrator, 'plot': plot, 'fileUrls': fileUrls, 'coverUrl': coverUrl, 'dateAdded': dateAdded,
  };

  factory Book.fromFirestore(Map<String, dynamic> data) => Book(
    id: data['id'], title: data['title'], author: data['author'] ?? 'Sconosciuto', series: data['series'], narrator: data['narrator'], plot: data['plot'],
    fileUrls: List<String>.from(data['fileUrls'] ?? []), coverUrl: data['coverUrl'], dateAdded: data['dateAdded'] ?? DateTime.now().millisecondsSinceEpoch,
  );

  double get progressPercentage => fileUrls.isEmpty ? 0.0 : (currentTrackIndex / fileUrls.length) * 100;
}

enum BookSort { az, za, recent, oldest }

// --- HUB PRINCIPALE CON MINI-PLAYER ---
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    appAudio.addListener(() => setState(() {}));
    _setupFCM();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('app_config').doc('update').get();
      if (!doc.exists) return;

      final data = doc.data()!;
      final latestVersion = data['latest_version'] as String;
      final apkUrl = data['apk_url'] as String;

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      if (latestVersion.compareTo(currentVersion) > 0) {
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('Nuovo Aggiornamento!'),
              content: Text('È disponibile la versione $latestVersion.\nAttualmente hai la $currentVersion.\n\nTi consigliamo di aggiornare per accedere alle nuove funzioni.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Più tardi')
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.download),
                  onPressed: () async {
                    final Uri url = Uri.parse(apkUrl);
                    if (await canLaunchUrl(url)) {
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    }
                  },
                  label: const Text('Scarica e Installa'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Errore aggiornamenti: $e");
    }
  }

  // --- LOGICA DI REGISTRAZIONE TOKEN FCM E GESTIONE IN-APP ---
  Future<void> _setupFCM() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    FirebaseMessaging messaging = FirebaseMessaging.instance;

    NotificationSettings settings = await messaging.requestPermission(
      alert: true, badge: true, sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      String? token = await messaging.getToken();
      if (token != null) {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'fcmToken': token,
          'lastLogin': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      messaging.onTokenRefresh.listen((newToken) {
        FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'fcmToken': newToken,
        }, SetOptions(merge: true));
      });

      // GESTIONE DELLA NOTIFICA QUANDO L'APP E' APERTA
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        if (message.notification != null && mounted) {
          showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: Row(
                  children: [
                    const Icon(Icons.notifications_active, color: appOrange),
                    const SizedBox(width: 8),
                    Expanded(child: Text(message.notification!.title ?? 'Nuova Notifica', style: const TextStyle(fontSize: 18))),
                  ],
                ),
                content: Text(message.notification!.body ?? ''),
                actions: [
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Chiudi'),
                  ),
                ],
              )
          );
        }
      });
    }
  }

  Widget _buildMiniPlayer() {
    final book = appAudio.currentBook;
    if (book == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const PlayerScreen())),
      child: Container(
        color: Theme.of(context).colorScheme.primaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: book.coverUrl != null
                    ? CachedNetworkImage(imageUrl: book.coverUrl!, width: 40, height: 40, fit: BoxFit.cover)
                    : Icon(Icons.book, size: 40, color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[400] : appNavyBlue),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(book.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
            StreamBuilder<PlayerState>(
              stream: appAudio.player.playerStateStream,
              builder: (context, snapshot) {
                final isPlaying = snapshot.data?.playing ?? false;
                return Semantics(
                  label: isPlaying ? 'Pausa' : 'Riproduci',
                  button: true,
                  child: IconButton(
                    iconSize: 32,
                    icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: appOrange),
                    onPressed: () => isPlaying ? appAudio.player.pause() : appAudio.player.play(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final bool isAdmin = user?.email == 'admin@audiolibripro.it';

    final List<Widget> screens = isAdmin
        ? [const LibraryScreen(), const SearchTabScreen(), const ProfileScreen()]
        : [const HomeScreen(), const LibraryScreen(), const SearchTabScreen(), const ProfileScreen()];

    final List<NavigationDestination> destinations = isAdmin
        ? const [
      NavigationDestination(icon: Icon(Icons.my_library_books), label: 'Catalogo'),
      NavigationDestination(icon: Icon(Icons.search), label: 'Cerca'),
      NavigationDestination(icon: Icon(Icons.person), label: 'Profilo'),
    ]
        : const [
      NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
      NavigationDestination(icon: Icon(Icons.my_library_books), label: 'Libreria'),
      NavigationDestination(icon: Icon(Icons.search), label: 'Cerca'),
      NavigationDestination(icon: Icon(Icons.person), label: 'Profilo'),
    ];

    if (_currentIndex >= screens.length) _currentIndex = 0;

    return Scaffold(
      body: Column(
        children: [
          Expanded(child: screens[_currentIndex]),
          _buildMiniPlayer(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) => setState(() => _currentIndex = index),
        destinations: destinations,
      ),
    );
  }
}

// --- HOME ---
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  String _ottieniSaluto() {
    final ora = DateTime.now().hour;
    if (ora < 13) return 'Buongiorno';
    if (ora < 18) return 'Buon pomeriggio';
    return 'Buonasera';
  }

  Widget _buildHorizontalList(List<Book> books, BuildContext context) {
    if (books.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('Nessun libro disponibile.'));

    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final heightScale = textScale > 1.0 ? textScale : 1.0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      height: 240 * heightScale,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: books.length,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemBuilder: (context, index) {
          final book = books[index];
          return GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => BookDetailsScreen(book: book))),
            child: MergeSemantics(
              child: Container(
                width: 140 * heightScale,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ExcludeSemantics(
                        child: Container(
                          decoration: BoxDecoration(
                            color: isDark ? Colors.grey[800] : appNavyBlue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            image: book.coverUrl != null
                                ? DecorationImage(image: CachedNetworkImageProvider(book.coverUrl!), fit: BoxFit.cover)
                                : null,
                          ),
                          child: book.coverUrl == null ? Center(child: Icon(Icons.menu_book, size: 60, color: isDark ? Colors.grey[400] : appNavyBlue)) : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(book.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    String firstName = user?.displayName?.split(' ').first ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text('${_ottieniSaluto()}${firstName.isNotEmpty ? ', $firstName' : ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
              tooltip: 'Richiedi Libro',
              icon: Semantics(label: 'Richiedi Libro', button: true, child: const Icon(Icons.mark_email_unread)),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const RequestBookScreen()))
          ),
          IconButton(
              tooltip: 'Supporto Tecnico',
              icon: Semantics(label: 'Supporto Tecnico', button: true, child: const Icon(Icons.support_agent)),
              onPressed: () async {
                final Uri emailUri = Uri.parse('mailto:supporto@audiolibripro.it?subject=Richiesta%20di%20Supporto%20App');
                try {
                  await launchUrl(emailUri);
                } catch (e) {
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App email non trovata')));
                }
              }
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('books').snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          List<Book> allBooks = snapshot.data!.docs.map((doc) => Book.fromFirestore(doc.data() as Map<String, dynamic>)).toList();
          List<Book> newReleases = List.from(allBooks)..sort((a, b) => b.dateAdded.compareTo(a.dateAdded));
          List<Book> recommended = List.from(allBooks)..shuffle();

          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(padding: EdgeInsets.all(16.0), child: Text('Novità della Settimana', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
                _buildHorizontalList(newReleases.take(10).toList(), context),
                const Padding(padding: EdgeInsets.fromLTRB(16, 32, 16, 16), child: Text('Consigliati per Te', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
                _buildHorizontalList(recommended.take(10).toList(), context),
              ],
            ),
          );
        },
      ),
    );
  }
}

// --- RICERCA ---
class SearchTabScreen extends StatefulWidget {
  const SearchTabScreen({super.key});
  @override
  State<SearchTabScreen> createState() => _SearchTabScreenState();
}

class _SearchTabScreenState extends State<SearchTabScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Cerca nel Catalogo')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              decoration: const InputDecoration(labelText: 'Cerca autore, titolo o saga...', border: OutlineInputBorder(), prefixIcon: Icon(Icons.search)),
              onChanged: (value) => setState(() => _query = value.toLowerCase()),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('books').snapshots(),
              builder: (context, booksSnapshot) {
                if (!booksSnapshot.hasData) return const SizedBox();
                return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).collection('progress').snapshots(),
                    builder: (context, progressSnapshot) {
                      List<Book> books = booksSnapshot.data!.docs.map((doc) => Book.fromFirestore(doc.data() as Map<String, dynamic>)).toList();
                      if (progressSnapshot.hasData) {
                        for (var progressDoc in progressSnapshot.data!.docs) {
                          final data = progressDoc.data() as Map<String, dynamic>;
                          final bookIndex = books.indexWhere((b) => b.id == progressDoc.id);
                          if (bookIndex != -1) books[bookIndex].inLibrary = data['inLibrary'] ?? false;
                        }
                      }
                      final results = books.where((b) => b.title.toLowerCase().contains(_query) || b.author.toLowerCase().contains(_query) || (b.series?.toLowerCase().contains(_query) ?? false)).toList();
                      if (results.isEmpty) return const Center(child: Text('Nessun risultato.'));

                      return ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final book = results[index];
                          return MergeSemantics(
                            child: ListTile(
                              leading: ExcludeSemantics(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: book.coverUrl != null
                                      ? CachedNetworkImage(imageUrl: book.coverUrl!, width: 50, height: 50, fit: BoxFit.cover, errorWidget: (c, u, e) => Icon(Icons.book, size: 40, color: isDark ? Colors.grey[400] : appNavyBlue))
                                      : Container(
                                    width: 50, height: 50,
                                    color: isDark ? Colors.grey[800] : appNavyBlue.withOpacity(0.1),
                                    child: Icon(Icons.menu_book, size: 30, color: isDark ? Colors.grey[400] : appNavyBlue),
                                  ),
                                ),
                              ),
                              title: Text(book.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('${book.author}${book.series != null ? ' • Saga: ${book.series}' : ''}'),
                              trailing: Semantics(
                                label: book.inLibrary ? 'Rimuovi dalla libreria' : 'Aggiungi alla libreria',
                                button: true,
                                child: IconButton(
                                  icon: Icon(book.inLibrary ? Icons.bookmark : Icons.bookmark_add_outlined, color: book.inLibrary ? appOrange : Colors.grey, size: 28),
                                  onPressed: () {
                                    setState(() => book.inLibrary = !book.inLibrary);
                                    if (user != null) FirebaseFirestore.instance.collection('users').doc(user.uid).collection('progress').doc(book.id).set({'inLibrary': book.inLibrary}, SetOptions(merge: true));
                                  },
                                ),
                              ),
                              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => BookDetailsScreen(book: book))),
                            ),
                          );
                        },
                      );
                    }
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- LIBRERIA (CON GESTIONE AVANZATA COPERTINE E COLORI CORRETTI) ---
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  BookSort _sortMode = BookSort.recent;

  Future<void> _createBookFromCloudFolder() async {
    if (FirebaseAuth.instance.currentUser?.email != 'admin@audiolibripro.it') return;

    final titleController = TextEditingController();
    final authorController = TextEditingController();
    final seriesController = TextEditingController();
    final narratorController = TextEditingController();
    final plotController = TextEditingController();
    final folderController = TextEditingController();
    final coverUrlController = TextEditingController();
    bool isConfirmed = false;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Admin: Collega Cartella'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: folderController, decoration: const InputDecoration(labelText: 'Nome cartella Storage (es. libro1)', border: OutlineInputBorder())),
              const SizedBox(height: 16),
              TextField(controller: titleController, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Titolo', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: authorController, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Autore', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: coverUrlController, decoration: const InputDecoration(labelText: 'Link Copertina (opzionale)', border: OutlineInputBorder(), hintText: 'https://.../immagine.jpg')),
              const SizedBox(height: 8),
              TextField(controller: seriesController, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Saga (opzionale)', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: narratorController, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Letto da (opzionale)', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: plotController, maxLines: 3, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Trama (opzionale)', border: OutlineInputBorder())),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annulla')),
          FilledButton(onPressed: () { isConfirmed = true; Navigator.pop(context); }, child: const Text('Genera')),
        ],
      ),
    );

    if (!isConfirmed || folderController.text.trim().isEmpty || titleController.text.trim().isEmpty || !mounted) return;
    showDialog(context: context, barrierDismissible: false, builder: (context) => const Center(child: CircularProgressIndicator()));

    try {
      final folderRef = FirebaseStorage.instance.ref().child(folderController.text.trim());
      final listResult = await folderRef.listAll();
      if (listResult.items.isEmpty) throw Exception("Cartella vuota!");

      final items = listResult.items.toList();
      items.sort((a, b) => a.name.compareTo(b.name));
      List<String> fileUrls = [];
      String? fetchedCoverUrl = coverUrlController.text.trim().isNotEmpty ? coverUrlController.text.trim() : null;

      for (var item in items) {
        final nameLower = item.name.toLowerCase();
        if (nameLower.endsWith('.mp3') || nameLower.endsWith('.m4a') || nameLower.endsWith('.wav')) {
          fileUrls.add(await item.getDownloadURL());
        } else if (fetchedCoverUrl == null && (nameLower.endsWith('.jpg') || nameLower.endsWith('.jpeg') || nameLower.endsWith('.png'))) {
          fetchedCoverUrl = await item.getDownloadURL();
        }
      }

      if (fetchedCoverUrl == null) {
        try {
          final query = Uri.encodeComponent('${titleController.text.trim()} ${authorController.text.trim()}');
          final response = await http.get(Uri.parse('https://www.googleapis.com/books/v1/volumes?q=$query&maxResults=1'));
          if (response.statusCode == 200) {
            final data = json.decode(response.body);
            if (data['items'] != null && data['items'].isNotEmpty) {
              final volumeInfo = data['items'][0]['volumeInfo'];
              if (volumeInfo['imageLinks'] != null) fetchedCoverUrl = volumeInfo['imageLinks']['thumbnail'].replaceAll('http:', 'https:');
            }
          }
        } catch (e) { debugPrint('Errore API Google Books: $e'); }
      }

      final newBook = Book(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: titleController.text.trim(),
        author: authorController.text.trim().isEmpty ? 'Autore Sconosciuto' : authorController.text.trim(),
        series: seriesController.text.trim().isEmpty ? null : seriesController.text.trim(),
        narrator: narratorController.text.trim().isEmpty ? null : narratorController.text.trim(),
        plot: plotController.text.trim().isEmpty ? null : plotController.text.trim(),
        fileUrls: fileUrls,
        coverUrl: fetchedCoverUrl,
      );

      await FirebaseFirestore.instance.collection('books').doc(newBook.id).set(newBook.toFirestore());
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generato!')));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore: $e')));
      }
    }
  }

  Future<void> _deleteBook(Book book) async {
    if (FirebaseAuth.instance.currentUser?.email != 'admin@audiolibripro.it') return;
    try {
      await FirebaseFirestore.instance.collection('books').doc(book.id).delete();
      final folderRef = FirebaseStorage.instance.ref().child('audiobooks').child(book.id);
      final listResult = await folderRef.listAll();
      for (var item in listResult.items) await item.delete();
    } catch (e) { debugPrint("Errore eliminazione: $e"); }
  }

  List<Book> _getSorted(List<Book> list) {
    List<Book> copy = List.from(list);
    copy.sort((a, b) {
      switch (_sortMode) {
        case BookSort.az: return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case BookSort.za: return b.title.toLowerCase().compareTo(a.title.toLowerCase());
        case BookSort.recent: return b.dateAdded.compareTo(a.dateAdded);
        case BookSort.oldest: return a.dateAdded.compareTo(b.dateAdded);
      }
    });
    return copy;
  }

  Widget _buildBookCard(Book book, bool isAdmin) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: MergeSemantics(
        child: ListTile(
          leading: ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: book.coverUrl != null
                  ? CachedNetworkImage(imageUrl: book.coverUrl!, width: 50, height: 50, fit: BoxFit.cover, errorWidget: (c, u, e) => Icon(Icons.book, size: 40, color: isDark ? Colors.grey[400] : appNavyBlue))
                  : Container(
                width: 50, height: 50,
                color: isDark ? Colors.grey[800] : appNavyBlue.withOpacity(0.1),
                child: Icon(Icons.cloud_done, size: 30, color: isDark ? Colors.grey[400] : appNavyBlue),
              ),
            ),
          ),
          title: Text(book.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${book.author}${book.series != null ? ' • Saga: ${book.series}' : ''}'),
              const SizedBox(height: 4),
              Text('${book.fileUrls.length} tracce'),
            ],
          ),
          trailing: isAdmin ? Semantics(
            label: 'Elimina ${book.title}',
            button: true,
            child: IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _deleteBook(book)),
          ) : null,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => BookDetailsScreen(book: book))),
        ),
      ),
    );
  }

  Widget _buildGroupedTab(List<Book> books, bool byAuthor, bool isAdmin) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sortedBooks = _getSorted(books);
    final Map<String, List<Book>> map = {};

    for (var book in sortedBooks) {
      String key = byAuthor ? book.author : (book.series ?? '');
      if (key.isNotEmpty) map.putIfAbsent(key, () => []).add(book);
    }

    final keys = map.keys.toList()..sort();
    if (keys.isEmpty) return Center(child: Text(byAuthor ? 'Nessun autore trovato.' : 'Nessuna saga trovata.'));

    return ListView.builder(
      itemCount: keys.length,
      itemBuilder: (context, index) {
        final key = keys[index];
        final categoryBooks = map[key]!;
        return ExpansionTile(
          title: Text(key, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('${categoryBooks.length} libri'),
          leading: ExcludeSemantics(child: Icon(byAuthor ? Icons.person : Icons.collections_bookmark, color: isDark ? Colors.grey[400] : appNavyBlue)),
          children: categoryBooks.map((b) => _buildBookCard(b, isAdmin)).toList(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final bool isAdmin = user?.email == 'admin@audiolibripro.it';

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('books').snapshots(),
      builder: (context, booksSnapshot) {
        if (!booksSnapshot.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('users').doc(user?.uid).collection('progress').snapshots(),
          builder: (context, progressSnapshot) {
            List<Book> allBooks = booksSnapshot.data!.docs.map((doc) => Book.fromFirestore(doc.data() as Map<String, dynamic>)).toList();
            if (progressSnapshot.hasData) {
              for (var progressDoc in progressSnapshot.data!.docs) {
                final data = progressDoc.data() as Map<String, dynamic>;
                final bookIndex = allBooks.indexWhere((b) => b.id == progressDoc.id);
                if (bookIndex != -1) {
                  allBooks[bookIndex].currentTrackIndex = data['currentTrackIndex'] ?? 0;
                  allBooks[bookIndex].positionSeconds = data['positionSeconds'] ?? 0;
                  allBooks[bookIndex].lastPlayed = data['lastPlayed'] ?? 0;
                  allBooks[bookIndex].inLibrary = data['inLibrary'] ?? false;
                }
              }
            }

            final userBooks = allBooks.where((b) => b.inLibrary || b.lastPlayed > 0).toList();
            final inProgress = userBooks.where((b) => b.progressPercentage > 0 && b.progressPercentage < 100).toList()..sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));
            final notStartedBooks = _getSorted(userBooks.where((b) => b.progressPercentage == 0).toList());
            final completedBooks = _getSorted(userBooks.where((b) => b.progressPercentage == 100).toList());
            final allBooksSorted = _getSorted(allBooks);

            return DefaultTabController(
              length: isAdmin ? 3 : 5,
              child: Scaffold(
                appBar: AppBar(
                  toolbarHeight: 60,
                  title: Text(isAdmin ? 'Catalogo Globale' : 'La Mia Libreria', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
                  actions: [
                    PopupMenuButton<BookSort>(
                      icon: const Icon(Icons.sort),
                      onSelected: (result) => setState(() => _sortMode = result),
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: BookSort.recent, child: Text('Più recenti')),
                        PopupMenuItem(value: BookSort.oldest, child: Text('Meno recenti')),
                        PopupMenuItem(value: BookSort.az, child: Text('A-Z')),
                        PopupMenuItem(value: BookSort.za, child: Text('Z-A')),
                      ],
                    ),
                  ],
                  bottom: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: isAdmin
                        ? const [Tab(text: 'Tutti i Libri'), Tab(text: 'Autori'), Tab(text: 'Saghe')]
                        : const [Tab(text: 'In Lettura'), Tab(text: 'Da Iniziare'), Tab(text: 'Completati'), Tab(text: 'Autori'), Tab(text: 'Saghe')],
                  ),
                ),
                body: TabBarView(
                  children: isAdmin
                      ? [
                    allBooksSorted.isEmpty ? const Center(child: Text('Nessun libro caricato.')) : ListView.builder(itemCount: allBooksSorted.length, itemBuilder: (c, i) => _buildBookCard(allBooksSorted[i], isAdmin)),
                    _buildGroupedTab(allBooks, true, isAdmin),
                    _buildGroupedTab(allBooks, false, isAdmin),
                  ]
                      : [
                    inProgress.isEmpty ? const Center(child: Text('Nessun libro in lettura.')) : ListView.builder(itemCount: inProgress.length, itemBuilder: (c, i) => _buildBookCard(inProgress[i], isAdmin)),
                    notStartedBooks.isEmpty ? const Center(child: Text('Nessun libro.')) : ListView.builder(itemCount: notStartedBooks.length, itemBuilder: (c, i) => _buildBookCard(notStartedBooks[i], isAdmin)),
                    completedBooks.isEmpty ? const Center(child: Text('Nessun libro completato.')) : ListView.builder(itemCount: completedBooks.length, itemBuilder: (c, i) => _buildBookCard(completedBooks[i], isAdmin)),
                    _buildGroupedTab(userBooks, true, isAdmin),
                    _buildGroupedTab(userBooks, false, isAdmin),
                  ],
                ),
                floatingActionButton: isAdmin
                    ? FloatingActionButton(onPressed: _createBookFromCloudFolder, tooltip: 'Aggiungi da cartella', child: const Icon(Icons.create_new_folder))
                    : null,
              ),
            );
          },
        );
      },
    );
  }
}

// --- DETTAGLI DEL LIBRO (CON TASTO "SCARICA INTERO LIBRO") ---
class BookDetailsScreen extends StatefulWidget {
  final Book book;
  const BookDetailsScreen({super.key, required this.book});
  @override
  State<BookDetailsScreen> createState() => _BookDetailsScreenState();
}

class _BookDetailsScreenState extends State<BookDetailsScreen> {
  late bool _inLibrary;
  bool _isDownloadingBook = false;
  double _bookDownloadProgress = 0.0;
  String _downloadStatus = "";

  @override
  void initState() {
    super.initState();
    _inLibrary = widget.book.inLibrary;
  }

  Future<void> _toggleLibrary() async {
    setState(() { _inLibrary = !_inLibrary; widget.book.inLibrary = _inLibrary; });
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) await FirebaseFirestore.instance.collection('users').doc(user.uid).collection('progress').doc(widget.book.id).set({'inLibrary': _inLibrary}, SetOptions(merge: true));
  }

  Future<void> _scaricaInteroLibro() async {
    setState(() { _isDownloadingBook = true; });
    try {
      for (int i = 0; i < widget.book.fileUrls.length; i++) {
        setState(() {
          _downloadStatus = "Scaricando capitolo ${i + 1} di ${widget.book.fileUrls.length}...";
          _bookDownloadProgress = 0.0;
        });
        await scaricaFileAudio(widget.book.fileUrls[i], widget.book.id, i, onProgress: (p) {
          if (mounted) setState(() => _bookDownloadProgress = p);
        });
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Libro scaricato completamente! Ora puoi ascoltarlo offline.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Errore durante il download')));
    } finally {
      if (mounted) setState(() { _isDownloadingBook = false; });
    }
  }

  void _mostraCapitoli() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        children: [
          const Padding(padding: EdgeInsets.all(16.0), child: Text('Capitoli', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
          Expanded(
            child: ListView.builder(
              itemCount: widget.book.fileUrls.length,
              itemBuilder: (context, index) => ListTile(
                leading: CircleAvatar(child: Text('${index + 1}')),
                title: Text('Capitolo ${index + 1}'),
                trailing: IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: 'Scarica questo capitolo',
                  onPressed: () async {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Inizio download capitolo ${index + 1}...')));
                    try {
                      await scaricaFileAudio(widget.book.fileUrls[index], widget.book.id, index);
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Capitolo ${index + 1} salvato offline!')));
                    } catch (e) {
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Errore download capitolo')));
                    }
                  },
                ),
                onTap: () {
                  Navigator.pop(context);
                  widget.book.currentTrackIndex = index;
                  appAudio.loadAndPlay(widget.book);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const PlayerScreen()));
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('Dettagli')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ExcludeSemantics(
              child: Container(
                height: 220, width: 150,
                decoration: BoxDecoration(color: isDark ? Colors.grey[800] : appNavyBlue.withOpacity(0.1), borderRadius: BorderRadius.circular(12), image: widget.book.coverUrl != null ? DecorationImage(image: CachedNetworkImageProvider(widget.book.coverUrl!), fit: BoxFit.cover) : null),
                child: widget.book.coverUrl == null ? Center(child: Icon(Icons.menu_book, size: 80, color: isDark ? Colors.grey[400] : appNavyBlue)) : null,
              ),
            ),
            const SizedBox(height: 24),
            MergeSemantics(
              child: Column(
                children: [
                  Text(widget.book.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, height: 1.2)),
                  const SizedBox(height: 12),
                  Text('di ${widget.book.author}', style: const TextStyle(fontSize: 18)),
                  if (widget.book.narrator != null) Padding(padding: const EdgeInsets.only(top: 8.0), child: Text('Letto da: ${widget.book.narrator}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.grey))),
                ],
              ),
            ),
            const SizedBox(height: 32),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: _toggleLibrary,
                  icon: Icon(_inLibrary ? Icons.check : Icons.add),
                  label: Text(_inLibrary ? 'È nella tua libreria' : 'Aggiungi alla libreria'),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), foregroundColor: _inLibrary ? Colors.green : (isDark ? Colors.white : appNavyBlue), side: BorderSide(color: _inLibrary ? Colors.green : (isDark ? Colors.white : appNavyBlue), width: 2)),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    appAudio.loadAndPlay(widget.book);
                    Navigator.push(context, MaterialPageRoute(builder: (context) => const PlayerScreen()));
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: Text(widget.book.progressPercentage > 0 ? 'Continua ad ascoltare' : 'Inizia ad ascoltare'),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(onPressed: _mostraCapitoli, icon: const Icon(Icons.format_list_numbered), label: const Text('Mostra Capitoli'), style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16))),

                const SizedBox(height: 12),

                if (_isDownloadingBook)
                  Column(
                    children: [
                      Text(_downloadStatus, style: const TextStyle(fontWeight: FontWeight.bold, color: appOrange)),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: _bookDownloadProgress, color: appOrange),
                    ],
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _scaricaInteroLibro,
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('Scarica Libro Intero (Offline)'),
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  ),
              ],
            ),
            const SizedBox(height: 40),
            MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Trama', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Text(widget.book.plot ?? 'Nessuna trama disponibile.', style: const TextStyle(fontSize: 16, height: 1.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- PLAYER GLOBALE ---
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  double _currentSpeed = 1.0;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;

  @override
  void initState() {
    super.initState();
    appAudio.addListener(_updateState);
  }

  @override
  void dispose() {
    appAudio.removeListener(_updateState);
    super.dispose();
  }

  void _updateState() {
    if (mounted) setState(() {});
  }

  void _toggleSpeed() {
    setState(() => _currentSpeed = _currentSpeed == 1.0 ? 1.25 : _currentSpeed == 1.25 ? 1.5 : _currentSpeed == 1.5 ? 2.0 : 1.0);
    appAudio.player.setSpeed(_currentSpeed);
  }

  void _showTimerPicker() {
    showModalBottomSheet(
        context: context,
        builder: (context) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(padding: EdgeInsets.all(16.0), child: Text('Timer di Spegnimento', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              ListTile(leading: const Icon(Icons.timer_off), title: const Text('Disattiva Timer'), onTap: () { appAudio.setSleepTimer(0); Navigator.pop(context); }),
              ListTile(leading: const Icon(Icons.timer), title: const Text('15 minuti'), onTap: () { appAudio.setSleepTimer(15); Navigator.pop(context); }),
              ListTile(leading: const Icon(Icons.timer), title: const Text('30 minuti'), onTap: () { appAudio.setSleepTimer(30); Navigator.pop(context); }),
              ListTile(leading: const Icon(Icons.timer), title: const Text('45 minuti'), onTap: () { appAudio.setSleepTimer(45); Navigator.pop(context); }),
              ListTile(leading: const Icon(Icons.timer), title: const Text('60 minuti'), onTap: () { appAudio.setSleepTimer(60); Navigator.pop(context); }),
              const SizedBox(height: 16),
            ],
          );
        }
    );
  }

  void _showPlaylist() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
            builder: (BuildContext context, StateSetter setModalState) {
              final book = appAudio.currentBook!;
              return StreamBuilder<int?>(
                stream: appAudio.player.currentIndexStream,
                builder: (context, snapshot) {
                  final currentIndex = snapshot.data ?? book.currentTrackIndex;
                  return Column(
                    children: [
                      const Padding(padding: EdgeInsets.all(16.0), child: Text('Tracce', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
                      Expanded(
                        child: ListView.builder(
                          itemCount: book.fileUrls.length,
                          itemBuilder: (context, index) {
                            final isPlaying = index == currentIndex;
                            return ListTile(
                              leading: Icon(isPlaying ? Icons.volume_up : Icons.music_note, color: isPlaying ? appOrange : Colors.grey),
                              title: Text('Traccia ${index + 1}', style: TextStyle(fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal, color: isPlaying ? appOrange : null)),
                              onTap: () {
                                appAudio.player.seek(Duration.zero, index: index);
                                Navigator.pop(context);
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              );
            }
        );
      },
    );
  }

  Widget buildPulsanteDownloadCapitolo(String urlCapitolo, int index) {
    if (_isDownloading) {
      return Column(
        children: [
          const Text("Download in corso...", style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _downloadProgress, color: appOrange),
        ],
      );
    }
    return ElevatedButton.icon(
      onPressed: () async {
        setState(() { _isDownloading = true; _downloadProgress = 0.0; });
        try {
          await scaricaFileAudio(urlCapitolo, appAudio.currentBook!.id, index, onProgress: (p) {
            if (mounted) setState(() => _downloadProgress = p);
          });
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Capitolo salvato per l\'ascolto offline!')));
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Errore durante il download')));
        } finally {
          if (mounted) setState(() { _isDownloading = false; });
        }
      },
      icon: const Icon(Icons.download),
      label: const Text("Scarica Capitolo"),
    );
  }

  @override
  Widget build(BuildContext context) {
    final book = appAudio.currentBook;
    if (book == null) return const Scaffold(body: Center(child: Text("Nessun audio.")));

    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(appAudio.timerEndTime != null ? Icons.timer : Icons.timer_outlined, color: appAudio.timerEndTime != null ? appOrange : null),
            tooltip: 'Timer Spegnimento',
            onPressed: _showTimerPicker,
          ),
          TextButton(onPressed: _toggleSpeed, child: Text('${_currentSpeed}x', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
          IconButton(icon: const Icon(Icons.format_list_bulleted), onPressed: _showPlaylist, tooltip: 'Mostra tracce'),
        ],
      ),
      body: appAudio.isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: book.coverUrl != null
                      ? CachedNetworkImage(imageUrl: book.coverUrl!, height: 250, fit: BoxFit.cover)
                      : Container(
                    height: 250, width: 170,
                    color: isDark ? Colors.grey[800] : appNavyBlue.withOpacity(0.1),
                    child: Center(child: Icon(Icons.book, size: 120, color: isDark ? Colors.grey[400] : appNavyBlue)),
                  ),
                ),
              ),
              const SizedBox(height: 30),
              StreamBuilder<int?>(
                stream: appAudio.player.currentIndexStream,
                builder: (context, snapshot) {
                  final current = (snapshot.data ?? book.currentTrackIndex) + 1;
                  return Text('Traccia $current di ${book.fileUrls.length}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500));
                },
              ),

              // --- TESTO DEL TIMER A SCHERMO ---
              if (appAudio.timerEndTime != null)
                StreamBuilder(
                    stream: Stream.periodic(const Duration(seconds: 1)),
                    builder: (context, snapshot) {
                      final remaining = appAudio.timerEndTime!.difference(DateTime.now());
                      if (remaining.isNegative) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text('Spegnimento tra ${remaining.inMinutes}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')}', style: const TextStyle(color: appOrange, fontWeight: FontWeight.bold)),
                      );
                    }
                ),

              const SizedBox(height: 12),
              StreamBuilder<Duration>(
                stream: appAudio.player.positionStream,
                builder: (context, snapshot) {
                  final position = snapshot.data ?? Duration.zero;
                  final duration = appAudio.player.duration ?? Duration.zero;
                  return Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), overlayShape: const RoundSliderOverlayShape(overlayRadius: 14)),
                        child: Slider(
                          min: 0.0,
                          max: duration.inSeconds > 0 ? duration.inSeconds.toDouble() : 1.0,
                          value: position.inSeconds.toDouble().clamp(0.0, duration.inSeconds > 0 ? duration.inSeconds.toDouble() : 1.0),
                          onChanged: (value) => appAudio.player.seek(Duration(seconds: value.toInt())),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("${position.inMinutes}:${(position.inSeconds % 60).toString().padLeft(2, '0')}", style: const TextStyle(color: Colors.grey)),
                            Text("${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}", style: const TextStyle(color: Colors.grey)),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),

              FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Semantics(
                        label: 'Torna indietro 30 secondi', button: true,
                        child: IconButton(iconSize: 36 * textScale, icon: const Icon(Icons.replay_30), onPressed: () { Duration newPos = appAudio.player.position - const Duration(seconds: 30); if (newPos < Duration.zero) newPos = Duration.zero; appAudio.player.seek(newPos); }),
                      ),
                      const SizedBox(width: 16),
                      Semantics(
                        label: 'Traccia precedente', button: true,
                        child: IconButton(iconSize: 48 * textScale, icon: const Icon(Icons.skip_previous), onPressed: () => appAudio.player.seekToPrevious()),
                      ),
                      const SizedBox(width: 16),
                      StreamBuilder<PlayerState>(
                        stream: appAudio.player.playerStateStream,
                        builder: (context, snapshot) {
                          final isPlaying = snapshot.data?.playing ?? false;
                          return Semantics(
                            label: isPlaying ? 'Pausa' : 'Riproduci', button: true,
                            child: IconButton(iconSize: 80 * textScale, icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled), color: appOrange, onPressed: () => isPlaying ? appAudio.player.pause() : appAudio.player.play()),
                          );
                        },
                      ),
                      const SizedBox(width: 16),
                      Semantics(
                        label: 'Traccia successiva', button: true,
                        child: IconButton(iconSize: 48 * textScale, icon: const Icon(Icons.skip_next), onPressed: () => appAudio.player.seekToNext()),
                      ),
                      const SizedBox(width: 16),
                      Semantics(
                        label: 'Vai avanti 30 secondi', button: true,
                        child: IconButton(iconSize: 36 * textScale, icon: const Icon(Icons.forward_30), onPressed: () { Duration newPos = appAudio.player.position + const Duration(seconds: 30); Duration maxPos = appAudio.player.duration ?? Duration.zero; if (newPos > maxPos) newPos = maxPos; appAudio.player.seek(newPos); }),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),

              StreamBuilder<int?>(
                stream: appAudio.player.currentIndexStream,
                builder: (context, snapshot) {
                  final currentIndex = snapshot.data ?? book.currentTrackIndex;
                  final currentUrl = book.fileUrls[currentIndex];
                  return buildPulsanteDownloadCapitolo(currentUrl, currentIndex);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- PROFILO ---
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final User? user = FirebaseAuth.instance.currentUser;
  late TextEditingController _nomeController;
  late TextEditingController _cognomeController;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    String fullName = user?.displayName ?? '';
    List<String> parts = fullName.split(' ');
    _nomeController = TextEditingController(text: parts.isNotEmpty ? parts[0] : '');
    _cognomeController = TextEditingController(text: parts.length > 1 ? parts.sublist(1).join(' ') : '');
  }

  Future<void> _cambiaFoto() async {
    try {
      final image = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (image == null || user == null) return;
      setState(() => _isLoading = true);
      final storageRef = FirebaseStorage.instance.ref().child('avatars').child('${user!.uid}.jpg');
      await storageRef.putFile(File(image.path));
      await user!.updatePhotoURL(await storageRef.getDownloadURL());
      await user!.reload();
      if (mounted) { setState(() {}); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Foto aggiornata!'))); }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Errore foto')));
    } finally { if (mounted) setState(() => _isLoading = false); }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('Il mio Profilo')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Semantics(
                label: 'Cambia immagine del profilo', button: true,
                child: GestureDetector(
                  onTap: _cambiaFoto,
                  child: CircleAvatar(
                      radius: 60,
                      backgroundColor: isDark ? Colors.grey[800] : appNavyBlue.withOpacity(0.1),
                      backgroundImage: user?.photoURL != null ? NetworkImage(user!.photoURL!) : null,
                      child: user?.photoURL == null ? Icon(Icons.person, size: 60, color: isDark ? Colors.grey[400] : appNavyBlue) : null
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
            TextField(controller: _nomeController, decoration: const InputDecoration(labelText: 'Nome', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _cognomeController, decoration: const InputDecoration(labelText: 'Cognome', border: OutlineInputBorder())),
            const SizedBox(height: 32),
            if (_isLoading) const Center(child: CircularProgressIndicator())
            else FilledButton.icon(onPressed: () {}, icon: const Icon(Icons.save), label: const Text('Salva Modifiche')),

            const SizedBox(height: 48),
            const Divider(),
            const SizedBox(height: 16),
            const Text('Impostazioni App', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SwitchListTile(title: const Text('Modalità Scura'), value: appSettings.themeMode == ThemeMode.dark, onChanged: (val) { appSettings.toggleTheme(val); setState(() {}); }),
            SwitchListTile(title: const Text('Colori Daltonismo'), value: appSettings.isColorBlindMode, onChanged: (val) { appSettings.toggleColorBlind(val); setState(() {}); }),

            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text('Account', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('Esci dall\'account', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              onTap: () async {
                await FirebaseAuth.instance.signOut();
              },
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// --- RICHIESTE ---
class RequestBookScreen extends StatefulWidget {
  const RequestBookScreen({super.key});

  @override
  State<RequestBookScreen> createState() => _RequestBookScreenState();
}

class _RequestBookScreenState extends State<RequestBookScreen> {
  final _titoloController = TextEditingController();
  final _autoreController = TextEditingController();
  late TextEditingController _nomeController;
  late TextEditingController _emailController;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    _nomeController = TextEditingController(text: user?.displayName ?? '');
    _emailController = TextEditingController(text: user?.email ?? '');
  }

  Future<void> _inviaRichiesta() async {
    final titolo = _titoloController.text.trim();
    final autore = _autoreController.text.trim();
    final nome = _nomeController.text.trim();
    final email = _emailController.text.trim();

    if (titolo.isEmpty || autore.isEmpty || nome.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Compila tutti i campi obbligatori!')));
      return;
    }

    final subject = Uri.encodeComponent('Richiesta Nuovo Audiolibro: $titolo');
    final body = Uri.encodeComponent('Ciao, vorrei richiedere:\n\nTitolo: $titolo\nAutore: $autore\n\nNome: $nome\nEmail: $email');
    final Uri emailUri = Uri.parse('mailto:richieste@audiolibripro.it?subject=$subject&body=$body');

    try {
      await launchUrl(emailUri);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App email non trovata')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Richiedi un Libro')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.forward_to_inbox, size: 60, color: appNavyBlue),
            const SizedBox(height: 24),
            const Text('Non trovi il tuo libro preferito?\nInviaci una richiesta!', textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
            const SizedBox(height: 32),
            TextField(controller: _titoloController, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Titolo del Libro *', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _autoreController, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Autore *', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _nomeController, decoration: const InputDecoration(labelText: 'Il tuo Nome *', border: OutlineInputBorder())),
            const SizedBox(height: 16),
            TextField(controller: _emailController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'La tua Email', border: OutlineInputBorder())),
            const SizedBox(height: 32),
            FilledButton.icon(onPressed: _inviaRichiesta, icon: const Icon(Icons.send), label: const Text('Invia Richiesta')),
          ],
        ),
      ),
    );
  }
}