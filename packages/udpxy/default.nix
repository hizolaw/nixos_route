{ lib, stdenv, fetchFromGitHub }:
stdenv.mkDerivation {
  pname = "udpxy";
  version = "1.0-25.2";
  src = fetchFromGitHub {
    owner = "pcherenkov";
    repo = "udpxy";
    rev = "2f1e87f72bf20203ac651e6f26e31ba413b9dc7f";
    hash = "sha256-v+w4Y6MyJqUrgwuYUYTZW0Zn1jhW4vEpgBEQyEjvkzg=";
  };
  sourceRoot = "source/chipmunk";
  # New compiler warnings in this older upstream must not become errors.
  postPatch = ''
    substituteInPlace Makefile --replace-fail "-Werror" ""
  '';
  makeFlags = [ "CC=${stdenv.cc.targetPrefix}cc" ];
  installPhase = ''
    runHook preInstall
    install -Dm755 udpxy "$out/bin/udpxy"
    runHook postInstall
  '';
  meta = {
    description = "UDP multicast to HTTP relay";
    homepage = "https://github.com/pcherenkov/udpxy";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "udpxy";
  };
}
