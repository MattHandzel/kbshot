# kbshot: press a hotkey, every screenshot-worthy thing on screen gets a labelled
# box, type the label to capture it. No mouse. See kbshot.py for the design notes.
#
# The picker overlay is wl-kbptr's `floating` mode fed candidate regions on stdin;
# kbshot supplies those regions itself from Hyprland window geometry, tesseract's
# layout analysis, and a scipy edge/connected-component pass. Every runtime binary
# is baked into the wrapper's PATH rather than assumed, because this runs from a
# Hyprland `exec` bind whose PATH is not the login shell's.
{pkgs}: let
  python = pkgs.python3.withPackages (ps: with ps; [numpy scipy pillow]);
in
  pkgs.writeShellApplication {
    name = "kbshot";
    runtimeInputs = with pkgs; [
      python
      wl-kbptr # the labelled keyboard picker overlay
      grim # screen capture
      tesseract # text block/paragraph/line boxes, and --ocr
      wl-clipboard # wl-copy
      libnotify # notify-send
      hyprland # hyprctl: monitor geometry and window rectangles
      procps # pkill -x, to clear a rival or wedged overlay off the screen
    ];
    text = ''
      exec ${python}/bin/python3 ${./kbshot.py} "$@"
    '';
  }
