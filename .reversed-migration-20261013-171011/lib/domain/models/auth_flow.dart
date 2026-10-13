enum AuthFlow {
  signUp,
  signIn;

  String get routeValue => this == AuthFlow.signUp ? 'sign-up' : 'sign-in';

  static AuthFlow fromRoute(String? value) {
    return value == 'sign-in' ? AuthFlow.signIn : AuthFlow.signUp;
  }
}
