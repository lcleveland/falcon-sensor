{
  lib,
  stdenvNoCC,
  python3,
  gtk3,
  gobject-introspection,
  libayatana-appindicator,
  wrapGAppsHook3,
}:

let
  pythonEnv = python3.withPackages (ps: [ ps.pygobject3 ]);

  # One icon per state in tools/falcon-sensor-tray.py's ICONS.
  #
  # Deliberately coloured rather than symbolic: a symbolic icon is black, and it
  # is the tray host's job to recolour it -- which GTK does and most
  # StatusNotifierItem hosts do not, leaving a black shield on a black bar. The
  # glyph differs per state as well as the hue, so the state does not depend on
  # being able to tell green from amber.
  shield = colour: glyph: ''
    <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22">
      <path d="M11 2 L19 5 V11 C19 15.5 15.6 19.2 11 20.5 C6.4 19.2 3 15.5 3 11 V5 Z"
            fill="${colour}"/>
      <g fill="none" stroke="#ffffff" stroke-width="2"
         stroke-linecap="round" stroke-linejoin="round">${glyph}</g>
    </svg>
  '';

  icons = {
    # A tick: registered, running, out of RFM.
    falcon-sensor-protected = shield "#2e7d32" ''<path d="M7.4 11.2 L9.9 13.7 L14.6 8.3"/>'';
    # An exclamation mark: running, but in RFM or unregistered.
    falcon-sensor-degraded = shield "#ef6c00" ''<path d="M11 6.5 V12.4"/><path d="M11 15.6 V15.7"/>'';
    # A cross: the unit is not running.
    falcon-sensor-inactive = shield "#c62828" ''<path d="M8.2 8.2 L13.8 13.8"/><path d="M13.8 8.2 L8.2 13.8"/>'';
    # A dash: nobody is publishing a status to read.
    falcon-sensor-unknown = shield "#616161" ''<path d="M7.6 11 H14.4"/>'';
  };

  iconCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: svg: ''
      install -Dm644 ${builtins.toFile "${name}.svg" svg} \
        "$out/share/falcon-sensor/icons/${name}.svg"
      install -Dm644 ${builtins.toFile "${name}.svg" svg} \
        "$out/share/icons/hicolor/scalable/status/${name}.svg"
    '') icons
  );
in
stdenvNoCC.mkDerivation {
  pname = "falcon-sensor-tray";
  version = "1.0.0";

  dontUnpack = true;

  nativeBuildInputs = [
    gobject-introspection # the typelibs the script requires at runtime
    wrapGAppsHook3
  ];

  buildInputs = [
    gtk3
    libayatana-appindicator
    pythonEnv
  ];

  installPhase = ''
    runHook preInstall

    install -Dm755 ${../tools/falcon-sensor-tray.py} "$out/bin/falcon-sensor-tray"
    substituteInPlace "$out/bin/falcon-sensor-tray" \
      --replace-fail '#!/usr/bin/env python3' '#!${pythonEnv.interpreter}'

    ${iconCommands}

    runHook postInstall
  '';

  # The tray icon's name is resolved by the tray host, not by this process, so the
  # icons ship with an absolute path the host is handed over D-Bus
  # (StatusNotifierItem's IconThemePath). The flat directory is what hosts look in
  # for `<name>.svg`; the hicolor copy above covers hosts that go through the icon
  # theme instead.
  preFixup = ''
    gappsWrapperArgs+=(
      --set FALCON_TRAY_ICON_PATH "$out/share/falcon-sensor/icons"
    )
  '';

  meta = {
    description = "Tray icon showing the CrowdStrike Falcon sensor's state";
    mainProgram = "falcon-sensor-tray";
    platforms = lib.platforms.linux;
  };
}
