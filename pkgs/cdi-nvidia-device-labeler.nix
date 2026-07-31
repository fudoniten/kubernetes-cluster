{ lib, stdenvNoCC, makeWrapper, babashka }:

stdenvNoCC.mkDerivation {
  pname = "cdi-nvidia-device-labeler";
  version = "0.1.0";

  src = ../static;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m0555 $src/cdi-nvidia-device-labeler.bb \
      $out/bin/cdi-nvidia-device-labeler
    wrapProgram $out/bin/cdi-nvidia-device-labeler \
      --prefix PATH : ${lib.makeBinPath [ babashka ]}
    runHook postInstall
  '';

  meta = {
    description =
      "Label Kubernetes nodes according to the NVIDIA devices they carry";
    mainProgram = "cdi-nvidia-device-labeler";
    platforms = lib.platforms.linux;
  };
}
