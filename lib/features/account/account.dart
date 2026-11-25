// DJ account facade: the one object the app uses for the account.
//
// Wiring (see FIREBASE-SETUP.md): after Firebase is configured, the
// app creates the account with [Account.create] and holds it in
// DjAppState. The sign-in page (lib/ui/sign_in_page.dart) talks to
// this object only.
//
// The account is only for sync. DJ works fully offline without one;
// the Core never needs an account.
import 'auth_service.dart';
import 'sync_service.dart';

/// The DJ account: sign-in state + sync, in one place.
class Account {
  Account({
    required AuthService auth,
    required SyncService sync,
    required CloudStore cloud,
    required LocalStore local,
  })  : _auth = auth,
        _sync = sync,
        _cloud = cloud,
        _local = local;

  /// Production wiring. [dataDir] is DJ's data folder (the one that
  /// holds dj_config.json). Call only after Firebase.initializeApp.
  factory Account.create({required String dataDir}) {
    final local = FileLocalStore(dataDir);
    final cloud = FirestoreCloudStore();
    final sync = SyncService(cloud: cloud, local: local);
    final auth = AuthService(
      onBeforeDelete: (uid) async {
        // Wipe cloud data first (still signed in), then local data.
        await cloud.deleteAll(uid);
        local.wipeAll();
      },
    );
    return Account(auth: auth, sync: sync, cloud: cloud, local: local);
  }

  final AuthService _auth;
  final SyncService _sync;
  final CloudStore _cloud;
  final LocalStore _local;

  AuthService get auth => _auth;
  SyncService get sync => _sync;

  /// Stream of the signed-in user (null when signed out).
  Stream<DjAuthUser?> get signInStatus => _auth.currentUser;

  bool isSignedIn() => _auth.isSignedIn;

  /// Email of the signed-in user, null when signed out.
  String? get email => _auth.currentUserNow?.email;

  /// Display name if one was ever set, else the part of the email
  /// before '@', else null. Email/password accounts have no display
  /// name by default.
  String? get displayName {
    final user = _auth.currentUserNow;
    if (user == null) return null;
    if (user.displayName != null && user.displayName!.isNotEmpty) {
      return user.displayName;
    }
    final email = user.email;
    if (email != null && email.contains('@')) {
      return email.split('@').first;
    }
    return email;
  }

  /// Sign in, then start syncing this device with the account.
  /// Throws [AuthFailure] with a plain message on failure.
  Future<DjAuthUser> signIn(String email, String password) async {
    final user = await _auth.signIn(email, password);
    await _sync.startSync(user.uid);
    return user;
  }

  /// Create the DJ account, then start syncing.
  /// Throws [AuthFailure] with a plain message on failure.
  Future<DjAuthUser> signUp(String email, String password) async {
    final user = await _auth.signUp(email, password);
    await _sync.startSync(user.uid);
    return user;
  }

  /// Sign out: stop sync first (nothing uploads after this), then
  /// sign out. Local data stays on this device.
  Future<void> signOut() async {
    await _sync.stopSync();
    await _auth.signOut();
  }

  /// Delete everything: the Firebase user, all of the user's
  /// Firestore data, and the synced local data. Only call after the
  /// UI has confirmed twice — this cannot be undone.
  Future<void> deleteEverything() async {
    await _sync.stopSync();
    final uid = _auth.currentUserNow?.uid;
    await _auth.deleteAccount();
    // Belt and braces: if the delete callback did not run (e.g. the
    // user was already signed out), wipe cloud + local directly.
    if (uid != null) {
      try {
        await _cloud.deleteAll(uid);
      } catch (_) {}
    }
    _local.wipeAll();
  }
}
