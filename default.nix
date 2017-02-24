# Nix file for Agda.
#
# To create a development environment, create a shell.nix file with this content:
#
# -----------------------------------
# with (import <nixpkgs> {}).pkgs;
# let modifiedHaskellPackages = haskellPackages.override {
#      overrides = self: super: {
#        Agda = self.callPackage ./. {
#            sphinx = python34Packages.sphinx;
#            sphinx_rtd_theme = python34Packages.sphinx_rtd_theme;
#            texLive = texlive.combined.scheme-full;
#        };
#      };
#     };
# in modifiedHaskellPackages.Agda.env
# -----------------------------------
#
# To enter the development environment, simply call `nix-shell shell.nix`.
#

{ mkDerivation, alex, array, base, binary, boxes, bytestring
, containers, cpphs, data-hash, deepseq, directory, edit-distance
, emacs, equivalence, filepath, geniplate-mirror, happy, hashable
, hashtables, haskeline, haskell-src-exts, mtl, parallel, pretty
, process, process-extras, QuickCheck, stdenv, strict, tasty
, regex-tdfa, regex-tdfa-text, filemanip
, tasty-silver, template-haskell, temporary, text, time
, transformers, transformers-compat, unordered-containers, xhtml
, murmur-hash, ieee754, gitrev
, zlib, tasty-quickcheck, monadplus, EdisonCore, EdisonAPI
, text-icu
, user-manual ? true, sphinx ? null, sphinx_rtd_theme ? null, texLive ? null
, nodejs-6_x
# additional test dependencies
, wdiff, colordiff
}:

assert user-manual -> sphinx != null && sphinx_rtd_theme != null && texLive != null;

mkDerivation {
  pname = "Agda";
<<<<<<< HEAD
  version = "2.5.1.1";
=======
  version = "2.6.0";
>>>>>>> upstream/master
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  buildDepends = [
    array base binary boxes bytestring containers data-hash deepseq
    directory edit-distance equivalence filepath geniplate-mirror
    hashable hashtables haskeline haskell-src-exts mtl parallel pretty
    process QuickCheck strict template-haskell text time transformers filemanip
    transformers-compat unordered-containers xhtml zlib tasty-quickcheck
    monadplus EdisonCore EdisonAPI murmur-hash ieee754 gitrev text-icu
  ];
  testDepends = [
    base containers directory filepath process-extras tasty
    regex-tdfa regex-tdfa-text
    tasty-silver temporary text
  ];
  configureFlags = [];
  buildTools = [ alex cpphs happy nodejs-6_x wdiff colordiff]
    ++ stdenv.lib.optionals user-manual [ sphinx sphinx_rtd_theme texLive ];

  executableToolDepends = [ emacs ];

  postInstall = ''
     # Separate loops to avoid internal error
     files=($out/share/*-ghc-*/Agda-*/lib/prim/Agda/{Primitive.agda,Builtin/*.agda})
     for f in "''${files[@]}"
     do
       $out/bin/agda $f
     done
     for f in "''${files[@]}"
     do
       $out/bin/agda -c --no-main $f
     done
     $out/bin/agda-mode compile
   '';

  homepage = "http://wiki.portal.chalmers.se/agda/";
  description = "A dependently typed functional programming language and proof assistant";
  license = "unknown";
}
