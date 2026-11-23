import 'package:firebase_auth/firebase_auth.dart';

class AccountUser {
  const AccountUser({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.emailVerified,
    required this.isAnonymous,
  });

  final String uid;
  final String email;
  final String displayName;
  final bool emailVerified;
  final bool isAnonymous;
}

abstract interface class AccountAuthService {
  AccountUser? get currentUser;
  Stream<AccountUser?> get userChanges;
  Future<AccountUser> createAccount({
    required String name,
    required String email,
    required String password,
  });
  Future<AccountUser?> signIn({
    required String email,
    required String password,
  });
  Future<AccountUser?> refreshCurrentUser();
  Future<void> resendVerificationEmail();
  Future<void> sendPasswordResetEmail(String email);
  Future<void> signOut();
}

class FirebaseAccountAuthService implements AccountAuthService {
  FirebaseAccountAuthService(this._auth);

  final FirebaseAuth _auth;

  @override
  AccountUser? get currentUser => _toAccountUser(_auth.currentUser);

  @override
  Stream<AccountUser?> get userChanges =>
      _auth.userChanges().map(_toAccountUser);

  @override
  Future<AccountUser> createAccount({
    required String name,
    required String email,
    required String password,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = credential.user;
    if (user == null) {
      throw StateError('Firebase did not return the new account.');
    }
    await user.updateDisplayName(name.trim());
    await user.sendEmailVerification();
    await user.reload();
    final refreshedUser = currentUser;
    if (refreshedUser == null) {
      throw StateError('The new Firebase account could not be refreshed.');
    }
    return refreshedUser;
  }

  @override
  Future<AccountUser?> signIn({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await credential.user?.reload();
    return currentUser;
  }

  @override
  Future<AccountUser?> refreshCurrentUser() async {
    await _auth.currentUser?.reload();
    return currentUser;
  }

  @override
  Future<void> resendVerificationEmail() async {
    final user = _auth.currentUser;
    if (user == null || user.isAnonymous) {
      throw StateError(
        'Sign in to an email account before requesting verification.',
      );
    }
    await user.sendEmailVerification();
  }

  @override
  Future<void> sendPasswordResetEmail(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  @override
  Future<void> signOut() => _auth.signOut();
}

AccountUser? _toAccountUser(User? user) {
  if (user == null) return null;
  return AccountUser(
    uid: user.uid,
    email: user.email ?? '',
    displayName: user.displayName ?? '',
    emailVerified: user.emailVerified,
    isAnonymous: user.isAnonymous,
  );
}

String describeFirebaseAuthError(FirebaseAuthException error) {
  return switch (error.code) {
    'email-already-in-use' =>
      'An account already uses this email. Try logging in.',
    'invalid-email' => 'Enter a valid email address.',
    'weak-password' => 'Choose a password with at least 6 characters.',
    'user-not-found' ||
    'wrong-password' ||
    'invalid-credential' => 'Email or password is incorrect.',
    'user-disabled' => 'This account has been disabled. Contact support.',
    'operation-not-allowed' =>
      'Email/password sign-in is not enabled for this Firebase project.',
    'too-many-requests' => 'Too many attempts. Wait a little and try again.',
    'network-request-failed' =>
      'Could not reach Firebase. Check your internet connection and try again.',
    _ => 'Firebase sign-in failed (${error.code}). Please try again.',
  };
}
