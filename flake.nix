{
  description = "NixOS-cn package collection";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    with flake-utils.lib;
    with nixpkgs.lib;
    with builtins;
    let
      defaultSystem = "x86_64-linux";

      listFiles = dir: map (n: dir + "/${n}") (attrNames (readDir dir));
      listNixFilesRecursive = dir:
        flatten (mapAttrsToList (name: type:
          let path = dir + "/${name}";
          in if type == "directory" then
            if pathExists (dir + "/${name}/default.nix") then
              path
            else
              listNixFilesRecursive path
          else if hasSuffix ".nix" name then
            path
          else
            [ ]) (readDir dir));

      filterBySystem = system: pkgs:
        filterAttrsRecursive (_: p:
          !(isDerivation p) || (if hasAttrByPath [ "meta" "platforms" ] p then
            elem system p.meta.platforms
          else
            system == defaultSystem)) pkgs;
      getPackages = f: dir:
        listToAttrs (map (name: {
          inherit name;
          value = f (dir + "/${name}");
        }) (attrNames (readDir dir)));
      makePackageSet = f:
        getPackages f ./top-level // listToAttrs (map (dir: {
          name = baseNameOf dir;
          value = recurseIntoAttrs (getPackages f dir);
        }) (listFiles ./package-set));

      toNixOSCNRegistries = mapAttrs (name: entry: {
        from = {
          id = "nixos-cn";
          ref = name;
          type = "indirect";
        };
        to = entry;
      });
      # Currently we only have github/gitlab registries
      registryEntryToGitURL = entry:
        with entry;
        "https://${type}.com/${owner}/${repo}.git";
      registryEntryToFlakeURL = entry: lock:
        with entry;
        "${type}:${owner}/${repo}/${lock.rev}";
      registryOutputs = let
        locks = importJSON ./registries.lock;
        registries = import ./registries.nix;
      in mapAttrs (name: entry:
        (getFlake (registryEntryToFlakeURL entry locks.${name})).outputs)
      registries;
      extractFromRegistries = f:
        filterAttrs (_: v: v != { }) (mapAttrs f registryOutputs);
      mapRecurseIntoAttrs = s:
        mapAttrs (_: v:
          if !isAttrs v || isDerivation v then v else mapRecurseIntoAttrs v)
        (recurseIntoAttrs s);
      mergeAttrsUniquely = s:
        let
          nameCount = zipAttrsWith (name: values: length values) (attrValues s);
        in foldl (prev: name:
          prev // (mapAttrs' (n: v:
            if nameCount.${n} > 1 then
              nameValuePair "${n}-${name}" v
            else
              nameValuePair n v) s.${name})) { } (attrNames s);

    in eachDefaultSystem (system:
      let
        pkgs = (import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        });
        intree-packages =
          filterBySystem system (makePackageSet (n: pkgs.callPackage n { }));
        outtree-packages = # filterBySystem system
          (mapRecurseIntoAttrs (mergeAttrsUniquely (extractFromRegistries
            (_: output:
              (attrByPath [ "packages" system ] { } output)
              // (attrByPath [ "legacyPackages" system ] { } output)))));
      in rec {
        legacyPackages = intree-packages // { re-export = outtree-packages; };
        apps = {
          update-lock = mkApp {
            drv = with pkgs;
              writeShellScriptBin "update-lock" ''
                export PATH=${makeBinPath [ git coreutils jq ]}
                function getRev(){
                  git ls-remote $1 HEAD|cut -f1
                }
                lock='{}'
                ${concatStrings (mapAttrsToList (name: entry: ''
                  lock=$(echo "$lock"|jq -c ".\"${name}\".rev = \"$(getRev "${
                    registryEntryToGitURL entry
                  }")\"")
                '') (import ./registries.nix))}
                echo "$lock"|jq
              '';
          };
          re-export-hash = with pkgs;
            let
              drvPaths = writeText "drvPaths" (concatStringsSep "\n"
                (map (p: builtins.unsafeDiscardStringContext p.drvPath)
                  (builtins.attrValues (flattenTree outtree-packages))));
              hash = runCommand "hash" { buildInputs = [ coreutils ]; } ''
                cat ${drvPaths}|sort|sha256sum|cut -d' ' -f1 > $out
              '';
            in mkApp {
              drv = writeShellScriptBin "re-export-hash" ''
                cat ${hash}
              '';
            };
        };

        checks = flattenTree intree-packages;
        hydraJobs = filterAttrs
          (_: v: !(hasAttrByPath [ "meta" "license" ] v) || v.meta.license.free)
          checks;
      }) // {
        overlay = final: prev: {
          nixoscn =
            recurseIntoAttrs (makePackageSet (n: final.callPackage n { }));
        };
        nixosModules.nixoscn = { ... }: {
          nixpkgs.overlays = [ self.overlay ];
          imports = listNixFilesRecursive ./module;
        };
        nixosModules.nixoscn-registries = { ... }: {
          nix.registry = toNixOSCNRegistries (import ./registries.nix);
        };
      };
}
