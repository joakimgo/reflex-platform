{ lib, haskellLib, fetchFromGitHub, fetchpatch, versionWildcard, thunkSet }:

with lib;
with haskellLib;

self: super: {
  _dep = super._dep or {} // thunkSet ./dep // {
  };

  attoparsec = self.callCabal2nix "attoparsec" self._dep.attoparsec {};
  buffer-builder = appendPatch super.buffer-builder ./buffer-builder-text-jsstring.patch;
  conduit-extra =  (appendPatch super.conduit-extra ./conduit-extra-text-jsstring.patch);
  double-conversion = overrideCabal super.double-conversion (drv: {
    src = fetchFromGitHub {
      owner = "obsidiansystems";
      repo = "double-conversion";
      rev = "0f9ddde468687d25fa6c4c9accb02a034bc2f9c3";
      sha256 = "0sjljf1sbwalw1zycpjf6bqhljag9i1k77b18b0fd1pzrc29wnks";
    };
  });
}
