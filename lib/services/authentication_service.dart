import 'package:firebase_auth/firebase_auth.dart';

class AuthenticationService {
  const AuthenticationService._();

  static Future<void> ensureAnonymousUser() async {
    if (FirebaseAuth.instance.currentUser != null) {
      return;
    }

    await FirebaseAuth.instance.signInAnonymously();
  }
}