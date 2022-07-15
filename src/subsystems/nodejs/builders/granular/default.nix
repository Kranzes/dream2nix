{...}: {
  type = "pure";

  build = {
    jq,
    lib,
    makeWrapper,
    pkgs,
    python3,
    runCommand,
    stdenv,
    writeText,
    ...
  }: {
    # Funcs
    # AttrSet -> Bool) -> AttrSet -> [x]
    getCyclicDependencies, # name: version: -> [ {name=; version=; } ]
    getDependencies, # name: version: -> [ {name=; version=; } ]
    getSource, # name: version: -> store-path
    # Attributes
    subsystemAttrs, # attrset
    defaultPackageName, # string
    defaultPackageVersion, # string
    packages, # list
    # attrset of pname -> versions,
    # where versions is a list of version strings
    packageVersions,
    # function which applies overrides to a package
    # It must be applied by the builder to each individual derivation
    # Example:
    #   produceDerivation name (mkDerivation {...})
    produceDerivation,
    nodejs ? null,
    ...
  } @ args: let
    b = builtins;
    l = lib // builtins;

    nodejsVersion = subsystemAttrs.nodejsVersion;

    isMainPackage = name: version:
      (args.packages."${name}" or null) == version;

    nodejs =
      if args ? nodejs
      then args.nodejs
      else
        pkgs."nodejs-${builtins.toString nodejsVersion}_x"
        or (throw "Could not find nodejs version '${nodejsVersion}' in pkgs");

    nodeSources = runCommand "node-sources" {} ''
      tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
      mv node-* $out
    '';

    allPackages =
      lib.mapAttrs
      (name: versions:
        lib.genAttrs
        versions
        (version:
          makePackage name version))
      packageVersions;

    outputs = rec {
      # select only the packages listed in dreamLock as main packages
      packages =
        b.foldl'
        (ps: p: ps // p)
        {}
        (lib.mapAttrsToList
          (name: version: {
            "${name}"."${version}" = allPackages."${name}"."${version}";
          })
          args.packages);

      devShell = devShells.default;

      devShells =
        {default = devShells.${defaultPackageName};}
        // (
          l.mapAttrs
          (name: version: allPackages.${name}.${version}.devShell)
          args.packages
        );
    };

    # This is only executed for electron based packages.
    # Electron ships its own version of node, requiring a rebuild of native
    # extensions.
    # Theoretically this requires headers for the exact electron version in use,
    # but we use the headers from nixpkgs' electron instead which might have a
    # different minor version.
    # Alternatively the headers can be specified via `electronHeaders`.
    # Also a custom electron version can be specified via `electronPackage`
    electron-rebuild = ''
      # prepare node headers for electron
      if [ -n "$electronPackage" ]; then
        export electronDist="$electronPackage/lib/electron"
      else
        export electronDist="$nodeModules/$packageName/node_modules/electron/dist"
      fi
      local ver
      ver="v$(cat $electronDist/version | tr -d '\n')"
      mkdir $TMP/$ver
      cp $electronHeaders $TMP/$ver/node-$ver-headers.tar.gz

      # calc checksums
      cd $TMP/$ver
      sha256sum ./* > SHASUMS256.txt
      cd -

      # serve headers via http
      python -m http.server 45034 --directory $TMP &

      # copy electron distribution
      cp -r $electronDist $TMP/electron
      chmod -R +w $TMP/electron

      # configure electron toolchain
      ${pkgs.jq}/bin/jq ".build.electronDist = \"$TMP/electron\"" package.json \
          | ${pkgs.moreutils}/bin/sponge package.json

      ${pkgs.jq}/bin/jq ".build.linux.target = \"dir\"" package.json \
          | ${pkgs.moreutils}/bin/sponge package.json

      ${pkgs.jq}/bin/jq ".build.npmRebuild = false" package.json \
          | ${pkgs.moreutils}/bin/sponge package.json

      # execute electron-rebuild if available
      export headers=http://localhost:45034/
      if command -v electron-rebuild &> /dev/null; then
        pushd $electronAppDir

        electron-rebuild -d $headers
        popd
      fi
    '';

    # Only executed for electron based packages.
    # Creates an executable script under /bin starting the electron app
    electron-wrap =
      if pkgs.stdenv.isLinux
      then ''
        mkdir -p $out/bin
        makeWrapper \
          $electronDist/electron \
          $out/bin/$(basename "$packageName") \
          --add-flags "$(realpath $electronAppDir)"
      ''
      else ''
        mkdir -p $out/bin
        makeWrapper \
          $electronDist/Electron.app/Contents/MacOS/Electron \
          $out/bin/$(basename "$packageName") \
          --add-flags "$(realpath $electronAppDir)"
      '';

    # Generates a derivation for a specific package name + version
    makePackage = name: version: let
      pname = lib.replaceStrings ["@" "/"] ["__at__" "__slash__"] name;

      deps = getDependencies name version;

      cyclicDeps = getCyclicDependencies name version;

      nodeDeps =
        lib.forEach
        deps
        (dep: allPackages."${dep.name}"."${dep.version}");

      cyclicNodeDeps =
        lib.forEach
        cyclicDeps
        (dep: allPackages."${dep.name}"."${dep.version}");

      allNodeDeps = nodeDeps ++ cyclicNodeDeps;

      # Derivation building the ./node_modules directory in isolation.
      # This is used for the devShell of the current package.
      # We do not want to build the full package for the devShell.
      nodeModulesDir = pkgs.runCommand "node_modules-${pname}" {} ''
        # symlink direct dependencies to ./node_modules
        mkdir $out
        ${l.concatStringsSep "\n" (
          l.forEach allNodeDeps
          (pkg: ''
            for dir in $(ls ${pkg}/lib/node_modules/); do
              if [[ $dir == @* ]]; then
                mkdir -p $out/$dir
                ln -s ${pkg}/lib/node_modules/$dir/* $out/$dir/
              else
                ln -s ${pkg}/lib/node_modules/$dir $out/
              fi
            done
          '')
        )}

        # symlink transitive executables to ./node_modules/.bin
        mkdir $out/.bin
        for dep in ${l.toString nodeDeps}; do
          for binDir in $(ls -d $dep/lib/node_modules/.bin 2>/dev/null ||:); do
            ln -sf $binDir/* $out/.bin/
          done
        done
      '';

      passthruDeps =
        l.listToAttrs
        (l.forEach deps
          (dep:
            l.nameValuePair
            dep.name
            allPackages."${dep.name}"."${dep.version}"));

      dependenciesJson =
        b.toJSON
        (lib.listToAttrs
          (b.map
            (dep: lib.nameValuePair dep.name dep.version)
            deps));

      electronDep =
        if ! isMainPackage name version
        then null
        else
          lib.findFirst
          (dep: dep.name == "electron")
          null
          deps;

      electronVersionMajor =
        lib.versions.major electronDep.version;

      electronHeaders =
        if electronDep == null
        then null
        else pkgs."electron_${electronVersionMajor}".headers;

      pkg = produceDerivation name (stdenv.mkDerivation rec {
        inherit
          dependenciesJson
          electronHeaders
          nodeDeps
          nodeSources
          version
          ;

        packageName = name;

        inherit pname;

        passthru.dependencies = passthruDeps;

        passthru.devShell = pkgs.mkShell {
          buildInputs = [
            nodejs
          ];
          shellHook = ''
            # create the ./node_modules directory
            if [ -e ./node_modules ] && [ ! -L ./node_modules ]; then
              echo -e "\nFailed creating the ./node_modules symlink to ${nodeModulesDir}"
              echo -e "\n./node_modules already exists and is a directory, which means it is managed by another program. Please delete ./node_modules first and re-enter the dev shell."
            else
              rm -f ./node_modules
              ln -s ${nodeModulesDir} ./node_modules
              export PATH="$PATH:$(realpath ./node_modules)/.bin"
            fi
          '';
        };

        installMethod = "symlink";

        electronAppDir = ".";

        # only run build on the main package
        runBuild = isMainPackage name version;

        src = getSource name version;

        nativeBuildInputs = [makeWrapper];

        buildInputs = [jq nodejs python3];

        # prevents running into ulimits
        passAsFile = ["dependenciesJson" "nodeDeps"];

        preConfigurePhases = ["d2nLoadFuncsPhase" "d2nPatchPhase"];

        # can be overridden to define alternative install command
        # (defaults to 'npm run postinstall')
        buildScript = null;

        # python script to modify some metadata to support installation
        # (see comments below on d2nPatchPhase)
        fixPackage = "${./fix-package.py}";

        # script to install (symlink or copy) dependencies.
        installDeps = "${./install-deps.py}";

        # costs performance and doesn't seem beneficial in most scenarios
        dontStrip = true;

        # declare some useful shell functions
        d2nLoadFuncsPhase = ''
          # function to resolve symlinks to copies
          symlinksToCopies() {
            local dir="$1"

            echo "transforming symlinks to copies..."
            for f in $(find -L "$dir" -xtype l); do
              if [ -f $f ]; then
                continue
              fi
              echo "copying $f"
              chmod +wx $(dirname "$f")
              mv "$f" "$f.bak"
              mkdir "$f"
              if [ -n "$(ls -A "$f.bak/")" ]; then
                cp -r "$f.bak"/* "$f/"
                chmod -R +w $f
              fi
              rm "$f.bak"
            done
          }
        '';

        # TODO: upstream fix to nixpkgs
        # example which requires this:
        #   https://registry.npmjs.org/react-window-infinite-loader/-/react-window-infinite-loader-1.0.7.tgz
        unpackCmd =
          if lib.hasSuffix ".tgz" src
          then "tar --delay-directory-restore -xf $src"
          else null;

        unpackPhase = ''
          runHook preUnpack

          nodeModules=$out/lib/node_modules

          export sourceRoot="$nodeModules/$packageName"

          # sometimes tarballs do not end with .tar.??
          unpackFallback(){
            local fn="$1"
            tar xf "$fn"
          }

          unpackCmdHooks+=(unpackFallback)

          unpackFile $src

          # Make the base dir in which the target dependency resides in first
          mkdir -p "$(dirname "$sourceRoot")"

          # install source
          if [ -f "$src" ]
          then
              # Figure out what directory has been unpacked
              export packageDir="$(find . -maxdepth 1 -type d | tail -1)"

              # Restore write permissions
              find "$packageDir" -type d -exec chmod u+x {} \;
              chmod -R u+w -- "$packageDir"

              # Move the extracted tarball into the output folder
              mv -- "$packageDir" "$sourceRoot"
          elif [ -d "$src" ]
          then
              export strippedName="$(stripHash $src)"

              # Restore write permissions
              chmod -R u+w -- "$strippedName"

              # Move the extracted directory into the output folder
              mv -- "$strippedName" "$sourceRoot"
          fi

          runHook postUnpack
        '';

        # The python script wich is executed in this phase:
        #   - ensures that the package is compatible to the current system
        #   - ensures the main version in package.json matches the expected
        #   - pins dependency versions in package.json
        #     (some npm commands might otherwise trigger networking)
        #   - creates symlinks for executables declared in package.json
        # Apart from that:
        #   - Any usage of 'link:' in package.json is replaced with 'file:'
        #   - If package-lock.json exists, it is deleted, as it might conflict
        #     with the parent package-lock.json.
        d2nPatchPhase = ''
          # delete package-lock.json as it can lead to conflicts
          rm -f package-lock.json

          # repair 'link:' -> 'file:'
          mv $nodeModules/$packageName/package.json $nodeModules/$packageName/package.json.old
          cat $nodeModules/$packageName/package.json.old | sed 's!link:!file\:!g' > $nodeModules/$packageName/package.json
          rm $nodeModules/$packageName/package.json.old

          # run python script (see comment above):
          cp package.json package.json.bak
          python $fixPackage \
          || \
          # exit code 3 -> the package is incompatible to the current platform
          #  -> Let the build succeed, but don't create lib/node_packages
          if [ "$?" == "3" ]; then
            rm -r $out/*
            echo "Not compatible with system $system" > $out/error
            exit 0
          else
            exit 1
          fi

          # configure typescript
          if [ -f ./tsconfig.json ] \
              && node -e 'require("typescript")' &>/dev/null; then
            node ${./tsconfig-to-json.js}
            ${pkgs.jq}/bin/jq ".compilerOptions.preserveSymlinks = true" tsconfig.json \
                | ${pkgs.moreutils}/bin/sponge tsconfig.json
          fi
        '';

        # - installs dependencies into the node_modules directory
        # - adds executables of direct node module dependencies to PATH
        # - adds the current node module to NODE_PATH
        # - sets HOME=$TMPDIR, as this is required by some npm scripts
        # TODO: don't install dev dependencies. Load into NODE_PATH instead
        configurePhase = ''
          runHook preConfigure

          # symlink sub dependencies as well as this imitates npm better
          python $installDeps

          echo "Symlinking transitive executables to $nodeModules/.bin"
          for dep in ${l.toString nodeDeps}; do
            binDir=$dep/lib/node_modules/.bin
            if [ -e $binDir ]; then
              for bin in $(ls $binDir/); do
                mkdir -p $nodeModules/.bin

                # symlink might have been already created by install-deps.py
                # if installMethod=copy was selected
                if [ ! -e $nodeModules/.bin/$bin ]; then
                  ln -s $binDir/$bin $nodeModules/.bin/$bin
                fi
              done
            fi
          done

          # add bin path entries collected by python script
          export PATH="$PATH:$nodeModules/.bin"

          # add dependencies to NODE_PATH
          export NODE_PATH="$NODE_PATH:$nodeModules/$packageName/node_modules"

          export HOME=$TMPDIR

          runHook postConfigure
        '';

        # Runs the install command which defaults to 'npm run postinstall'.
        # Allows using custom install command by overriding 'buildScript'.
        buildPhase = ''
          runHook preBuild

          # execute electron-rebuild
          if [ -n "$electronHeaders" ]; then
            echo "executing electron-rebuild"
            ${electron-rebuild}
          fi

          # execute install command
          if [ -n "$buildScript" ]; then
            if [ -f "$buildScript" ]; then
              $buildScript
            else
              eval "$buildScript"
            fi
          # by default, only for top level packages, `npm run build` is executed
          elif [ -n "$runBuild" ] && [ "$(jq '.scripts.build' ./package.json)" != "null" ]; then
            npm run build
          else
            if [ "$(jq '.scripts.install' ./package.json)" != "null" ]; then
              npm --production --offline --nodedir=$nodeSources run install
            fi
            if [ "$(jq '.scripts.postinstall' ./package.json)" != "null" ]; then
              npm --production --offline --nodedir=$nodeSources run postinstall
            fi
          fi

          runHook postBuild
        '';

        # Symlinks executables and manual pages to correct directories
        installPhase = ''
          runHook preInstall

          echo "Symlinking manual pages"
          if [ -d "$nodeModules/$packageName/man" ]
          then
            mkdir -p $out/share
            for dir in "$nodeModules/$packageName/man/"*
            do
              mkdir -p $out/share/man/$(basename "$dir")
              for page in "$dir"/*
              do
                  ln -s $page $out/share/man/$(basename "$dir")
              done
            done
          fi

          # wrap electron app
          if [ -n "$electronHeaders" ]; then
            echo "Wrapping electron app"
            ${electron-wrap}
          fi

          runHook postInstall
        '';
      });
    in
      pkg;
  in
    outputs;
}
