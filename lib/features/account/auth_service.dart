// DJ account: sign-in with the user's own DJ login (email + password).
//
// One same account on the Windows laptop and the Android phone. The
// account exists only so DJ can sync context between the two devices;
// DJ works fully offline without one (the Core never needs it).
//
// Choice: Firebase Auth (email/password) + Cloud Firestore, free Spark
// plan. Hand-rolled auth is risky to get right; Firebase Auth is proven,
// free, and does exactly this (one login, both devices). No social
// login (no Google/Apple) — the user picks an email + password.
//
// Privacy: no password is ever logged or stored anywhere except
// Firebase Auth. AuthService only ever sees the password for the
// duration of one sign-in/sign-up call, then drops the reference.

import 'package:firebase_auth/firebase_auth.dart';

/// Plain-language auth failure. The UI shows [message] as-is.
class AuthFailure implements Exception {
  final String message;
  const AuthFailure(this.message);
  @override
  String toString() => 'AuthFailure: $message';
}

/// The signed-in user, as the app sees them. No password, no token.
class DjAuthUser {
  final String uid;
  final String? email;
  final String? displayName;
  const DjAuthUser({
    required this.uid,
    this.email,
    this.displayName,
  });
}

/// Backend behind [AuthService]. The real one talks to Firebase Auth;
/// tests use a fake. This seam is what lets the account be tested
/// without a real Firebase project.
abstract class AuthBackend {
  Stream<DjAuthUser?> get authStateChanges;
  DjAuthUser? get currentUser;
  Future<DjAuthUser> signUp(String email, String password);
  Future<DjAuthUser> signIn(String email, String password);
  Future<void> signOut();
  Future<void> deleteUser();
}

/// Firebase Auth implementation of [AuthBackend].
class FirebaseAuthBackend implements AuthBackend {
  FirebaseAuthBackend([FirebaseAuth? auth])
      : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  static DjAuthUser _toUser(User user) => DjAuthUser(
        uid: user.uid,
        email: user.email,
        displayName: user.displayName,
      );

  @override
  Stream<DjAuthUser?> get authStateChanges =>
      _auth.authStateChanges().map((u) => u == null ? null : _toUser(u));

  @override
  DjAuthUser? get currentUser {
    final u = _auth.currentUser;
    return u == null ? null : _toUser(u);
  }

  @override
  Future<DjAuthUser> signUp(String email, String password) async {
    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      return _toUser(cred.user!);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendlyMessage(e));
    }
  }

  @override
  Future<DjAuthUser> signIn(String email, String password) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return _toUser(cred.user!);
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendlyMessage(e));
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<void> deleteUser() async {
    try {
      await _auth.currentUser?.delete();
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(_friendlyMessage(e));
    }
  }

  /// Firebase error codes -> one plain sentence each. The raw code and
  /// the password are never surfaced.
  static String _friendlyMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'That email address does not look right.';
      case 'user-not-found':
        return 'No DJ account with this email. Create one instead.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Wrong password. Try again.';
      case 'email-already-in-use':
        return 'An account with this email already exists. Sign in instead.';
      case 'weak-password':
        return 'Choose a stronger password (at least 6 characters).';
      case 'too-many-requests':
        return 'Too many tries. Wait a little, then try again.';
      case 'network-request-failed':
        return 'No connection. Check your internet and try again.';
      case 'requires-recent-login':
        return 'Sign in again first, then try deleting the account.';
      case 'user-disabled':
        return 'This account has been disabled.';
      default:
        return 'Something went wrong. Try again.';
    }
  }
}

/// The DJ account service. The app talks to this, never to Firebase
/// directly.
class AuthService {
  AuthService({
    AuthBackend? backend,
    // Runs BEFORE the Firebase user is deleted, while the user is
    // still signed in: wipes the user's Firestore data and local
    // synced data. Wiring (see Account.create) supplies this; without
    // it, deleteAccount only deletes the Firebase user.
    this.onBeforeDelete,
  }) : _backend = backend ?? FirebaseAuthBackend();

  final AuthBackend _backend;

  /// Called before the Firebase user is deleted. See above.
  final Future<void> Function(String uid)? onBeforeDelete;

  /// Stream of the signed-in user (null when signed out).
  Stream<DjAuthUser?> get currentUser => _backend.authStateChanges;

  DjAuthUser? get currentUserNow => _backend.currentUser;

  bool get isSignedIn => _backend.currentUser != null;

  Future<DjAuthUser> signUp(String email, String password) =>
      _backend.signUp(email.trim(), password);

  Future<DjAuthUser> signIn(String email, String password) =>
      _backend.signIn(email.trim(), password);

  Future<void> signOut() => _backend.signOut();

  /// Deletes the Firebase user AND wipes the user's Firestore data
  /// AND the local synced data (via [onBeforeDelete], which runs
  /// first, while still signed in). Only call after the UI confirms.
  Future<void> deleteAccount() async {
    final user = _backend.currentUser;
    if (user == null) return;
    await onBeforeDelete?.call(user.uid);
    await _backend.deleteUser();
  }
}
