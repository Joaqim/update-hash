{
  lib,
  writeShellApplication,
  ...
}:
writeShellApplication rec {
  name = "update-hash";
  text = builtins.readFile ./${name}.bash;
  meta = with lib; {
    description = "Utility script to update flake.nix hash";
    platforms = platforms.all;
    mainProgram = name;
  };
}
